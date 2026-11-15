#!/usr/bin/env bash
# test_helper.bash — shared bats setup/teardown for Vigil's test suites.
#
# Isolates every test run into its own scratch VIGIL_RUNTIME_DIR so tests
# never touch a real $XDG_RUNTIME_DIR/tmux socket, and prepends the repo's
# scripts/ directory to PATH so bare `vigil-queue` invocations resolve to
# the script under test regardless of which test/<suite>/*.bats file loads
# this helper.

setup_vigil_runtime() {
	export VIGIL_RUNTIME_DIR="$(mktemp -d)"
	export PATH="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/scripts:${PATH}"
	# Unit tests must never publish to a developer's live multiplexer.
	unset TMUX
}

setup() {
	setup_vigil_runtime
}

teardown() {
	rm -rf "${VIGIL_RUNTIME_DIR:-}"
}
