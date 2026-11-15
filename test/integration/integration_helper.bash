#!/usr/bin/env bash
# integration_helper.bash — disposable tmux server lifecycle for Vigil tests.
#
# Every helper here operates on a private tmux server started with a unique
# `-L` socket under a fresh TMUX_TMPDIR, so integration tests can drive the
# plugin against a real tmux(1) without ever touching a developer's live
# server. `vigil_test_server_stop` kills that server and removes its tempdir.

vigil_test_server_start() {
	export VIGIL_TEST_SOCKET="vigil-test-$$-${BATS_TEST_NUMBER:-0}-${RANDOM}"
	export VIGIL_TEST_TMUX_TMPDIR="$(mktemp -d)"
	TMUX_TMPDIR="$VIGIL_TEST_TMUX_TMPDIR" tmux -L "$VIGIL_TEST_SOCKET" -f /dev/null new-session -d -s main
	local socket
	socket="$(TMUX_TMPDIR="$VIGIL_TEST_TMUX_TMPDIR" tmux -L "$VIGIL_TEST_SOCKET" display-message -p '#{socket_path}')"
	export TMUX="$socket,0,0"
}

vigil_test_server_stop() {
	if [[ -n "${VIGIL_TEST_SOCKET:-}" ]]; then
		TMUX_TMPDIR="${VIGIL_TEST_TMUX_TMPDIR:-/tmp}" tmux -L "$VIGIL_TEST_SOCKET" kill-server 2>/dev/null || true
	fi
	if [[ -n "${VIGIL_TEST_TMUX_TMPDIR:-}" ]]; then
		rm -rf "$VIGIL_TEST_TMUX_TMPDIR"
	fi
	unset TMUX VIGIL_TEST_SOCKET VIGIL_TEST_TMUX_TMPDIR
}

vigil_load_plugin() {
	bash "$BATS_TEST_DIRNAME/../../vigil.tmux"
}
