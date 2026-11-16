#!/usr/bin/env bats
# advance_guard.bats — outside-tmux no-op guard coverage for
# vigil-advance and vigil-prune. Both scripts are navigation/hook
# tools that genuinely require a real tmux server to exercise their
# actual behavior (see test/integration/advance.bats and prune.bats
# in 05-02) -- this file covers only the zero-tmux-dependency guard
# clause each script shares with vigil.tmux/vigil-publish.

load '../test_helper'

@test "vigil-advance is a silent no-op outside tmux" {
	run env -u TMUX bash "$BATS_TEST_DIRNAME/../../scripts/vigil-advance"
	[ "$status" -eq 0 ]
	[ ! -e "${VIGIL_RUNTIME_DIR}/queue.json" ]
}

@test "vigil-prune is a silent no-op outside tmux" {
	run env -u TMUX bash "$BATS_TEST_DIRNAME/../../scripts/vigil-prune"
	[ "$status" -eq 0 ]
	[ ! -e "${VIGIL_RUNTIME_DIR}/queue.json" ]
}
