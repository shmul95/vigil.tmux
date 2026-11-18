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
	vigil_test_detach_client
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

# vigil_test_attach_client — spawns a genuine, non-interactive
# control-mode tmux client attached to "main" on the private test
# server, backed by a FIFO so the client process has a readable,
# never-closed stdin (a plain `-C attach-session` with a closed or
# non-piped stdin exits immediately; control mode needs an open,
# continuously-live input stream to stay attached). Required for
# any assertion that depends on `switch-client` actually doing
# something: empirically, `tmux switch-client -t <pane>` against a
# server with ZERO attached clients fails outright ("no current
# client") -- there is nothing for it to switch. Multi-attached-
# client support is out of scope for v1 (REQUIREMENTS.md), so
# exactly one control-mode client is sufficient for every test that
# needs real navigation to be observable.
vigil_test_attach_client() {
	VIGIL_TEST_CLIENT_FIFO="$(mktemp -u)"
	mkfifo "$VIGIL_TEST_CLIENT_FIFO"
	(
		exec 9<>"$VIGIL_TEST_CLIENT_FIFO"
		TMUX_TMPDIR="$VIGIL_TEST_TMUX_TMPDIR" tmux -L "$VIGIL_TEST_SOCKET" -C attach-session -t main <&9 >/dev/null 2>&1 &
		echo $! >"${VIGIL_TEST_CLIENT_FIFO}.pid"
	)
	# Poll (up to 1s) for the client to actually register with the
	# server before returning control to the caller -- the
	# background subshell above returns almost immediately, well
	# before tmux has necessarily finished the attach handshake.
	local i
	for i in 1 2 3 4 5 6 7 8 9 10; do
		if [[ -n "$(TMUX_TMPDIR="$VIGIL_TEST_TMUX_TMPDIR" tmux -L "$VIGIL_TEST_SOCKET" list-clients 2>/dev/null)" ]]; then
			return 0
		fi
		sleep 0.1
	done
	echo "vigil_test_attach_client: client never registered" >&2
	return 1
}

# vigil_test_detach_client — kills the control-mode client spawned
# by vigil_test_attach_client (if any) and removes its FIFO. Safe
# to call even when no client was ever attached.
vigil_test_detach_client() {
	if [[ -n "${VIGIL_TEST_CLIENT_FIFO:-}" ]]; then
		if [[ -f "${VIGIL_TEST_CLIENT_FIFO}.pid" ]]; then
			kill "$(cat "${VIGIL_TEST_CLIENT_FIFO}.pid")" 2>/dev/null || true
			rm -f "${VIGIL_TEST_CLIENT_FIFO}.pid"
		fi
		rm -f "$VIGIL_TEST_CLIENT_FIFO"
	fi
	unset VIGIL_TEST_CLIENT_FIFO
}

# vigil_test_stub_claude — creates a stub "claude" binary that logs
# its full argv (one invocation per line) to
# $VIGIL_TEST_CLAUDE_LOG and then sleeps indefinitely (mirrors a
# real, long-running Claude Code session so the spawned tmux window
# stays alive for the remainder of the test -- a stub that exits
# immediately would let tmux close/remove the window before a test
# can assert against it, per `remain-on-exit`'s default-off
# behavior). Exports VIGIL_CLAUDE_BIN to the stub's own absolute
# path -- NOT a PATH prepend -- so vigil-task-spawn's own
# `command -v "${VIGIL_CLAUDE_BIN:-claude}"` resolution (run in the
# SCRIPT's process, never the tmux server's environment snapshot,
# 08-RESEARCH.md Pitfall 2) finds it directly regardless of when
# the disposable server was started relative to this export. The
# real `claude` binary requires interactive auth and is long-running
# -- it must never be invoked by this suite.
vigil_test_stub_claude() {
	VIGIL_TEST_CLAUDE_DIR="$(mktemp -d)"
	VIGIL_TEST_CLAUDE_LOG="$VIGIL_TEST_CLAUDE_DIR/invocations.log"
	: >"$VIGIL_TEST_CLAUDE_LOG"
	cat >"$VIGIL_TEST_CLAUDE_DIR/claude" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$VIGIL_TEST_CLAUDE_LOG"
exec sleep 86400
STUB
	chmod +x "$VIGIL_TEST_CLAUDE_DIR/claude"
	export VIGIL_CLAUDE_BIN="$VIGIL_TEST_CLAUDE_DIR/claude"
	export VIGIL_TEST_CLAUDE_LOG
}

# vigil_test_stub_claude_cleanup — removes the stub directory and
# log created by vigil_test_stub_claude. Safe to call even if that
# was never invoked.
vigil_test_stub_claude_cleanup() {
	if [[ -n "${VIGIL_TEST_CLAUDE_DIR:-}" ]]; then
		rm -rf "$VIGIL_TEST_CLAUDE_DIR"
	fi
	unset VIGIL_CLAUDE_BIN VIGIL_TEST_CLAUDE_DIR VIGIL_TEST_CLAUDE_LOG
}
