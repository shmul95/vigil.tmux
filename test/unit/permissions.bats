#!/usr/bin/env bats
# permissions.bats — WR-07 regression coverage: the runtime leaf
# directory and the state files inside it must never depend on the
# caller's ambient umask, and a pre-existing loose leaf must be
# tightened on every invocation, not just on first creation.

load '../test_helper'

@test "WR-07: the leaf runtime dir is created 0700 even under a permissive umask" {
	source "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"

	(
		umask 022
		vigil_ensure_runtime_dir
	)

	local mode
	mode="$(stat -c %a "$(vigil_runtime_dir)" 2>/dev/null || stat -f %A "$(vigil_runtime_dir)" 2>/dev/null)"
	[ "$mode" = "700" ]
}

@test "WR-07: an existing loose leaf directory is tightened to 0700 on the next call" {
	source "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"

	vigil_ensure_runtime_dir
	chmod 755 "$(vigil_runtime_dir)"

	vigil_ensure_runtime_dir

	local mode
	mode="$(stat -c %a "$(vigil_runtime_dir)" 2>/dev/null || stat -f %A "$(vigil_runtime_dir)" 2>/dev/null)"
	[ "$mode" = "700" ]
}

@test "WR-07: queue.json and queue.lock are created 0600 even under a permissive umask" {
	(
		umask 022
		vigil-queue enqueue '%1'
	)

	local queue_mode lock_mode
	queue_mode="$(stat -c %a "${VIGIL_RUNTIME_DIR}/queue.json" 2>/dev/null || stat -f %A "${VIGIL_RUNTIME_DIR}/queue.json" 2>/dev/null)"
	lock_mode="$(stat -c %a "${VIGIL_RUNTIME_DIR}/queue.lock" 2>/dev/null || stat -f %A "${VIGIL_RUNTIME_DIR}/queue.lock" 2>/dev/null)"
	[ "$queue_mode" = "600" ]
	[ "$lock_mode" = "600" ]
}
