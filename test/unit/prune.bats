#!/usr/bin/env bats
# prune.bats — injected-live-pane-id prune coverage (test seam) for
# `vigil-queue prune`.

load '../test_helper'

@test "prune removes entries absent from the injected live list, preserving survivor order" {
	vigil-queue enqueue '%1'
	vigil-queue enqueue '%2'
	vigil-queue enqueue '%3'

	# Argument order deliberately reversed from enqueue order — proves
	# prune filters, it never reorders by argument order.
	run vigil-queue prune '%3' '%1'
	[ "$status" -eq 0 ]
	[ "$output" = "2" ]

	run vigil-queue count
	[ "$status" -eq 0 ]
	[ "$output" = "2" ]

	run vigil-queue peek
	[ "$status" -eq 0 ]
	run jq -r '.pane_id' <<<"$output"
	[ "$output" = "%1" ]
}

@test "prune with zero live-id arguments on a non-empty queue empties the queue" {
	vigil-queue enqueue '%1'
	vigil-queue enqueue '%2'
	vigil-queue enqueue '%3'

	run vigil-queue prune
	[ "$status" -eq 0 ]
	[ "$output" = "0" ]

	run vigil-queue count
	[ "$status" -eq 0 ]
	[ "$output" = "0" ]
}

@test "pruning a queue where all entries are already live leaves it unchanged" {
	vigil-queue enqueue '%1'
	vigil-queue enqueue '%2'
	vigil-queue enqueue '%3'

	run vigil-queue prune '%1' '%2' '%3'
	[ "$status" -eq 0 ]
	[ "$output" = "3" ]

	run vigil-queue count
	[ "$status" -eq 0 ]
	[ "$output" = "3" ]
}

@test "vigil-queue never shells out to tmux directly (test seam contract)" {
	run grep -c 'tmux ' "$BATS_TEST_DIRNAME/../../scripts/vigil-queue"
	[ "$output" = "0" ]

	run grep -c 'list-panes' "$BATS_TEST_DIRNAME/../../scripts/vigil-queue"
	[ "$output" = "0" ]
}
