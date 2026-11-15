#!/usr/bin/env bats
# rotate.bats — head-to-tail rotation + full-cycle FIFO ordering coverage
# for `vigil-queue rotate`.

load '../test_helper'

@test "rotate moves the head to the back and prints the new head's pane_id" {
	vigil-queue enqueue '%1'
	vigil-queue enqueue '%2'
	vigil-queue enqueue '%3'

	run vigil-queue rotate
	[ "$status" -eq 0 ]
	[ "$output" = "%2" ]

	run vigil-queue peek
	[ "$status" -eq 0 ]
	run jq -r '.pane_id' <<<"$output"
	[ "$output" = "%2" ]

	run vigil-queue count
	[ "$status" -eq 0 ]
	[ "$output" = "3" ]
}

@test "rotating a second time advances the head again" {
	vigil-queue enqueue '%1'
	vigil-queue enqueue '%2'
	vigil-queue enqueue '%3'

	vigil-queue rotate

	run vigil-queue rotate
	[ "$status" -eq 0 ]
	[ "$output" = "%3" ]

	run vigil-queue peek
	[ "$status" -eq 0 ]
	run jq -r '.pane_id' <<<"$output"
	[ "$output" = "%3" ]
}

@test "rotate on an empty queue exits 1 without corrupting state" {
	run vigil-queue rotate
	[ "$status" -eq 1 ]
	[[ "$output" == *"queue is empty"* ]]

	run vigil-queue count
	[ "$status" -eq 0 ]
	[ "$output" = "0" ]
}

@test "full cycle: three rotates on a three-entry queue return to the original head with no entry lost or duplicated" {
	vigil-queue enqueue '%1'
	vigil-queue enqueue '%2'
	vigil-queue enqueue '%3'

	vigil-queue rotate
	vigil-queue rotate

	run vigil-queue rotate
	[ "$status" -eq 0 ]
	[ "$output" = "%1" ]

	run vigil-queue peek
	[ "$status" -eq 0 ]
	run jq -r '.pane_id' <<<"$output"
	[ "$output" = "%1" ]

	run vigil-queue count
	[ "$status" -eq 0 ]
	[ "$output" = "3" ]
}
