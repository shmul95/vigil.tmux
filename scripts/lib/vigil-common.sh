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
# Always created with explicit 0700 (never relies on ambient umask) per the
# Information Disclosure mitigation (T-02-03): the runtime dir may live
# under a world-readable /tmp fallback, so permissions must be hardened
# every time, not just on first creation. `mkdir -p -m 700` only applies
# -m to the deepest directory it creates (shellcheck SC2174) — any
# intermediate directories (e.g. the shared "vigil" parent) would fall
# back to the ambient umask, so a temporary umask override guarantees
# every directory created by this call, not just the leaf, is 0700.
vigil_ensure_runtime_dir() {
	local old_umask
	old_umask="$(umask)"
	umask 077
	mkdir -p "$(vigil_runtime_dir)"
	umask "$old_umask"
}

# vigil_now_iso — echoes the current UTC time in ISO-8601 format.
vigil_now_iso() {
	date -u +%Y-%m-%dT%H:%M:%SZ
}
