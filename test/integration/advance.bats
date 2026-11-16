#!/usr/bin/env bats
# advance.bats — NAV-01/NAV-02/NAV-03 proof for `vigil-advance`
# against a REAL, disposable tmux server with a genuine attached
# client (required: `switch-client` is a no-op error with none
# attached -- see integration_helper.bash's vigil_test_attach_client).

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

@test "NAV-01: jumps to the head pane without changing queue order when not already on it" {
	tmux select-pane -t "$PANE_C"
	vigil-queue enqueue "$PANE_A"
	vigil-queue enqueue "$PANE_B"

	run vigil-advance
	[ "$status" -eq 0 ]

	[ "$(tmux display-message -p '#{pane_id}')" = "$PANE_A" ]
	[ "$(vigil-queue peek | jq -r '.pane_id')" = "$PANE_A" ]
	[ "$(vigil-queue count)" = "2" ]
}

@test "NAV-02: rotates the head to the back and jumps to the new head when already on it" {
	tmux select-pane -t "$PANE_A"
	vigil-queue enqueue "$PANE_A"
	vigil-queue enqueue "$PANE_B"
	vigil-queue enqueue "$PANE_C"

	run vigil-advance
	[ "$status" -eq 0 ]

	[ "$(tmux display-message -p '#{pane_id}')" = "$PANE_B" ]
	[ "$(vigil-queue peek | jq -r '.pane_id')" = "$PANE_B" ]
	[ "$(vigil-queue count)" = "3" ]
}

@test "NAV-03: an empty queue flashes the exact message and does not change focus" {
	tmux select-pane -t "$PANE_A"
	[ "$(vigil-queue count)" = "0" ]

	local real_tmux stub_dir
	real_tmux="$(command -v tmux)"
	stub_dir="$(mktemp -d)"
	cat >"$stub_dir/tmux" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "display-message" && "\$2" != "-p" ]]; then
	echo "\$*" >>"$stub_dir/messages.log"
fi
exec "$real_tmux" "\$@"
STUB
	chmod +x "$stub_dir/tmux"

	PATH="$stub_dir:$PATH" run vigil-advance
	[ "$status" -eq 0 ]
	[ -f "$stub_dir/messages.log" ]
	grep -q "Vigil: nothing waiting" "$stub_dir/messages.log"

	[ "$(tmux display-message -p '#{pane_id}')" = "$PANE_A" ]

	rm -rf "$stub_dir"
}
