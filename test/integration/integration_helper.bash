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

	# WR-04: the whole point of this helper is that tests never touch a
	# developer's live server. That isolation previously depended
	# entirely on bats' implicit `set -e` aborting setup() if
	# display-message failed -- nothing actually validated the returned
	# path. tmux resolves TMUX=",0,0" (an empty socket path) to the
	# DEFAULT socket rather than failing, so a display-message that
	# succeeds with empty output would silently point every subsequent
	# `tmux` call in the test at the developer's real server. Fail
	# loudly on both emptiness and a path outside this test's own
	# isolated TMUX_TMPDIR.
	local socket
	if ! socket="$(TMUX_TMPDIR="$VIGIL_TEST_TMUX_TMPDIR" tmux -L "$VIGIL_TEST_SOCKET" display-message -p '#{socket_path}')" ||
		[[ -z "$socket" ]]; then
		echo "failed to start isolated tmux server" >&2
		return 1
	fi
	if [[ "$socket" != "$VIGIL_TEST_TMUX_TMPDIR"/* ]]; then
		echo "refusing: socket '$socket' is outside the isolated TMUX_TMPDIR" >&2
		return 1
	fi
	export TMUX="$socket,0,0"
	# Also export TMUX_TMPDIR for the test process itself, so any stray
	# plain `tmux` invocation in a test body (not routed through this
	# helper's explicit -L/TMUX_TMPDIR pair) still cannot reach the
	# default socket directory.
	export TMUX_TMPDIR="$VIGIL_TEST_TMUX_TMPDIR"
}

vigil_test_server_stop() {
	if [[ -n "${VIGIL_TEST_SOCKET:-}" ]]; then
		TMUX_TMPDIR="${VIGIL_TEST_TMUX_TMPDIR:-/tmp}" tmux -L "$VIGIL_TEST_SOCKET" kill-server 2>/dev/null || true
	fi
	if [[ -n "${VIGIL_TEST_TMUX_TMPDIR:-}" ]]; then
		rm -rf "$VIGIL_TEST_TMUX_TMPDIR"
	fi
	unset TMUX VIGIL_TEST_SOCKET VIGIL_TEST_TMUX_TMPDIR TMUX_TMPDIR
}

vigil_load_plugin() {
	bash "$BATS_TEST_DIRNAME/../../vigil.tmux"
}
