#!/usr/bin/env bats
# enqueue_dequeue.bats — behavioral coverage for `vigil-queue enqueue`/`dequeue`.

load '../test_helper'

@test "enqueue then count: 0 -> 1" {
	run vigil-queue count
	[ "$status" -eq 0 ]
	[ "$output" = "0" ]

	run vigil-queue enqueue '%1'
	[ "$status" -eq 0 ]

	run vigil-queue count
	[ "$status" -eq 0 ]
	[ "$output" = "1" ]
}

@test "re-enqueuing the same pane_id is idempotent (no duplicate, no position change)" {
	run vigil-queue enqueue '%1'
	[ "$status" -eq 0 ]
	run vigil-queue enqueue '%1'
	[ "$status" -eq 0 ]

	run vigil-queue count
	[ "$status" -eq 0 ]
	[ "$output" = "1" ]
}

@test "enqueue two, dequeue one: count reflects the remaining entry" {
	run vigil-queue enqueue '%1'
	[ "$status" -eq 0 ]
	run vigil-queue enqueue '%2'
	[ "$status" -eq 0 ]
	run vigil-queue dequeue '%1'
	[ "$status" -eq 0 ]

	run vigil-queue count
	[ "$status" -eq 0 ]
	[ "$output" = "1" ]
}

@test "dequeue on a nonexistent pane_id is a harmless no-op" {
	run vigil-queue dequeue '%nonexistent'
	[ "$status" -eq 0 ]
}

@test "enqueue with a missing pane_id argument exits 1" {
	run vigil-queue enqueue
	[ "$status" -eq 1 ]
}

@test "after enqueue, the queue file is valid JSON with the pane_id at queue[0]" {
	run vigil-queue enqueue '%1'
	[ "$status" -eq 0 ]

	run jq empty "$(vigil_queue_file_for_test)"
	[ "$status" -eq 0 ]

	run jq -r '.queue[0].pane_id' "$(vigil_queue_file_for_test)"
	[ "$status" -eq 0 ]
	[ "$output" = "%1" ]
}

# Helper local to this suite: resolves the queue file path the same way
# vigil-queue does, without requiring every test to re-source the lib.
vigil_queue_file_for_test() {
	printf '%s/queue.json' "$VIGIL_RUNTIME_DIR"
}
