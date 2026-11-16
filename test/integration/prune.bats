#!/usr/bin/env bats
# prune.bats — QUEUE-03 proof against a REAL tmux server: the
# pane-exited fast path for a pane's own process exiting normally,
# and the lazy prune-on-read backstop vigil-advance runs before
# every navigation decision -- self-healing even with ZERO hooks
# ever registered (the literal must-have from 05-CONTEXT.md's
# two-layer design and this phase's quality gate).

load '../test_helper'
load 'integration_helper'

setup() {
	setup_vigil_runtime
	unset TMUX
	vigil_test_server_start
}

teardown() {
	vigil_test_detach_client
	vigil_test_server_stop
	rm -rf "${VIGIL_RUNTIME_DIR:-}"
}

@test "QUEUE-03 fast path: a pane's own process exiting normally self-prunes via pane-exited, with no Alt+v" {
	tmux split-window -t main -d
	PANE_A="$(tmux list-panes -t main -F '#{pane_id}' | sed -n '1p')"
	PANE_B="$(tmux list-panes -t main -F '#{pane_id}' | sed -n '2p')"

	vigil_load_plugin
	vigil-queue enqueue "$PANE_A"
	vigil-queue enqueue "$PANE_B"
	[ "$(vigil-queue count)" = "2" ]

	# Natural process exit -- NOT kill-pane -- is what actually fires
	# pane-exited (PITFALLS.md Pitfall 6).
	tmux send-keys -t "$PANE_A" 'exit' Enter

	local i
	for i in 1 2 3 4 5 6 7 8 9 10; do
		[ "$(vigil-queue count)" = "1" ] && break
		sleep 0.2
	done
	[ "$(vigil-queue count)" = "1" ]
	[ "$(vigil-queue peek | jq -r '.pane_id')" = "$PANE_B" ]
}

@test "QUEUE-03 backstop: tmux kill-pane fires no hook at all, yet Alt+v still self-heals with zero hooks ever registered" {
	# Deliberately never load vigil.tmux in this test -- there is no
	# pane-exited hook registered on this server at any point, not
	# merely one that happened not to fire yet. This is the phase's
	# explicit quality-gate scenario.
	tmux split-window -t main -d
	tmux split-window -t main -d
	PANE_A="$(tmux list-panes -t main -F '#{pane_id}' | sed -n '1p')"
	PANE_B="$(tmux list-panes -t main -F '#{pane_id}' | sed -n '2p')"
	PANE_C="$(tmux list-panes -t main -F '#{pane_id}' | sed -n '3p')"
	vigil_test_attach_client

	vigil-queue enqueue "$PANE_A"
	vigil-queue enqueue "$PANE_B"
	tmux select-pane -t "$PANE_C"

	# kill-pane fires NO tmux hook (PITFALLS.md Pitfall 6, empirically
	# confirmed) -- exactly the scenario the lazy prune-on-read
	# backstop exists for.
	tmux kill-pane -t "$PANE_A"
	[[ "$(tmux list-panes -a -F '#{pane_id}')" != *"$PANE_A"* ]]

	run vigil-advance
	[ "$status" -eq 0 ]

	[ "$(tmux display-message -p '#{pane_id}')" = "$PANE_B" ]
	[ "$(vigil-queue count)" = "1" ]
	[ "$(vigil-queue peek | jq -r '.pane_id')" = "$PANE_B" ]
}
