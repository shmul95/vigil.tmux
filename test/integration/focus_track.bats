#!/usr/bin/env bats
# focus_track.bats — AUTO-04 wiring coverage: vigil.tmux's
# focus-events/allow-passthrough global option corrections, the
# client-focus-in/client-focus-out hook registrations pointing at
# vigil-focus-track, the M-V keybinding, and vigil-focus-track's
# own @vigil_kitty_focused single-writer behavior when invoked
# directly with in/out. Against a REAL, disposable tmux server
# (same harness as plugin.bats) -- bats' control-mode test client
# is not a real pty and cannot emit genuine \e[I/\e[O
# focus-reporting bytes, so the actual kitty-to-tmux escape-code
# delivery itself stays out of scope here (06-VALIDATION.md's
# documented limitation); this file proves the registration and
# the hook-handler script's own behavior instead.

load '../test_helper'
load 'integration_helper'

setup() {
	setup_vigil_runtime
	unset TMUX
	vigil_test_server_start
	vigil_load_plugin
}

teardown() {
	vigil_test_server_stop
	rm -rf "${VIGIL_RUNTIME_DIR:-}"
}

@test "Critical Pitfall 3: focus-events is set on" {
	[ "$(tmux show-options -gv focus-events)" = "on" ]
}

@test "Critical Pitfall 1: allow-passthrough is corrected to all, not on" {
	[ "$(tmux show-options -gv allow-passthrough)" = "all" ]
}

@test "registers client-focus-in and client-focus-out pointing at vigil-focus-track" {
	run tmux show-hooks -g client-focus-in
	[[ "$output" == *"run-shell"*"vigil-focus-track in"* ]]
	run tmux show-hooks -g client-focus-out
	[[ "$output" == *"run-shell"*"vigil-focus-track out"* ]]
}

@test "AUTO-01: binds M-V (no prefix) to run-shell vigil-auto-toggle, distinct from M-v" {
	run tmux list-keys -T root
	[ "$status" -eq 0 ]
	[[ "$output" == *"M-V"*"run-shell"*"vigil-auto-toggle"* ]]
	[[ "$output" == *"M-v"*"run-shell"*"vigil-advance"* ]]
}

@test "first load seeds @vigil_kitty_focused to off" {
	[ "$(tmux show-options -gv @vigil_kitty_focused)" = "off" ]
}

@test "vigil-focus-track in sets @vigil_kitty_focused on" {
	run vigil-focus-track in
	[ "$status" -eq 0 ]
	[ "$(tmux show-options -gv @vigil_kitty_focused)" = "on" ]
}

@test "vigil-focus-track out sets @vigil_kitty_focused off" {
	tmux set-option -g @vigil_kitty_focused on
	run vigil-focus-track out
	[ "$status" -eq 0 ]
	[ "$(tmux show-options -gv @vigil_kitty_focused)" = "off" ]
}

@test "vigil-focus-track with an unknown argument exits 1" {
	run vigil-focus-track sideways
	[ "$status" -eq 1 ]
}

@test "reloading the plugin never duplicates the M-V binding" {
	vigil_load_plugin
	run tmux list-keys -T root
	count="$(grep -c -- ' M-V ' <<<"$output")"
	[ "$count" -eq 1 ]
}

@test "CR-01/WR-06 (carried forward): an install path containing a single quote skips client-focus-in/out registration too, not just pane-exited" {
	tmux set-hook -gu pane-exited
	tmux set-hook -gu client-focus-in
	tmux set-hook -gu client-focus-out

	QUOTE_DIR="$(mktemp -d)/vigil'quote"
	mkdir -p "$QUOTE_DIR/scripts/lib"
	cp "$BATS_TEST_DIRNAME/../../vigil.tmux" "$QUOTE_DIR/vigil.tmux"
	cp "$BATS_TEST_DIRNAME/../../scripts/vigil-advance" "$QUOTE_DIR/scripts/vigil-advance"
	cp "$BATS_TEST_DIRNAME/../../scripts/vigil-prune" "$QUOTE_DIR/scripts/vigil-prune"
	cp "$BATS_TEST_DIRNAME/../../scripts/vigil-auto-toggle" "$QUOTE_DIR/scripts/vigil-auto-toggle"
	cp "$BATS_TEST_DIRNAME/../../scripts/vigil-focus-track" "$QUOTE_DIR/scripts/vigil-focus-track"
	cp "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh" "$QUOTE_DIR/scripts/lib/vigil-common.sh"

	run bash "$QUOTE_DIR/vigil.tmux"
	[ "$status" -eq 0 ]
	[[ "$output" == *"single quote"* ]]

	run tmux show-hooks -g client-focus-in
	[ "$output" = "client-focus-in" ]
	run tmux show-hooks -g client-focus-out
	[ "$output" = "client-focus-out" ]

	rm -rf "$(dirname "$QUOTE_DIR")"
}
