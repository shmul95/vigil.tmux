#!/usr/bin/env bats
# vigil_cli.bats — coverage for scripts/vigil, the manual control
# surface (`vigil <workflow> cron|attach`). The attach path is driven
# against a PATH-prepended tmux stub, so no real tmux server is
# touched; the `eip cron` test drives the real vigil-task-cron
# against an empty tasks directory.

bats_require_minimum_version 1.5.0

load '../test_helper'

CLI="$BATS_TEST_DIRNAME/../../scripts/vigil"

setup() {
	setup_vigil_runtime
	STUB_DIR="$(mktemp -d)"
	mkdir -p "$STUB_DIR/bin"
	TMUX_LOG="$STUB_DIR/tmux.log"
	: >"$TMUX_LOG"
	export TMUX_LOG
	cat >"$STUB_DIR/bin/tmux" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\$TMUX_LOG"
case "\$1" in
  has-session) [[ -f "$STUB_DIR/has-session-ok" ]] && exit 0 || exit 1 ;;
  *) exit 0 ;;
esac
STUB
	chmod +x "$STUB_DIR/bin/tmux"
	export PATH="$STUB_DIR/bin:$PATH"
	# The real sweep, with nothing to read: fast, no gh/claude calls.
	VIGIL_TASKS_DIR="$(mktemp -d)"
	export VIGIL_TASKS_DIR
}

teardown() {
	rm -rf "${VIGIL_RUNTIME_DIR:-}" "${STUB_DIR:-}" "${VIGIL_TASKS_DIR:-}"
}

@test "no arguments prints usage and exits 2" {
	run --separate-stderr "$CLI"
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"usage: vigil <workflow> <action>"* ]]
	[ ! -s "$TMUX_LOG" ]
}

@test "an unknown action prints usage and exits 2" {
	run --separate-stderr "$CLI" eip frobnicate
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"usage: vigil <workflow> <action>"* ]]
}

@test "vigil eip cron runs the real task cron now and hints at attach" {
	run --separate-stderr "$CLI" eip cron
	[ "$status" -eq 0 ]
	[[ "$output" == *"vigil-task-cron: 0 tasks found, 0 spawned"* ]]
	[[ "$stderr" == *"attach with 'vigil eip attach'"* ]]
	[ ! -s "$TMUX_LOG" ]
}

@test "a workflow with no registered cron is rejected" {
	run --separate-stderr "$CLI" thu cron
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"no cron registered for workflow 'thu'"* ]]
}

@test "vigil eip attach creates eip with the keeper window, then attaches" {
	run "$CLI" eip attach
	[ "$status" -eq 0 ]
	grep -qF "has-session -t eip" "$TMUX_LOG"
	grep -qF "new-session -d -s eip -n vigil-home" "$TMUX_LOG"
	grep -qF "attach -t eip" "$TMUX_LOG"
}

@test "vigil eip attach switches the client when already inside tmux" {
	touch "$STUB_DIR/has-session-ok"
	export TMUX="stub,0,0"
	run "$CLI" eip attach
	[ "$status" -eq 0 ]
	grep -qF "has-session -t eip" "$TMUX_LOG"
	[ "$(grep -cF "new-session" "$TMUX_LOG")" -eq 0 ]
	grep -qF "switch-client -t eip" "$TMUX_LOG"
}

@test "attach to a missing session Vigil does not own fails clearly" {
	run --separate-stderr "$CLI" thu attach
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"no tmux session 'thu' to attach to"* ]]
	[ "$(grep -cF "new-session" "$TMUX_LOG")" -eq 0 ]
}
