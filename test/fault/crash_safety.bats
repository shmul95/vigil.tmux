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
