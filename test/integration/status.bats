#!/usr/bin/env bats
# status.bats — end-to-end status contract against a private tmux server.
# Each test is self-contained: bats runs every @test with a fresh
# VIGIL_RUNTIME_DIR and setup() starts a brand-new isolated server, so a
# test may never rely on state left by a previous @test.

load '../test_helper'
load 'integration_helper'

setup() {
	setup_vigil_runtime
	unset TMUX
	vigil_test_server_start
	tmux set-option -g status-right 'USERSEG'
	tmux set-option -g status-interval 60
	vigil_load_plugin
}

teardown() {
	vigil_test_server_stop
	rm -rf "${VIGIL_RUNTIME_DIR:-}"
}

@test "enqueue updates the count and leaves auto off and status-interval intact" {
	vigil-queue enqueue '%1'
	[ "$(tmux show-options -gv @vigil_queue_count)" = '1' ]
	[ "$(tmux show-options -gv @vigil_auto)" = 'off' ]
	[ "$(tmux show-options -gv @vigil_status)" = '1 Vigil #[fg=red]●#[default]' ]
	[ "$(tmux show-options -gv status-interval)" = '60' ]
}

@test "publish on flips auto and renders the white/green status" {
	vigil-queue enqueue '%1'
	vigil-publish on
	[ "$(tmux show-options -gv @vigil_auto)" = 'on' ]
	[ "$(tmux show-options -gv @vigil_status)" = '#[fg=white]1 Vigil #[fg=green]●#[default]' ]
}

@test "enqueue after publish on keeps auto on and increments the white count" {
	vigil-queue enqueue '%1'
	vigil-publish on
	vigil-queue enqueue '%2'
	[ "$(tmux show-options -gv @vigil_queue_count)" = '2' ]
	[ "$(tmux show-options -gv @vigil_auto)" = 'on' ]
	[ "$(tmux show-options -gv @vigil_status)" = '#[fg=white]2 Vigil #[fg=green]●#[default]' ]
}

@test "dequeue removes one entry from the published count" {
	vigil-queue enqueue '%1'
	vigil-queue enqueue '%2'
	vigil-queue dequeue '%1'
	[ "$(tmux show-options -gv @vigil_queue_count)" = '1' ]
}

@test "publish off flips auto off and renders the red status" {
	vigil-queue enqueue '%1'
	vigil-publish on
	vigil-publish off
	[ "$(tmux show-options -gv @vigil_auto)" = 'off' ]
	[ "$(tmux show-options -gv @vigil_status)" = '1 Vigil #[fg=red]●#[default]' ]
}

@test "rotate republishes the unchanged count" {
	vigil-queue enqueue '%1'
	vigil-queue enqueue '%2'
	vigil-queue rotate
	[ "$(tmux show-options -gv @vigil_queue_count)" = '2' ]
	[ "$(tmux show-options -gv @vigil_status)" = '2 Vigil #[fg=red]●#[default]' ]
}

@test "prune republishes the surviving count" {
	vigil-queue enqueue '%1'
	vigil-queue enqueue '%2'
	vigil-queue prune '%1'
	[ "$(tmux show-options -gv @vigil_queue_count)" = '1' ]
	[ "$(tmux show-options -gv @vigil_status)" = '1 Vigil #[fg=red]●#[default]' ]
}

@test "dequeue of the last entry publishes a zero count" {
	vigil-queue enqueue '%1'
	vigil-queue dequeue '%1'
	[ "$(tmux show-options -gv @vigil_status)" = '0 Vigil #[fg=red]●#[default]' ]
}

@test "status-right expands to USERSEG plus the published status" {
	vigil-queue enqueue '%1'
	local published
	published="$(tmux show-options -gv @vigil_status)"
	run tmux display-message -p '#{E:status-right}'
	[ "$status" -eq 0 ]
	[ "$output" = "USERSEG $published" ]
}

@test "status rendering uses published options only and never polls" {
	vigil-queue enqueue '%1'
	[ "$(tmux show-options -gv status-interval)" = '60' ]
	run tmux show-options -gv status-right
	[[ "$output" != *'#('* ]]
	run tmux show-options -gv @vigil_status
	[[ "$output" != *'#('* ]]
	run grep -c 'refresh-client -S' "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"
	[ "$status" -eq 0 ]
	[ "$output" -ge 1 ]
}
