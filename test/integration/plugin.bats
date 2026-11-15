#!/usr/bin/env bats
# plugin.bats — real-server coverage for the TPM entrypoint: status-right
# append, idempotence across reloads, default option seeding, and the
# outside-tmux no-op. Every test drives a private `tmux -L` server.

load '../test_helper'
load 'integration_helper'

# vigil_marker_count <string> — number of literal #{@vigil_status} markers.
vigil_marker_count() {
	grep -o '#{@vigil_status}' <<<"$1" | wc -l | tr -d ' '
}

setup() {
	setup_vigil_runtime
	unset TMUX
	vigil_test_server_start
	tmux set-option -g status-right 'USERSEG'
	# Capture the -f /dev/null default BEFORE the plugin first runs so the
	# "does not change status-interval" test compares against the true
	# pre-load value instead of a hardcoded number.
	VIGIL_TEST_INTERVAL_BEFORE="$(tmux show-options -gv status-interval)"
	vigil_load_plugin
}

teardown() {
	vigil_test_server_stop
	rm -rf "${VIGIL_RUNTIME_DIR:-}"
	unset VIGIL_TEST_INTERVAL_BEFORE
}

@test "loading appends the segment once to an existing status-right" {
	run tmux show-options -gv status-right
	[ "$status" -eq 0 ]
	[ "$output" = 'USERSEG #{@vigil_status}' ]
	[ "$(vigil_marker_count "$output")" -eq 1 ]
}

@test "loading twice never duplicates the marker" {
	local before after
	before="$(tmux show-options -gv status-right)"
	vigil_load_plugin
	after="$(tmux show-options -gv status-right)"
	[ "$before" = "$after" ]
	[ "$(vigil_marker_count "$after")" -eq 1 ]
}

@test "an empty status-right yields just the marker with no leading space" {
	tmux set-option -g status-right ''
	vigil_load_plugin
	run tmux show-options -gv status-right
	[ "$output" = '#{@vigil_status}' ]
}

@test "a pre-existing marker is left untouched" {
	tmux set-option -g status-right 'A #{@vigil_status} B'
	vigil_load_plugin
	run tmux show-options -gv status-right
	[ "$output" = 'A #{@vigil_status} B' ]
}

@test "first load seeds auto off, count zero, and the red status string" {
	tmux set-option -gu @vigil_auto
	tmux set-option -gu @vigil_queue_count
	tmux set-option -gu @vigil_status
	vigil_load_plugin
	[ "$(tmux show-options -gv @vigil_auto)" = 'off' ]
	[ "$(tmux show-options -gv @vigil_queue_count)" = '0' ]
	[ "$(tmux show-options -gv @vigil_status)" = '0 Vigil #[fg=red]●#[default]' ]
}

@test "first load seeds without resolving the runtime dir" {
	tmux set-option -gu @vigil_auto
	tmux set-option -gu @vigil_queue_count
	tmux set-option -gu @vigil_status
	vigil_load_plugin
	[ ! -e "${VIGIL_RUNTIME_DIR}/queue.json" ]
	[ ! -e "${VIGIL_RUNTIME_DIR}/queue.lock" ]
}

@test "first load does not change status-interval" {
	[ -n "$VIGIL_TEST_INTERVAL_BEFORE" ]
	[ "$(tmux show-options -gv status-interval)" = "$VIGIL_TEST_INTERVAL_BEFORE" ]
}

@test "status-right and @vigil_status contain no command substitution" {
	run tmux show-options -gv status-right
	[[ "$output" != *'#('* ]]
	run tmux show-options -gv @vigil_status
	[[ "$output" != *'#('* ]]
}

@test "running outside tmux exits zero and changes nothing" {
	run env -u TMUX bash "$BATS_TEST_DIRNAME/../../vigil.tmux"
	[ "$status" -eq 0 ]
	[ "$(tmux show-options -gv status-right)" = 'USERSEG #{@vigil_status}' ]
}
