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

@test "WR-02: an escaped ##{@vigil_status} literal is not mistaken for an already-wired marker" {
	# tmux renders "##{@vigil_status}" as the literal text "#{@vigil_status}"
	# (the "##" is an escaped "#"), not as a live reference to the option.
	# A plain substring guard is fooled by this and never appends a real
	# marker, so the status line never shows anything.
	tmux set-option -g status-right 'A ##{@vigil_status} B'
	vigil_load_plugin
	run tmux show-options -gv status-right
	[ "$status" -eq 0 ]
	# One occurrence is the user's escaped literal text; the other is the
	# real marker the plugin appended. vigil_marker_count is a plain
	# substring count, so it legitimately reports 2 here -- the escaped
	# occurrence is the exact scenario this test exists to cover.
	[ "$output" = 'A ##{@vigil_status} B #{@vigil_status}' ]
	[ "$(vigil_marker_count "$output")" -eq 2 ]
}

@test "WR-02: a marker referenced inside a conditional format is still treated as wired" {
	# The marker is genuinely present in the user's status-right here
	# (just conditionally rendered), so the plugin correctly leaves it
	# alone rather than appending a duplicate occurrence.
	tmux set-option -g status-right 'A #{?client_prefix,,#{@vigil_status}} B'
	vigil_load_plugin
	run tmux show-options -gv status-right
	[ "$status" -eq 0 ]
	[ "$output" = 'A #{?client_prefix,,#{@vigil_status}} B' ]
}

@test "WR-02: a marker referenced inside a #() command substitution is still treated as wired" {
	tmux set-option -g status-right 'A #(echo #{@vigil_status}) B'
	vigil_load_plugin
	run tmux show-options -gv status-right
	[ "$status" -eq 0 ]
	[ "$output" = 'A #(echo #{@vigil_status}) B' ]
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

@test "WR-06: a fresh server picks up the persisted queue count instead of fabricating zero" {
	# Simulate a tmux restart: the @vigil_* options are gone (as they
	# would be on a brand-new server), but queue.json persists across
	# the restart because it's keyed by socket path, not by option
	# state.
	vigil-queue enqueue '%1'
	vigil-queue enqueue '%2'
	tmux set-option -gu @vigil_auto
	tmux set-option -gu @vigil_queue_count
	tmux set-option -gu @vigil_status
	vigil_load_plugin
	[ "$(tmux show-options -gv @vigil_queue_count)" = '2' ]
	[ "$(tmux show-options -gv @vigil_status)" = '2 Vigil #[fg=red]●#[default]' ]
}

@test "WR-06: a non-numeric pre-existing @vigil_queue_count is repaired from the persisted queue" {
	vigil-queue enqueue '%1'
	tmux set-option -g @vigil_queue_count 'garbage'
	vigil_load_plugin
	[ "$(tmux show-options -gv @vigil_queue_count)" = '1' ]
}

@test "WR-06: a non-on/off pre-existing @vigil_auto is sanitized to off" {
	tmux set-option -g @vigil_auto 'garbage'
	vigil_load_plugin
	[ "$(tmux show-options -gv @vigil_auto)" = 'off' ]
}

@test "WR-06/WR-03: a repaired @vigil_queue_count also re-renders a stale @vigil_status" {
	# Regression test for commit 75e598b: a non-numeric @vigil_queue_count
	# is repaired from the persisted queue (WR-06), but without WR-03 the
	# rendered @vigil_status string would be left stale -- disagreeing with
	# the just-repaired count -- until the next real mutation republishes
	# all three options together.
	vigil-queue enqueue '%1'
	tmux set-option -g @vigil_queue_count 'garbage'
	tmux set-option -g @vigil_status 'stale-marker'
	vigil_load_plugin
	[ "$(tmux show-options -gv @vigil_queue_count)" = '1' ]
	[ "$(tmux show-options -gv @vigil_status)" = '1 Vigil #[fg=red]●#[default]' ]
}

@test "WR-06/WR-03: a sanitized @vigil_auto also re-renders a stale @vigil_status" {
	# Same regression as above, but for the @vigil_auto repair path: a
	# bogus @vigil_auto is sanitized to off (WR-06), and the stale
	# @vigil_status left over from a previous on-mode render must be
	# re-rendered to match the just-sanitized auto value, not left stale.
	tmux set-option -g @vigil_auto 'garbage'
	tmux set-option -g @vigil_status '#[fg=white]0 Vigil #[fg=green]●#[default]'
	vigil_load_plugin
	[ "$(tmux show-options -gv @vigil_auto)" = 'off' ]
	[ "$(tmux show-options -gv @vigil_status)" = '0 Vigil #[fg=red]●#[default]' ]
}

@test "WR-03: a failed status-right read leaves status-right untouched and exits 0" {
	# Simulate show-options failing for status-right specifically (a tmux
	# shim missing the command, a transient server failure, ...) by
	# wrapping the real tmux binary in a stub that fails only for that
	# one read and delegates everything else unchanged.
	local real_tmux stub_dir before after
	real_tmux="$(command -v tmux)"
	stub_dir="$(mktemp -d)"
	cat >"$stub_dir/tmux" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "show-options" && "\$*" == *"status-right"* && "\$*" != *"status-right-length"* ]]; then
	exit 1
fi
exec "$real_tmux" "\$@"
STUB
	chmod +x "$stub_dir/tmux"

	before="$(tmux show-options -gv status-right)"

	PATH="$stub_dir:$PATH" run bash "$BATS_TEST_DIRNAME/../../vigil.tmux"
	[ "$status" -eq 0 ]
	[[ "$output" == *"unable to read status-right"* ]]

	after="$(tmux show-options -gv status-right)"
	[ "$after" = "$before" ]

	rm -rf "$stub_dir"
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
