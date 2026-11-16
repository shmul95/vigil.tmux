#!/usr/bin/env bats
# hook_dedup.bats — DETECT-04 end-to-end proof: invokes the real
# vigil-hook-stop and vigil-hook-notification scripts in sequence
# (not a unit test of enqueue alone) to prove a Stop followed by an
# allow-listed Notification for the same pane -- in either firing
# order -- collapses to exactly one queue entry, via zero new dedup
# code (Phase 2's append-if-absent `vigil-queue enqueue` is already
# idempotent per pane_id).

load '../test_helper'

setup() {
	setup_vigil_runtime
	fixtures="$BATS_TEST_DIRNAME/../fixtures/hooks"
}

@test "DETECT-04: Stop followed by an allow-listed Notification for the same pane produces exactly one queue entry" {
	# Deviation from the plan's literal example (Rule 1 - bug): single
	# quotes around the `bash -c '...'` body mean $BATS_TEST_DIRNAME is
	# never expanded by the outer bats shell, and bats does not export
	# that variable into child processes either -- the nested shell sees
	# an empty path and fails to find the fixture. $fixtures is resolved
	# once in `setup` (outer bats shell) and interpolated here instead.
	TMUX_PANE='%7' run bash -c "vigil-hook-stop < '$fixtures/stop.json'"
	[ "$status" -eq 0 ]
	[ "$(vigil-queue count)" = "1" ]

	TMUX_PANE='%7' run bash -c "vigil-hook-notification < '$fixtures/notification_idle_prompt.json'"
	[ "$status" -eq 0 ]

	# The pane was already queued by Stop; the later allow-listed
	# Notification for the SAME pane must not create a second entry.
	[ "$(vigil-queue count)" = "1" ]
	[ "$(vigil-queue peek | jq -r '.pane_id')" = "%7" ]
}

@test "DETECT-04 reverse order: an allow-listed Notification followed by Stop for the same pane also collapses to one entry" {
	TMUX_PANE='%7' run bash -c "vigil-hook-notification < '$fixtures/notification_idle_prompt.json'"
	[ "$status" -eq 0 ]
	[ "$(vigil-queue count)" = "1" ]

	TMUX_PANE='%7' run bash -c "vigil-hook-stop < '$fixtures/stop.json'"
	[ "$status" -eq 0 ]
	[ "$(vigil-queue count)" = "1" ]
}

@test "DETECT-04: Stop for two DIFFERENT panes each produces its own entry (dedup is per-pane, not global)" {
	TMUX_PANE='%7' run bash -c "vigil-hook-stop < '$fixtures/stop.json'"
	[ "$status" -eq 0 ]
	TMUX_PANE='%9' run bash -c "vigil-hook-stop < '$fixtures/stop.json'"
	[ "$status" -eq 0 ]
	[ "$(vigil-queue count)" = "2" ]
}
