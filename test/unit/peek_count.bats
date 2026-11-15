#!/usr/bin/env bats
# peek_count.bats — FIFO head ordering + count coverage for `vigil-queue
# peek`/`count`.

load '../test_helper'

@test "peek returns the first-enqueued pane as head (%1, %2, %3 order)" {
	vigil-queue enqueue '%1'
	vigil-queue enqueue '%2'
	vigil-queue enqueue '%3'

	run vigil-queue peek
	[ "$status" -eq 0 ]
	run jq -r '.pane_id' <<<"$output"
	[ "$output" = "%1" ]
}

@test "peek head tracks arrival order, not pane_id value (%3, %1, %2 order)" {
	vigil-queue enqueue '%3'
	vigil-queue enqueue '%1'
	vigil-queue enqueue '%2'

	run vigil-queue peek
	[ "$status" -eq 0 ]
	run jq -r '.pane_id' <<<"$output"
	[ "$output" = "%3" ]
}

@test "peek on an empty queue outputs null and exits 0" {
	run vigil-queue peek
	[ "$status" -eq 0 ]
	[ "$output" = "null" ]
}

@test "count is 0 on an empty/nonexistent queue, 2 after two enqueues" {
	run vigil-queue count
	[ "$status" -eq 0 ]
	[ "$output" = "0" ]

	vigil-queue enqueue '%1'
	vigil-queue enqueue '%2'

	run vigil-queue count
	[ "$status" -eq 0 ]
	[ "$output" = "2" ]
}

@test "a corrupted queue file causes count to exit 1 with the corruption message" {
	source "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"
	vigil_ensure_runtime_dir
	printf 'not json' >"$(vigil_queue_file)"

	run vigil-queue count
	[ "$status" -eq 1 ]
	[[ "$output" == *"vigil-queue: queue file is corrupted"* ]]
}

@test "an empty (0-byte) queue file is handled explicitly, not silently" {
	source "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"
	vigil_ensure_runtime_dir
	: >"$(vigil_queue_file)"

	run vigil-queue count
	[ "$status" -eq 0 ]
	[ "$output" = "0" ]

	run vigil-queue enqueue '%1'
	[ "$status" -eq 0 ]
	run vigil-queue count
	[ "$output" = "1" ]
}
