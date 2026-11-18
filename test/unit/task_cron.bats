#!/usr/bin/env bats
# task_cron.bats (unit) — CRON-02 structural checks for
# scripts/vigil-task-cron and its schedule documentation. No tmux,
# no network, no fixtures needed.

load '../test_helper'

SCRIPT="$BATS_TEST_DIRNAME/../../scripts/vigil-task-cron"
DOC="$BATS_TEST_DIRNAME/../../docs/vigil-task-cron-schedule.md"

@test "CRON-02: vigil-task-cron exists and is executable" {
	[ -f "$SCRIPT" ]
	[ -x "$SCRIPT" ]
}

@test "CRON-02: vigil-task-cron contains no schedule-registration mechanism" {
	[ -f "$SCRIPT" ]
	run grep -nE 'crontab|systemctl|systemd-run' "$SCRIPT"
	[ "$status" -ne 0 ]
}

@test "CRON-02: schedule doc exists and explicitly states it is not applied automatically" {
	[ -f "$DOC" ]
	run grep -qi 'NOT applied automatically' "$DOC"
	[ "$status" -eq 0 ]
}

@test "CRON-02: schedule doc documents the 15-minute timer with catch-up" {
	run grep -qF 'OnCalendar=*:0/15' "$DOC"
	[ "$status" -eq 0 ]
	run grep -qF 'Persistent=true' "$DOC"
	[ "$status" -eq 0 ]
	run grep -qF 'Type=oneshot' "$DOC"
	[ "$status" -eq 0 ]
}

@test "CRON-02: schedule doc lists jq, gh, and claude as hard prerequisites" {
	run grep -qF 'jq' "$DOC"
	[ "$status" -eq 0 ]
	run grep -qF 'gh' "$DOC"
	[ "$status" -eq 0 ]
	run grep -qF 'claude' "$DOC"
	[ "$status" -eq 0 ]
	run grep -qF 'systemctl --user' "$DOC"
	[ "$status" -eq 0 ]
}
