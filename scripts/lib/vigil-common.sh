#!/usr/bin/env bash
# vigil-common.sh — shared runtime-path and timestamp helpers for Vigil.
#
# This file is meant to be `source`d (never executed directly) by
# scripts/vigil-queue and future Vigil scripts. It deliberately does NOT
# `set -e`/`set -u` at the top-level, since that would mutate the shell
# options of whatever script sources it.

# _vigil_sha1_16 — echoes the first 16 hex chars of the SHA-1 of stdin.
#
# WR-08: `sha1sum` is a GNU coreutils utility, not part of the base
# macOS userland and not in this project's devShell buildInputs for the
# darwin systems flake.nix declares support for. Prefer it when present
# (keeps the exact same hash -- and therefore the exact same resolved
# runtime dir -- on every system this has run on so far), falling back
# to macOS's own `shasum` and then to `openssl dgst`, both of which
# produce the identical SHA-1 digest.
_vigil_sha1_16() {
	if command -v sha1sum >/dev/null 2>&1; then
		sha1sum | cut -c1-16
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 1 | cut -c1-16
	else
		# openssl's stdin output format varies by version ("SHA1(stdin)=
		# <hash>" vs. a bare "<hash>"); the hash is always the LAST
		# whitespace-separated field either way.
		openssl dgst -sha1 | awk '{print $NF}' | cut -c1-16
	fi
}

# vigil_runtime_dir — echoes the resolved runtime dir for this tmux server.
#
# Honors $VIGIL_RUNTIME_DIR as a test seam first (bats isolates every test
# run into its own scratch directory via this override, never touching the
# real $XDG_RUNTIME_DIR). Otherwise resolves to
# "${XDG_RUNTIME_DIR:-/tmp}/vigil/<socket-name>", where <socket-name> is the
# basename of $TMUX's socket path component, or "default" if $TMUX is unset.
# When $XDG_RUNTIME_DIR is unset (the shared, non-UID-scoped /tmp fallback),
# <socket-name> is further prefixed with the caller's UID to avoid colliding
# with another local user's identically-named socket.
vigil_runtime_dir() {
	if [[ -n "${VIGIL_RUNTIME_DIR:-}" ]]; then
		printf '%s' "$VIGIL_RUNTIME_DIR"
		return
	fi

	local base socket_path socket_name
	base="${XDG_RUNTIME_DIR:-/tmp}"
	if [[ -n "${TMUX:-}" ]]; then
		socket_path="${TMUX%%,*}"
		# Hash the FULL socket path, not just its basename (WR-01): two
		# distinct tmux servers started with e.g. `-S /project-a/default`
		# and `-S /project-b/default` both have a trailing "default"
		# filename component, so basename() alone would collapse them
		# onto the same vigil runtime dir and silently merge their queues.
		socket_name="$(printf '%s' "$socket_path" | _vigil_sha1_16)"
	else
		socket_name="default"
	fi
	# When falling back to the shared /tmp (no $XDG_RUNTIME_DIR), prefix the
	# socket name with the caller's UID: tmux's own default socket path is
	# already UID-scoped ("/tmp/tmux-<uid>/..."), but basename() above
	# discards that component, so two different local users on the same
	# host would otherwise collide on the identical "/tmp/vigil/default"
	# path and lock each other out (0700 dir created by whichever user
	# runs first).
	if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
		socket_name="$(id -u)-${socket_name}"
	fi
	printf '%s/vigil/%s' "$base" "$socket_name"
}

# vigil_usage_cache_file — echoes the usage/balance cache path (v1.2).
#
# Deliberately NOT scoped to a tmux socket: the cache is written by a
# systemd timer (which runs with no $TMUX and therefore resolves a
# different socket name) and read by the renderer inside tmux. Both must
# agree, so this is a single per-UID path under $XDG_RUNTIME_DIR.
# VIGIL_USAGE_CACHE is the test/config seam.
vigil_usage_cache_file() {
	if [[ -n "${VIGIL_USAGE_CACHE:-}" ]]; then
		printf '%s' "$VIGIL_USAGE_CACHE"
		return
	fi
	printf '%s/vigil-usage-%s.json' "${XDG_RUNTIME_DIR:-/tmp}" "$(id -u)"
}

# vigil_queue_file — echoes the path to this runtime dir's queue.json.
vigil_queue_file() {
	printf '%s/queue.json' "$(vigil_runtime_dir)"
}

# vigil_lock_file — echoes the path to this runtime dir's queue.lock.
vigil_lock_file() {
	printf '%s/queue.lock' "$(vigil_runtime_dir)"
}

# _vigil_assert_safe_dir <path> [skip_owner_check]
#
# Refuses to proceed (exit 1) if <path> already exists but is not a plain
# directory -- e.g. a symlink (or a broken symlink, which fails `-e` but
# not `-L`) planted by another local user ahead of time, or some other
# non-directory entry -- closing the CR-01 (iteration 3) symlink/foreign-
# directory redirection attack on the shared /tmp fallback path: without
# this check, `mkdir -p` treats "already exists" as success and silently
# follows whatever is already there, so the leaf runtime dir, queue.json,
# and the lock-file's truncating `exec {FD}>` open could all land inside
# an attacker-chosen location instead of a user-controlled one.
#
# By default, an existing directory must additionally be owned by the
# current user. Pass "skip_owner_check" for paths that are intentionally
# shared across every local user (the sticky 1777 "vigil" parent) -- an
# ownership check there would reintroduce the shared-parent lockout that
# a prior iteration's CR-01 fix (edf77c3) specifically closed, since only
# whichever user created the parent first would ever own it.
_vigil_assert_safe_dir() {
	local path="$1" skip_owner_check="${2:-}"

	if [[ -L "$path" ]]; then
		echo "vigil-queue: refusing to use '$path': is a symlink (possible symlink attack)" >&2
		exit 1
	fi

	if [[ -e "$path" ]]; then
		if [[ ! -d "$path" ]]; then
			echo "vigil-queue: refusing to use '$path': not a plain directory" >&2
			exit 1
		fi
		if [[ "$skip_owner_check" != "skip_owner_check" ]]; then
			local owner
			owner="$(stat -c %u "$path" 2>/dev/null || stat -f %u "$path" 2>/dev/null)"
			if [[ "$owner" != "$(id -u)" ]]; then
				echo "vigil-queue: refusing to use '$path': not owned by current user" >&2
				exit 1
			fi
		fi
	fi
}

# vigil_ensure_runtime_dir — creates the runtime dir with 0700 permissions.
#
# The leaf runtime directory itself is always created with explicit 0700
# (never relies on ambient umask) per the Information Disclosure mitigation
# (T-02-03): the runtime dir may live under a world-readable /tmp fallback,
# so permissions must be hardened every time, not just on first creation.
#
# On the /tmp fallback path (no $XDG_RUNTIME_DIR), the leaf dir has a
# shared "vigil" parent that every local user's invocation needs to
# traverse. That parent is deliberately created/kept world-traversable
# with the sticky bit (mode 1777, like /tmp itself) BEFORE the umask
# override below — a bare `umask 077; mkdir -p <leaf>` would otherwise
# apply 0700 to that shared parent too (shellcheck SC2174: `-m` only
# applies to the deepest directory `mkdir -p` creates, so intermediate
# dirs still inherit the active umask), permanently locking out every
# user but whoever ran first (CR-01). Under $XDG_RUNTIME_DIR, the parent
# is already inside the user's own 0700 "/run/user/<uid>" dir, so forcing
# it to 1777 there is harmless. Only the leaf is locked to 0700; the
# UID-prefixed leaf name (see vigil_runtime_dir) still prevents different
# users' leaf dirs from colliding.
#
# Also performs a best-effort sweep of orphaned *.tmp.* files left behind
# by a writer killed (or crashed) between _vigil_write_queue_atomic's
# temp-file write and its atomic `mv` (WR-02). This runs on every
# invocation, so a long-running production environment self-heals instead
# of accumulating clutter indefinitely. A plain `trap ... EXIT` would not
# cover this: the holder may be killed with SIGKILL (exactly what
# test/fault/crash_safety.bats exercises), which no process can trap. The
# `-mmin +1` threshold (older than 1 minute) avoids racing a write that is
# still legitimately in flight.
vigil_ensure_runtime_dir() {
	local dir parent old_umask
	dir="$(vigil_runtime_dir)"
	parent="${dir%/*}"

	# Reject a pre-existing symlink or foreign-owned entry at either path
	# component before trusting `mkdir -p`'s "already exists" success
	# (CR-01, iteration 3). The shared "vigil" parent is intentionally
	# traversable by every local user (1777), so only its directory-ness
	# is checked there, not its owner.
	_vigil_assert_safe_dir "$parent" skip_owner_check

	# Shared "vigil" parent (only present on the /tmp fallback path) must
	# stay traversable by every local user, like /tmp itself. SC2174 ("-m
	# only applies to the deepest directory with -p") doesn't apply here:
	# $parent's own parent ("$base", either /tmp or $XDG_RUNTIME_DIR) is
	# always pre-existing, so this call only ever creates the single
	# "vigil" directory and -m always lands on it.
	# shellcheck disable=SC2174
	mkdir -p -m 1777 "$parent"

	# The leaf is exclusively this user's (UID-prefixed, see
	# vigil_runtime_dir), so unlike the shared parent it must additionally
	# be owned by us -- closing the same symlink-redirection attack at the
	# leaf itself, not just at the parent.
	_vigil_assert_safe_dir "$dir"

	old_umask="$(umask)"
	umask 077
	mkdir -p "$dir"
	umask "$old_umask"

	# WR-07: `mkdir -p` is a no-op on an already-existing leaf, so the
	# `umask 077` above only hardens permissions on first creation --
	# contradicting the docstring's "hardened every time" claim. chmod
	# unconditionally so a leaf that ever existed with looser
	# permissions (older version, restored state, manual creation) is
	# tightened on every invocation, not just the first.
	chmod 700 "$dir"

	find "$dir" -maxdepth 1 -name 'queue.json.tmp.*' -mmin +1 -delete 2>/dev/null || true
}

# vigil_now_iso — echoes the current UTC time in ISO-8601 format.
vigil_now_iso() {
	date -u +%Y-%m-%dT%H:%M:%SZ
}

# _vigil_close_lock_fd — closes this process's copy of the held lock FD
# (if any) in the CURRENT shell context. Harmless no-op when no lock is
# held (VIGIL_LOCK_FD unset).
#
# CR-01: `exec {VIGIL_LOCK_FD}>"$lock_file"` does not set close-on-exec,
# so every child process forked while the lock is held (jq, mv, tmux,
# the fault-injection sleep, ...) inherits its own copy of that
# descriptor. flock is attached to the open file description, so the
# kernel keeps the advisory lock alive until *every* copy is closed --
# not just until the nominal holder exits. If the holder is killed while
# such a child is still running, the orphaned child keeps the lock held
# indefinitely, and the next mutation times out after `flock -w 2` and
# exits 2 (the mutation is dropped).
#
# Call sites MUST invoke this at the top of a literal subshell -- "( ... )"
# or the subshell a command substitution "$( ... )" already creates --
# immediately before spawning the child that must not inherit the lock.
# Because `exec` inside a subshell only mutates that subshell's own FD
# table, the parent process (and its real hold on the lock) is untouched;
# only the forked child that follows loses its copy of the descriptor.
_vigil_close_lock_fd() {
	if [[ -n "${VIGIL_LOCK_FD:-}" ]]; then
		exec {VIGIL_LOCK_FD}>&-
	fi
}

# vigil_release_lock — closes the currently held lock FD in THIS shell
# (not a subshell), actually releasing the flock early so the caller can
# do further best-effort work (e.g. refresh-client, WR-05) without that
# work being gated inside the critical section. Safe to call when no
# lock is held. Unlike _vigil_close_lock_fd, this is meant to be called
# directly (no subshell wrapper) by the real lock holder.
vigil_release_lock() {
	if [[ -n "${VIGIL_LOCK_FD:-}" ]]; then
		exec {VIGIL_LOCK_FD}>&-
		unset VIGIL_LOCK_FD
	fi
}

# vigil_with_lock <fn> [args...]
#
# Acquires an exclusive flock on the dedicated queue.lock file (never the
# queue file itself) before running <fn>, and leaves the FD open so the
# lock remains held until the process exits (or vigil_release_lock is
# called explicitly). A 2s wait timeout means a stuck/dead lock holder
# fails loudly (exit 2) rather than hanging the caller indefinitely
# (D-06/D-12). No stale-lock cleanup is needed: flock is a kernel-level
# advisory lock that releases automatically once every copy of its
# descriptor is closed, including by process exit (D-08) -- see
# _vigil_close_lock_fd above for why children must not keep their own
# copy. Both vigil-queue mutations and vigil-publish mode flips MUST go
# through this helper so neither can read-modify-write @vigil_* state
# concurrently (T-03-03).
#
# Not re-entrant across calls in the same process: `exec {FD}>` allocates
# a NEW descriptor and overwrites VIGIL_LOCK_FD each time, so without
# releasing first, a second in-process call would leak the first FD (and
# its lock), then deadlock against its own still-held lock until the 2s
# timeout exits the whole process (WR-01). Release any previously held
# lock before reacquiring so composing two locked operations in one
# process degrades to "the second call re-locks" rather than a crash.
#
# Do not call this from vigil.tmux: it may exit on lock timeout.
vigil_with_lock() {
	local lock_file
	lock_file="$(vigil_lock_file)"
	vigil_ensure_runtime_dir
	vigil_release_lock
	exec {VIGIL_LOCK_FD}>"$lock_file"
	# WR-07: `exec {FD}>` creates the lock file under the caller's
	# ambient umask (e.g. 0644 under the common 022), not the 0700 the
	# leaf directory above is hardened to. The leaf's permissions
	# protect it via directory traversal in the common case, but chmod
	# it explicitly too so the file's own permissions match the stated
	# guarantee regardless of umask.
	chmod 600 "$lock_file" 2>/dev/null || true
	if ! flock -w 2 "$VIGIL_LOCK_FD"; then
		echo "${0##*/}: lock acquisition timed out after 2s" >&2
		exit 2
	fi
	"$@"
}

# vigil_in_tmux — 0 only when $TMUX is non-empty and tmux is on PATH.
vigil_in_tmux() {
	[[ -n "${TMUX:-}" ]] && command -v tmux >/dev/null 2>&1
}

# vigil_valid_pane_id <pane_id> — 0 only when <pane_id> matches
# tmux's own #{pane_id} shape exactly ("%" followed by one or more
# digits, e.g. "%7", "%123"). Defense-in-depth (ASVS V5): every
# caller that interpolates a pane_id into a tmux/kitten command
# argument or an OSC 99 payload string should validate it with this
# first, even though pane_id values are already sourced exclusively
# from vigil-queue's own tmux-generated #{pane_id} strings, never
# from pane content/title -- a corrupted or hand-edited queue.json
# must never be able to smuggle something else through this path.
vigil_valid_pane_id() {
	[[ "${1:-}" =~ ^%[0-9]+$ ]]
}

# vigil_read_queue_count — echoes an integer >= 0; 0 when queue.json is
# absent, unreadable, or not {"queue":[...]}.
vigil_read_queue_count() {
	local queue_file count
	# CR-03: close this process's copy of the lock FD UNCONDITIONALLY,
	# before doing anything else. Every call site -- the
	# count="$(vigil_read_queue_count)" inside vigil_publish_state (the
	# highest-frequency instance: reached on every queue mutation via
	# _vigil_mutation and every vigil-publish invocation, while the lock
	# is still held) and the equivalent call in vigil.tmux (lock-free,
	# where VIGIL_LOCK_FD is unset and this is a no-op) -- already
	# invokes this function from inside a "$(...)" command substitution
	# subshell, so this only ever closes that subshell's own copy,
	# never the real holder's. Closing it FIRST (before vigil_queue_file
	# resolves the runtime dir, which may itself fork a sha1sum/shasum/
	# openssl child via _vigil_sha1_16 when $TMUX is set, and before the
	# jq call below) covers every child this function spawns.
	_vigil_close_lock_fd
	queue_file="$(vigil_queue_file)"
	if [[ ! -s "$queue_file" ]]; then
		printf '0'
		return 0
	fi
	count="$(jq -r 'if (.queue | type) == "array" then (.queue | length) else empty end' "$queue_file" 2>/dev/null || true)"
	if [[ -z "$count" ]]; then
		count=0
	fi
	printf '%s' "$count"
}

# vigil_usage_segment — render the cached provider usage/balance (v1.2).
# Cache-only: NEVER performs network I/O (RENDER-02), so it is safe on
# every status redraw. Prints nothing when the cache is absent, empty,
# or unreadable. Fixed provider colors identify each entry; no name text.
# DeepSeek #4d6bfe, Claude #d97757.
# Markers: "!" = the last refresh failed, "~" = cache older than 45 min.
vigil_usage_segment() {
	local cache now fields
	cache="$(vigil_usage_cache_file)"
	[[ -s "$cache" ]] || return 0
	command -v jq >/dev/null 2>&1 || return 0

	now="$(date +%s)"
	# Read every field in one jq pass. The separator is U+001F, NOT a
	# tab: tab is IFS whitespace, so `read` would collapse runs of
	# empty fields and silently shift every value.
	fields="$(jq -r --argjson now "$now" '
		[ (.deepseek.usd // ""),
		  (.deepseek.cny // ""),
		  (.deepseek.error // ""),
		  (.deepseek.fetched_at // ""),
		  (.claude.five_hour_pct // ""),
		  (.claude.seven_day_pct // ""),
		  (.claude.error // "") ] | map(tostring) | join("\u001f")
	' "$cache" 2>/dev/null)" || return 0

	local ds_usd ds_cny ds_err ds_at cl5 cl7 cl_err
	IFS=$'\x1f' read -r ds_usd ds_cny ds_err ds_at cl5 cl7 cl_err <<<"$fields"

	local out="" ds="" marker="" age
	if [[ -n "$ds_err" ]]; then
		marker="!"
	elif [[ -n "$ds_at" ]]; then
		age="$(jq -rn --arg t "$ds_at" --argjson now "$now" \
			'($now - ($t | fromdateiso8601))' 2>/dev/null || printf '0')"
		if [[ "$age" =~ ^[0-9]+$ ]] && ((age > 2700)); then
			marker="~"
		fi
	fi
	if [[ -n "$ds_usd" || -n "$ds_cny" ]]; then
		ds="${marker}\$${ds_usd:-–}/${ds_cny:-–}元"
	elif [[ -n "$ds_err" ]]; then
		ds="!DS"
	fi
	if [[ -n "$ds" ]]; then
		out="#[fg=#4d6bfe]${ds}#[default]"
	fi

	local cl="" cl5s="" cl7s=""
	if [[ -n "$cl_err" ]]; then
		cl="!CL"
	elif [[ -n "$cl5" || -n "$cl7" ]]; then
		[[ -n "$cl5" ]] && cl5s="${cl5}%"
		[[ -n "$cl7" ]] && cl7s="${cl7}%"
		cl="${cl5s:-–}/${cl7s:-–}"
	fi
	if [[ -n "$cl" ]]; then
		out="${out:+$out }#[fg=#d97757]${cl}#[default]"
	fi

	printf '%s' "$out"
}

# vigil_render_status <count> <auto> — the ONLY place the status format
# string is built. Uses no pane-derived data and no #() command
# substitution (Pitfall 5).
vigil_render_status() {
	local count="$1" auto="$2" base usage
	if [[ "$auto" == "on" ]]; then
		base="#[fg=white]${count} Vigil #[fg=green]●#[default]"
	else
		base="#[fg=white]${count} Vigil #[fg=red]●#[default]"
	fi
	usage="$(vigil_usage_segment)"
	if [[ -n "$usage" ]]; then
		printf '%s %s' "$base" "$usage"
	else
		printf '%s' "$base"
	fi
}

# vigil_refresh_clients — per-client status refresh; no-op when detached.
vigil_refresh_clients() {
	local clients client
	vigil_in_tmux || return 0
	clients="$(
		_vigil_close_lock_fd
		tmux list-clients -F '#{client_name}' 2>/dev/null || true
	)"
	[[ -n "$clients" ]] || return 0
	while IFS= read -r client; do
		[[ -n "$client" ]] || continue
		(
			_vigil_close_lock_fd
			tmux refresh-client -S -t "$client"
		) 2>/dev/null || true
	done <<<"$clients"
	return 0
}

# vigil_publish_state [auto] — publish count/auto/rendered status. No-op
# outside tmux. Callers MUST hold the queue lock (see vigil_with_lock)
# for the duration of this call; callers are responsible for calling
# vigil_release_lock + vigil_refresh_clients themselves AFTER this
# returns (WR-05) -- the refresh is a redraw request that writes no
# state, so it does not need to be inside the critical section, and
# keeping it out bounds the lock-hold time to just the option writes
# below. Every tmux call is best-effort so a dead server cannot fail a
# queue mutation (D-03/D-05).
#
# CR-01: each tmux invocation below runs in a subshell that closes this
# process's copy of the lock FD before exec'ing tmux (_vigil_close_lock_fd),
# so a tmux child that is still running when the holder is killed cannot
# keep the flock held. The parent process's own hold on the lock is
# unaffected -- only the forked child's copy is closed.
#
# WR-05: the three @vigil_* writes are batched into a SINGLE tmux
# invocation (tmux's own "cmd1 \; cmd2 \; cmd3" multi-command syntax)
# instead of three separate execs, shrinking both the number of
# processes forked and the wall-clock time spent inside the lock's
# hardcoded 2s timeout.
vigil_publish_state() {
	local auto count status
	if ! vigil_in_tmux; then
		return 0
	fi
	auto="${1:-}"
	if [[ -z "$auto" ]]; then
		auto="$(
			_vigil_close_lock_fd
			tmux show-options -gv @vigil_auto 2>/dev/null || true
		)"
	fi
	if [[ "$auto" != "on" ]]; then
		auto="off"
	fi
	count="$(vigil_read_queue_count)"
	status="$(vigil_render_status "$count" "$auto")"
	# IN-01: redirect stdout too, not just stderr. In current tmux
	# set-option prints nothing on stdout on success, so this is defense
	# in depth -- but a future tmux version (or a user's tmux config/hook)
	# that ever makes set-option/refresh-client emit stdout would
	# otherwise silently concatenate onto cmd_rotate's single-line
	# pane_id contract, the only mutation that returns meaningful stdout
	# to its caller.
	(
		_vigil_close_lock_fd
		tmux set-option -g @vigil_queue_count "$count" \; \
			set-option -g @vigil_auto "$auto" \; \
			set-option -g @vigil_status "$status"
	) >/dev/null 2>&1 || true
}
