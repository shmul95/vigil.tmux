#!/usr/bin/env bats
# auto_next.bats — AUTO-03 proof: submitting a prompt while auto
# mode is on automatically jumps to the new FIFO head
# (vigil-advance's NAV-01 jump-only half, applied headlessly from
# the UserPromptSubmit hook), against a REAL disposable tmux
# server with a genuine attached client (switch-client is a no-op
# error with none attached).

load '../test_helper'
load 'integration_helper'

setup() {
	setup_vigil_runtime
	unset TMUX
	vigil_test_server_start
	tmux split-window -t main -d
	tmux split-window -t main -d
	PANE_A="$(tmux list-panes -t main -F '#{pane_id}' | sed -n '1p')"
	PANE_B="$(tmux list-panes -t main -F '#{pane_id}' | sed -n '2p')"
	PANE_C="$(tmux list-panes -t main -F '#{pane_id}' | sed -n '3p')"
	vigil_test_attach_client
}

teardown() {
	vigil_test_detach_client
	vigil_test_server_stop
	rm -rf "${VIGIL_RUNTIME_DIR:-}"
}

@test "AUTO-03: with auto mode on, submitting a prompt jumps to the new FIFO head" {
	tmux set-option -g @vigil_auto on
	tmux select-pane -t "$PANE_C"
	vigil-queue enqueue "$PANE_A"
	vigil-queue enqueue "$PANE_B"

	TMUX_PANE="$PANE_C" run vigil-hook-userpromptsubmit <"$BATS_TEST_DIRNAME/../fixtures/hooks/userpromptsubmit.json"
	[ "$status" -eq 0 ]

	[ "$(tmux display-message -p '#{pane_id}')" = "$PANE_A" ]
	[ "$(vigil-queue peek | jq -r '.pane_id')" = "$PANE_A" ]
	[ "$(vigil-queue count)" = "2" ]
}

@test "AUTO-03: with auto mode off, submitting a prompt dequeues but does NOT jump focus" {
	tmux set-option -g @vigil_auto off
	tmux select-pane -t "$PANE_C"
	vigil-queue enqueue "$PANE_A"

	TMUX_PANE="$PANE_A" run vigil-hook-userpromptsubmit <"$BATS_TEST_DIRNAME/../fixtures/hooks/userpromptsubmit.json"
	[ "$status" -eq 0 ]

	[ "$(tmux display-message -p '#{pane_id}')" = "$PANE_C" ]
	[ "$(vigil-queue count)" = "0" ]
}

@test "AUTO-03: with auto mode on and an empty queue, focus is unchanged" {
	tmux set-option -g @vigil_auto on
	tmux select-pane -t "$PANE_C"

	TMUX_PANE="$PANE_C" run vigil-hook-userpromptsubmit <"$BATS_TEST_DIRNAME/../fixtures/hooks/userpromptsubmit.json"
	[ "$status" -eq 0 ]

	[ "$(tmux display-message -p '#{pane_id}')" = "$PANE_C" ]
}
