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
		socket_name="$(basename "$socket_path")"
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

	# Shared "vigil" parent (only present on the /tmp fallback path) must
	# stay traversable by every local user, like /tmp itself. SC2174 ("-m
	# only applies to the deepest directory with -p") doesn't apply here:
	# $parent's own parent ("$base", either /tmp or $XDG_RUNTIME_DIR) is
	# always pre-existing, so this call only ever creates the single
	# "vigil" directory and -m always lands on it.
	# shellcheck disable=SC2174
	mkdir -p -m 1777 "$parent"

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
