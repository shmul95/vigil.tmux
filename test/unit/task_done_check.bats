#!/usr/bin/env bats
# task_done_check.bats — DONE-01/DONE-02 coverage for
# vigil-task-done-check against a stubbed `gh` binary. The stub is
# a plain PATH-prepend (not an env-var seam like Phase 8's
# VIGIL_CLAUDE_BIN) -- this script invokes gh as a direct
# subprocess of its own bash process, with no tmux-server-
# environment-snapshot boundary to work around
# (09-RESEARCH.md Pattern 3).

load '../test_helper'

FIXTURE_DIR="$BATS_TEST_DIRNAME/../fixtures/tasks/samuel"

setup() {
	setup_vigil_runtime
	STUB_DIR="$(mktemp -d)"
	mkdir -p "$STUB_DIR/bin"
	GH_CALLS_LOG="$STUB_DIR/gh_calls.log"
	: >"$GH_CALLS_LOG"
	export GH_CALLS_LOG
	cat >"$STUB_DIR/bin/gh" <<STUB
#!/usr/bin/env bash
# Controlled by env vars the test sets before \`run\`:
#   GH_STUB_EXIT   - exit code to return (default 0)
#   GH_STUB_STDOUT - exact stdout to print
#   GH_STUB_STDERR - exact stderr to print
printf '%s\n' "\$*" >>"$GH_CALLS_LOG"
printf '%s' "\${GH_STUB_STDOUT:-}"
printf '%s' "\${GH_STUB_STDERR:-}" >&2
exit "\${GH_STUB_EXIT:-0}"
STUB
	chmod +x "$STUB_DIR/bin/gh"
	export PATH="$STUB_DIR/bin:$PATH"
}

teardown() {
	rm -rf "${VIGIL_RUNTIME_DIR:-}" "${STUB_DIR:-}"
}

@test "DONE-01: exact task-id substring found in a merged PR's title -> exit 1, done: line with PR number+URL" {
	export GH_STUB_STDOUT='{"number":42,"title":"Fix: vigil-task-20261110090000 handled","body":"","url":"https://github.com/EIP-memtide/memtide-dev/pull/42","repository":{"nameWithOwner":"EIP-memtide/memtide-dev"}}'
	run vigil-task-done-check "$FIXTURE_DIR/valid-open.md"
	[ "$status" -eq 1 ]
	[ "$output" = "done: vigil-task-20261110090000 (merged PR #42: https://github.com/EIP-memtide/memtide-dev/pull/42)" ]
}

@test "DONE-01: exact task-id substring found only in a merged PR's body (not title) -> exit 1, done: line" {
	export GH_STUB_STDOUT='{"number":43,"title":"Routine maintenance","body":"Closes vigil-task-20261110090000","url":"https://github.com/EIP-memtide/memtide-dev/pull/43","repository":{"nameWithOwner":"EIP-memtide/memtide-dev"}}'
	run vigil-task-done-check "$FIXTURE_DIR/valid-open.md"
	[ "$status" -eq 1 ]
	[ "$output" = "done: vigil-task-20261110090000 (merged PR #43: https://github.com/EIP-memtide/memtide-dev/pull/43)" ]
}

@test "DONE-01: gh succeeds with zero matches (filtered result is literal null) -> exit 0, not done: line" {
	export GH_STUB_STDOUT='null'
	run vigil-task-done-check "$FIXTURE_DIR/valid-open.md"
	[ "$status" -eq 0 ]
	[ "$output" = "not done: vigil-task-20261110090000" ]
}

@test "DONE-01: gh command itself fails (non-zero exit) -> fail-open, exit 0, not done: stdout, distinct stderr message" {
	export GH_STUB_EXIT=1
	export GH_STUB_STDERR='non-200 OK status code: 401 Unauthorized'
	run --separate-stderr vigil-task-done-check "$FIXTURE_DIR/valid-open.md"
	[ "$status" -eq 0 ]
	[ "$output" = "not done: vigil-task-20261110090000" ]
	[[ "$stderr" == *"evidence check failed: gh error"* ]]
	[[ "$stderr" == *"401"* ]]
}

@test "DONE-01: deterministic tie-break -- script requests gh's own --sort/--order/.[0] selection, never re-picks among candidates itself" {
	export GH_STUB_STDOUT='{"number":99,"title":"vigil-task-20261110090000 latest fix","body":"","url":"https://github.com/EIP-memtide/memtide-dev/pull/99","repository":{"nameWithOwner":"EIP-memtide/memtide-dev"}}'
	run vigil-task-done-check "$FIXTURE_DIR/valid-open.md"
	[ "$status" -eq 1 ]
	[ "$output" = "done: vigil-task-20261110090000 (merged PR #99: https://github.com/EIP-memtide/memtide-dev/pull/99)" ]
	grep -qF -- '--sort updated --order desc' "$GH_CALLS_LOG"
	grep -qF -- '.[0]' "$GH_CALLS_LOG"
}

@test "DONE-01: constructs the locked gh query exactly -- owner/merged/updated/json/jq fields all present verbatim" {
	export GH_STUB_STDOUT='null'
	run vigil-task-done-check "$FIXTURE_DIR/valid-open.md"
	[ "$status" -eq 0 ]
	grep -qF -- '--owner EIP-memtide' "$GH_CALLS_LOG"
	grep -qF -- '--merged' "$GH_CALLS_LOG"
	grep -qF -- '--updated >=2026-11-10T09:00:00Z' "$GH_CALLS_LOG"
	grep -qF -- '--json number,title,body,url,repository' "$GH_CALLS_LOG"
	grep -qF -- 'contains("20261110090000")' "$GH_CALLS_LOG"
}

@test "id re-derivation: a malformed-id task note is rejected (exit 1, stderr message) without ever invoking gh" {
	run --separate-stderr vigil-task-done-check "$FIXTURE_DIR/malformed-id-shape.md"
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"id field is not a 14-digit timestamp"* ]]
	[ ! -s "$GH_CALLS_LOG" ]
}

@test "usage: missing task_file argument exits 1 with a usage message, never invokes gh" {
	run --separate-stderr vigil-task-done-check
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"usage: vigil-task-done-check"* ]]
	[ ! -s "$GH_CALLS_LOG" ]
}
