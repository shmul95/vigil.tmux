#!/usr/bin/env bats
# isolation_guard.bats — proves vigil_test_server_start validates the
# socket path display-message returns instead of trusting it blindly
# (WR-04). tmux resolves TMUX=",0,0" (an empty socket path) to the
# developer's DEFAULT socket rather than failing, so an unchecked read
# failure or empty-but-successful read would silently point every
# subsequent `tmux` call in the test at a live server.
#
# These two tests intentionally do NOT use `run` (which forks a
# subshell to capture output): vigil_test_server_start exports
# VIGIL_TEST_SOCKET/VIGIL_TEST_TMUX_TMPDIR as it starts the real
# isolated server, and a subshell would discard those exports, orphaning
# the server process this test itself started with no way to clean it
# up. Calling the function directly (with stdout/stderr redirected to a
# file) keeps it in the test's own shell so those exports -- and the
# ability to tear the orphaned server down -- survive the simulated
# failure.

load '../test_helper'
load 'integration_helper'

setup() {
	setup_vigil_runtime
	unset TMUX
}

teardown() {
	# The simulated-failure tests below still start a REAL server (the
	# failure is injected at the display-message step, after
	# new-session has already succeeded), so it must be killed with the
	# same TMUX_TMPDIR override vigil_test_server_stop uses -- without
	# it, kill-server looks in the default tmux tmpdir, never finds this
	# socket, and silently leaks the server.
	if [[ -n "${VIGIL_TEST_SOCKET:-}" ]]; then
		TMUX_TMPDIR="${VIGIL_TEST_TMUX_TMPDIR:-/tmp}" tmux -L "$VIGIL_TEST_SOCKET" kill-server 2>/dev/null || true
	fi
	rm -rf "${VIGIL_TEST_TMUX_TMPDIR:-}" "${VIGIL_RUNTIME_DIR:-}"
	unset VIGIL_TEST_SOCKET VIGIL_TEST_TMUX_TMPDIR TMUX TMUX_TMPDIR
}

@test "WR-04: an empty socket_path from display-message fails loudly instead of defaulting to the live socket" {
	local real_tmux stub_dir errfile rc
	real_tmux="$(command -v tmux)"
	stub_dir="$(mktemp -d)"
	errfile="$(mktemp)"
	cat >"$stub_dir/tmux" <<STUB
#!/usr/bin/env bash
if [[ "\$*" == *"display-message"* ]]; then
	exit 0
fi
exec "$real_tmux" "\$@"
STUB
	chmod +x "$stub_dir/tmux"

	rc=0
	PATH="$stub_dir:$PATH" vigil_test_server_start >/dev/null 2>"$errfile" || rc=$?

	[ "$rc" -eq 1 ]
	grep -q "failed to start isolated tmux server" "$errfile"
	[ -z "${TMUX:-}" ]

	rm -rf "$stub_dir" "$errfile"
}

@test "WR-04: a socket outside the isolated TMUX_TMPDIR is refused" {
	local real_tmux stub_dir errfile rc
	real_tmux="$(command -v tmux)"
	stub_dir="$(mktemp -d)"
	errfile="$(mktemp)"
	cat >"$stub_dir/tmux" <<STUB
#!/usr/bin/env bash
if [[ "\$*" == *"display-message"* ]]; then
	printf '/not/the/isolated/tmpdir/socket'
	exit 0
fi
exec "$real_tmux" "\$@"
STUB
	chmod +x "$stub_dir/tmux"

	rc=0
	PATH="$stub_dir:$PATH" vigil_test_server_start >/dev/null 2>"$errfile" || rc=$?

	[ "$rc" -eq 1 ]
	grep -q "refusing: socket" "$errfile"
	[ -z "${TMUX:-}" ]

	rm -rf "$stub_dir" "$errfile"
}

@test "a successful start exports TMUX and TMUX_TMPDIR scoped to the isolated socket" {
	vigil_test_server_start
	[[ "$TMUX" == "$VIGIL_TEST_TMUX_TMPDIR"/* ]]
	[ "$TMUX_TMPDIR" = "$VIGIL_TEST_TMUX_TMPDIR" ]
	vigil_test_server_stop
}
