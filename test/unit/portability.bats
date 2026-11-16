#!/usr/bin/env bats
# portability.bats — WR-08 regression coverage: resolving the runtime
# dir must not hard-depend on GNU coreutils' sha1sum being present.
#
# To simulate "sha1sum is unavailable" without actually removing it
# from PATH (which, on this system, would also remove unrelated tools
# like `cut` that happen to live in the same coreutils derivation),
# these tests override the `command` builtin in a nested shell so that
# `command -v sha1sum` specifically reports failure, while every other
# `command` call -- including the real sha1sum/shasum/cut binaries
# actually running -- is delegated unchanged.

load '../test_helper'

_vigil_hide_sha1sum_snippet() {
	cat <<'SNIPPET'
command() {
	if [[ "$1" == "-v" && "$2" == "sha1sum" ]]; then
		return 1
	fi
	builtin command "$@"
}
SNIPPET
}

@test "WR-08: _vigil_sha1_16 falls back to shasum when sha1sum is unavailable" {
	source "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"

	command -v shasum >/dev/null 2>&1 || skip "no shasum on this system to fall back to"

	local with_sha1sum without_sha1sum
	with_sha1sum="$(printf '%s' 'vigil-portability-fixture' | _vigil_sha1_16)"

	without_sha1sum="$(bash -c "
		$(_vigil_hide_sha1sum_snippet)
		source '$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh'
		command -v sha1sum >/dev/null 2>&1 && exit 1
		printf '%s' 'vigil-portability-fixture' | _vigil_sha1_16
	")"

	[ -n "$without_sha1sum" ]
	[ "$without_sha1sum" = "$with_sha1sum" ]
}

@test "WR-08: vigil_runtime_dir resolves identically regardless of which hash tool is used" {
	source "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"

	command -v shasum >/dev/null 2>&1 || skip "no shasum on this system to compare against"

	local via_sha1sum via_shasum
	via_sha1sum="$(bash -c "
		source '$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh'
		unset VIGIL_RUNTIME_DIR
		export TMUX='/tmp/tmux-1000/default,0,0'
		vigil_runtime_dir
	")"

	via_shasum="$(bash -c "
		$(_vigil_hide_sha1sum_snippet)
		source '$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh'
		unset VIGIL_RUNTIME_DIR
		export TMUX='/tmp/tmux-1000/default,0,0'
		vigil_runtime_dir
	")"

	[ "$via_sha1sum" = "$via_shasum" ]
}
