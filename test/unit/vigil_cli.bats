#!/usr/bin/env bats
# vigil_cli.bats — coverage for scripts/vigil, the manual control
# surface (`vigil cron|attach <workflow>`). The attach path is driven
# against a PATH-prepended tmux stub, so no real tmux server is
# touched; the `cron eip` test drives the real vigil-task-cron
# against an empty tasks directory; the `cron thu` tests drive a
# PATH-prepended systemctl stub, so no real systemd user manager is
# touched.

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
	SYSTEMCTL_LOG="$STUB_DIR/systemctl.log"
	: >"$SYSTEMCTL_LOG"
	export SYSTEMCTL_LOG
	cat >"$STUB_DIR/bin/systemctl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\$SYSTEMCTL_LOG"
if [[ "\$*" == "--user start --wait tsinghua-lms-producer.service" && -f "$STUB_DIR/producer-fail" ]]; then
  exit 1
fi
exit 0
STUB
	chmod +x "$STUB_DIR/bin/systemctl"
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
	[[ "$stderr" == *"usage: vigil <action> <workflow>"* ]]
	[ ! -s "$TMUX_LOG" ]
}

@test "an unknown action prints usage and exits 2" {
	run --separate-stderr "$CLI" frobnicate eip
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"usage: vigil <action> <workflow>"* ]]
}

@test "vigil cron eip runs the real task cron now and hints at attach" {
	run --separate-stderr "$CLI" cron eip
	[ "$status" -eq 0 ]
	[[ "$output" == *"vigil-task-cron: 0 tasks found, 0 spawned"* ]]
	[[ "$stderr" == *"attach with 'vigil attach eip'"* ]]
	[ ! -s "$TMUX_LOG" ]
}

@test "a workflow with no registered cron is rejected" {
	run --separate-stderr "$CLI" cron bogus-workflow
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"no cron registered for workflow 'bogus-workflow'"* ]]
}

@test "vigil cron thu runs producer then consumer and exits 0" {
	run --separate-stderr "$CLI" cron thu
	[ "$status" -eq 0 ]
	producer_line="$(grep -n "start --wait tsinghua-lms-producer.service" "$SYSTEMCTL_LOG" | head -1 | cut -d: -f1)"
	consumer_line="$(grep -n "start --wait tsinghua-lms-consumer.service" "$SYSTEMCTL_LOG" | head -1 | cut -d: -f1)"
	[ -n "$producer_line" ]
	[ -n "$consumer_line" ]
	[ "$producer_line" -lt "$consumer_line" ]
}

@test "vigil cron thu fails loudly if the producer fails and never runs the consumer" {
	touch "$STUB_DIR/producer-fail"
	run --separate-stderr "$CLI" cron thu
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"tsinghua-lms-producer.service"* ]]
	[ "$(grep -cF "tsinghua-lms-consumer.service" "$SYSTEMCTL_LOG")" -eq 0 ]
}

@test "vigil attach eip creates eip with the keeper window, then attaches" {
	run "$CLI" attach eip
	[ "$status" -eq 0 ]
	grep -qF "has-session -t eip" "$TMUX_LOG"
	grep -qF "new-session -d -s eip -n vigil-home" "$TMUX_LOG"
	grep -qF "attach -t eip" "$TMUX_LOG"
}

@test "vigil attach eip switches the client when already inside tmux" {
	touch "$STUB_DIR/has-session-ok"
	export TMUX="stub,0,0"
	run "$CLI" attach eip
	[ "$status" -eq 0 ]
	grep -qF "has-session -t eip" "$TMUX_LOG"
	[ "$(grep -cF "new-session" "$TMUX_LOG")" -eq 0 ]
	grep -qF "switch-client -t eip" "$TMUX_LOG"
}

@test "attach to a missing session Vigil does not own fails clearly" {
	run --separate-stderr "$CLI" attach thu
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"no tmux session 'thu' to attach to"* ]]
	[ "$(grep -cF "new-session" "$TMUX_LOG")" -eq 0 ]
}
