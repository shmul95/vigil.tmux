#!/usr/bin/env bash
# vigil-common.sh — shared runtime-path and timestamp helpers for Vigil.
#
# This file is meant to be `source`d (never executed directly) by
# scripts/vigil-queue and future Vigil scripts. It deliberately does NOT
# `set -e`/`set -u` at the top-level, since that would mutate the shell
# options of whatever script sources it.

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
		socket_name="$(printf '%s' "$socket_path" | sha1sum | cut -c1-16)"
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

	find "$dir" -maxdepth 1 -name 'queue.json.tmp.*' -mmin +1 -delete 2>/dev/null || true
}

# vigil_now_iso — echoes the current UTC time in ISO-8601 format.
vigil_now_iso() {
	date -u +%Y-%m-%dT%H:%M:%SZ
}
