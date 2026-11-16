#!/usr/bin/env bats
# hook_pane_identity.bats — proves pane identity is resolved from
# $TMUX_PANE captured at hook-fire time, never from a live "what's
# focused" tmux query (Pitfall 9). Uses a REAL isolated tmux server
# with two distinct panes so a regression to `tmux display-message -p
# '#{pane_id}'` would be caught: that call would return the FOCUSED
# pane (B below), not the one that actually fired the hook (A).

load '../test_helper'
load 'integration_helper'

setup() {
    setup_vigil_runtime
    unset TMUX
    vigil_test_server_start
    tmux split-window -t main -d
    PANE_A="$(tmux list-panes -t main -F '#{pane_id}' | sed -n '1p')"
    PANE_B="$(tmux list-panes -t main -F '#{pane_id}' | sed -n '2p')"
    # Deliberately focus B -- the pane that did NOT fire any hook --
    # so a buggy "query the current pane" implementation would wrongly
    # attribute every hook below to B instead of A.
    tmux select-pane -t "$PANE_B"
}

teardown() {
    vigil_test_server_stop
    rm -rf "${VIGIL_RUNTIME_DIR:-}"
}

@test "Stop fired with TMUX_PANE=A enqueues A, not the focused pane B" {
    [ "$(tmux display-message -p '#{pane_id}')" = "$PANE_B" ]

    TMUX_PANE="$PANE_A" run bash -c "vigil-hook-stop < \"$BATS_TEST_DIRNAME/../fixtures/hooks/stop.json\""
    [ "$status" -eq 0 ]
    [ "$(vigil-queue peek | jq -r '.pane_id')" = "$PANE_A" ]
}

@test "UserPromptSubmit fired with TMUX_PANE=A dequeues A even while client focus is on B" {
    vigil-queue enqueue "$PANE_A"
    [ "$(tmux display-message -p '#{pane_id}')" = "$PANE_B" ]

    TMUX_PANE="$PANE_A" run bash -c "vigil-hook-userpromptsubmit < \"$BATS_TEST_DIRNAME/../fixtures/hooks/userpromptsubmit.json\""
    [ "$status" -eq 0 ]
    [ "$(vigil-queue count)" = "0" ]
}

@test "Notification (allow-listed) fired with TMUX_PANE=A enqueues A, not B" {
    TMUX_PANE="$PANE_A" run bash -c "vigil-hook-notification < \"$BATS_TEST_DIRNAME/../fixtures/hooks/notification_idle_prompt.json\""
    [ "$status" -eq 0 ]
    [ "$(vigil-queue peek | jq -r '.pane_id')" = "$PANE_A" ]
}

@test "DETECT-05: all three hooks exit 0 inside a real tmux session even with a corrupted queue file" {
    echo 'not valid json' > "$VIGIL_RUNTIME_DIR/queue.json"

    TMUX_PANE="$PANE_A" run timeout 5 bash -c "vigil-hook-stop < \"$BATS_TEST_DIRNAME/../fixtures/hooks/stop.json\""
    [ "$status" -eq 0 ]

    TMUX_PANE="$PANE_A" run timeout 5 bash -c "vigil-hook-notification < \"$BATS_TEST_DIRNAME/../fixtures/hooks/notification_idle_prompt.json\""
    [ "$status" -eq 0 ]

    TMUX_PANE="$PANE_A" run timeout 5 bash -c "vigil-hook-userpromptsubmit < \"$BATS_TEST_DIRNAME/../fixtures/hooks/userpromptsubmit.json\""
    [ "$status" -eq 0 ]
}
