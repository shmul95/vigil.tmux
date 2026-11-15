#!/usr/bin/env bats
# crash_safety.bats — fault injection proving SIGKILL mid-write never
# corrupts queue.json (phase success criterion 3). Exploits
# VIGIL_QUEUE_TEST_DELAY, the fault-injection seam inside
# _vigil_write_queue_atomic (scripts/vigil-queue), to kill the process
# inside the window between the temp-file write and the atomic `mv`.

load '../test_helper'

@test "SIGKILL mid-write across 10 iterations never corrupts queue.json" {
	source "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"

	for i in $(seq 1 10); do
		VIGIL_QUEUE_TEST_DELAY=0.2 vigil-queue enqueue "%kill$i" &
		local pid=$!
		sleep "0.0$(((RANDOM % 9) + 1))"
		kill -9 "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true

		run jq empty "$(vigil_queue_file)" 2>/dev/null
		if [ "$status" -ne 0 ] && [ -e "$(vigil_queue_file)" ]; then
			echo "iteration $i: queue file exists but is invalid JSON" >&2
			false
		fi
	done

	# Sanity check: the helper never resolves to a .tmp path.
	[ "$(basename "$(vigil_queue_file)")" = "queue.json" ]

	# Leftover *.tmp.* files from killed processes are harmless clutter,
	# not corruption — the real queue file (if it exists at all; a killed
	# writer may never have completed its mv) must never be present-and-invalid.
	run jq empty "$(vigil_queue_file)" 2>/dev/null
	[ "$status" -eq 0 ] || [ ! -e "$(vigil_queue_file)" ]
}

@test "CR-01: SIGKILL while holding the lock releases it immediately, not after the 2s timeout" {
	source "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"

	# Hold the lock via the fault-injection delay, then kill the holder
	# mid-sleep. Before the CR-01 fix, the orphaned `sleep` inherited a
	# copy of the lock FD and kept flock held, so the next mutation below
	# would block for the full 2s `flock -w 2` and exit 2.
	VIGIL_QUEUE_TEST_DELAY=3 vigil-queue enqueue '%victim' &
	local holder=$!
	sleep 0.5
	kill -9 "$holder" 2>/dev/null || true
	wait "$holder" 2>/dev/null || true

	# The lock must be acquirable well within the 2s timeout now that the
	# orphaned sleep no longer holds a copy of the FD -- bound this with a
	# 1s wall-clock timeout so a regression (silently waiting the full 2s
	# and exiting 2) fails this assertion rather than just being slow.
	run timeout 1 vigil-queue enqueue '%second'
	[ "$status" -eq 0 ]
	[ "$(vigil-queue count)" = "1" ]
	[ "$(vigil-queue peek | jq -r '.pane_id')" = "%second" ]
}
