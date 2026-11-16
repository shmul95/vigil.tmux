#!/usr/bin/env bats
# hook_common.bats — behavior coverage for vigil-hook-common.sh, the
# shared helper library sourced by all three Phase 4 hook client scripts
# (vigil-hook-stop, vigil-hook-notification, vigil-hook-userpromptsubmit).
#
# Covers: pane-identity capture from $TMUX_PANE only (never a live tmux
# query), defensive jq field extraction (missing field / explicit null /
# malformed JSON all degrade to the caller's default instead of crashing),
# and VIGIL_DEBUG-gated stderr tracing.

load '../test_helper'

setup() {
	setup_vigil_runtime
	source "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-hook-common.sh"
}

@test "vigil_hook_pane_id echoes \$TMUX_PANE when set" {
	export TMUX_PANE='%7'
	run vigil_hook_pane_id
	[ "$status" -eq 0 ]
	[ "$output" = "%7" ]
}

@test "vigil_hook_pane_id fails closed (non-zero, no output) when \$TMUX_PANE unset" {
	unset TMUX_PANE
	run vigil_hook_pane_id
	[ "$status" -ne 0 ]
	[ "$output" = "" ]
}

@test "vigil_hook_jq_field returns the field value when present" {
	run vigil_hook_jq_field '{"hook_event_name":"Stop"}' hook_event_name unknown
	[ "$status" -eq 0 ]
	[ "$output" = "Stop" ]
}

@test "vigil_hook_jq_field returns the default when the field is absent" {
	run vigil_hook_jq_field '{"hook_event_name":"Stop"}' notification_type unknown
	[ "$status" -eq 0 ]
	[ "$output" = "unknown" ]
}

@test "vigil_hook_jq_field returns the default on malformed JSON" {
	run vigil_hook_jq_field 'not valid json at all' notification_type unknown
	[ "$status" -eq 0 ]
	[ "$output" = "unknown" ]
}

@test "vigil_hook_jq_field returns the default when the field is explicitly null" {
	run vigil_hook_jq_field '{"notification_type":null}' notification_type unknown
	[ "$status" -eq 0 ]
	[ "$output" = "unknown" ]
}

@test "vigil_hook_debug is silent when VIGIL_DEBUG is unset" {
	unset VIGIL_DEBUG
	run vigil_hook_debug "some trace message"
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
}

@test "vigil_hook_debug emits exactly one stderr line containing the message when VIGIL_DEBUG=1" {
	export VIGIL_DEBUG=1
	run vigil_hook_debug "some trace message"
	[ "$status" -eq 0 ]
	local line_count
	line_count="$(printf '%s\n' "$output" | wc -l)"
	[ "$line_count" -eq 1 ]
	[[ "$output" == *"some trace message"* ]]
}
