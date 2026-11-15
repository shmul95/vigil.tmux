#!/usr/bin/env bats
# concurrency.bats — fault injection proving zero lost updates and valid
# final JSON when multiple vigil-queue processes race against the same
# queue file (phase success criterion 2; PITFALLS.md Pitfall 7).

load '../test_helper'

@test "5 concurrent enqueues land all 5 entries, no loss, no corruption" {
	source "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"

	vigil-queue enqueue "%conc1" &
	vigil-queue enqueue "%conc2" &
	vigil-queue enqueue "%conc3" &
	vigil-queue enqueue "%conc4" &
	vigil-queue enqueue "%conc5" &
	wait

	run vigil-queue count
	[ "$status" -eq 0 ]
	[ "$output" -eq 5 ]

	run jq -r '.queue[].pane_id' "$(vigil_queue_file)"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | wc -l)" -eq 5 ]
	[ "$(echo "$output" | sort -u | wc -l)" -eq 5 ]

	run jq empty "$(vigil_queue_file)"
	[ "$status" -eq 0 ]
}

@test "concurrent mixed enqueue+dequeue converges to the mathematically expected set" {
	source "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"

	# Seed sequentially — this just establishes starting state, not the race.
	vigil-queue enqueue "%pre1"
	vigil-queue enqueue "%pre2"
	vigil-queue enqueue "%pre3"
	vigil-queue enqueue "%pre4"
	vigil-queue enqueue "%pre5"

	vigil-queue enqueue "%new1" &
	vigil-queue enqueue "%new2" &
	vigil-queue dequeue "%pre1" &
	vigil-queue dequeue "%pre2" &
	wait

	run jq empty "$(vigil_queue_file)"
	[ "$status" -eq 0 ]

	run bash -c "jq -r '.queue[].pane_id' \"$(vigil_queue_file)\" | sort"
	[ "$status" -eq 0 ]
	expected="$(printf '%s\n' %new1 %new2 %pre3 %pre4 %pre5 | sort)"
	[ "$output" = "$expected" ]
}
