#!/usr/bin/env bats
# hook_userpromptsubmit.bats — behavior coverage for
# vigil-hook-userpromptsubmit, the Claude Code UserPromptSubmit hook
# client (DETECT-03/NAV-04: submitting a prompt dequeues the firing
# pane).

load '../test_helper'

@test "dequeues the firing pane when it is currently queued" {
	vigil-queue enqueue '%7'
	TMUX_PANE='%7' run bash -c "vigil-hook-userpromptsubmit < '$BATS_TEST_DIRNAME/../fixtures/hooks/userpromptsubmit.json'"
	[ "$status" -eq 0 ]
	[ "$(vigil-queue count)" = "0" ]
}

@test "no-ops cleanly when the firing pane is not currently queued" {
	TMUX_PANE='%7' run bash -c "vigil-hook-userpromptsubmit < '$BATS_TEST_DIRNAME/../fixtures/hooks/userpromptsubmit.json'"
	[ "$status" -eq 0 ]
	[ "$(vigil-queue count)" = "0" ]
}

@test "fails closed (no dequeue) when TMUX_PANE is unset" {
	vigil-queue enqueue '%7'
	unset TMUX_PANE
	run bash -c "unset TMUX_PANE; vigil-hook-userpromptsubmit < '$BATS_TEST_DIRNAME/../fixtures/hooks/userpromptsubmit.json'"
	[ "$status" -eq 0 ]
	[ "$(vigil-queue count)" = "1" ]
}

@test "VIGIL_DEBUG=1 emits a stderr trace line mentioning the hook" {
	TMUX_PANE='%7' VIGIL_DEBUG=1 run bash -c "vigil-hook-userpromptsubmit < '$BATS_TEST_DIRNAME/../fixtures/hooks/userpromptsubmit.json'"
	[ "$status" -eq 0 ]
	[[ "$output" == *"UserPromptSubmit"* || "$output" == *"vigil-hook-userpromptsubmit"* ]]
}
