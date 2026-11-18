#!/usr/bin/env bats
# task_spawn.bats — DEDUP-01/DEDUP-02/SPAWN-01/SPAWN-02 proof for
# `vigil-task-spawn` against a REAL, disposable tmux server. Uses a
# stubbed `claude` binary (vigil_test_stub_claude,
# integration_helper.bash) -- the real binary requires interactive
# auth and must never be invoked by this suite.

bats_require_minimum_version 1.5.0

load '../test_helper'
load 'integration_helper'

FIXTURE_DIR="$BATS_TEST_DIRNAME/../fixtures/tasks/samuel"

setup() {
	setup_vigil_runtime
	unset TMUX
	vigil_test_server_start
	vigil_test_stub_claude
}

teardown() {
	vigil_test_stub_claude_cleanup
	vigil_test_server_stop
	rm -rf "${VIGIL_RUNTIME_DIR:-}"
}

@test "DEDUP-02: creates the eip session when it does not exist yet, rather than failing" {
	run tmux has-session -t eip
	[ "$status" -ne 0 ]

	run vigil-task-spawn "$FIXTURE_DIR/valid-open.md"
	[ "$status" -eq 0 ]
	[ "$output" = "spawned: vigil-task-20261110090000 (window created in eip)" ]

	run tmux has-session -t eip
	[ "$status" -eq 0 ]
}

@test "SPAWN-01: spawns a window named vigil-task-<id> that runs claude with /thinking-partner @<path> (SPAWN-02 identity)" {
	run vigil-task-spawn "$FIXTURE_DIR/valid-open.md"
	[ "$status" -eq 0 ]

	windows="$(tmux list-windows -t eip -F '#{window_name}')"
	[ "$windows" = "vigil-task-20261110090000" ]

	local i
	for i in 1 2 3 4 5 6 7 8 9 10; do
		[ -s "$VIGIL_TEST_CLAUDE_LOG" ] && break
		sleep 0.2
	done
	[ -s "$VIGIL_TEST_CLAUDE_LOG" ]
	grep -qF "/thinking-partner @$FIXTURE_DIR/valid-open.md" "$VIGIL_TEST_CLAUDE_LOG"
}

@test "DEDUP-01: an exact-match pre-existing window is recognized as already running and is never re-spawned" {
	tmux new-session -d -s eip -n "vigil-task-20261110090000" "sleep 86400"

	run vigil-task-spawn "$FIXTURE_DIR/valid-open.md"
	[ "$status" -eq 0 ]
	[ "$output" = "skipped: vigil-task-20261110090000 (already running)" ]

	count="$(tmux list-windows -t eip -F '#{window_name}' | wc -l)"
	[ "$count" -eq 1 ]
}

@test "DEDUP-01: running spawn twice in a row against the same task file produces exactly one window, not two" {
	run vigil-task-spawn "$FIXTURE_DIR/valid-open.md"
	[ "$status" -eq 0 ]
	[[ "$output" == spawned:* ]]

	run vigil-task-spawn "$FIXTURE_DIR/valid-open.md"
	[ "$status" -eq 0 ]
	[ "$output" = "skipped: vigil-task-20261110090000 (already running)" ]

	count="$(tmux list-windows -t eip -F '#{window_name}' | grep -Fxc "vigil-task-20261110090000")"
	[ "$count" -eq 1 ]
}

@test "T-08-02 regression: a task id sharing a long numeric prefix with another running task's id is never falsely deduped (exact-match only)" {
	run vigil-task-spawn "$FIXTURE_DIR/valid-open.md"
	[ "$status" -eq 0 ]
	[[ "$output" == spawned:* ]]

	run vigil-task-spawn "$FIXTURE_DIR/valid-open-prefix.md"
	[ "$status" -eq 0 ]
	[ "$output" = "spawned: vigil-task-20261110090001 (window created in eip)" ]

	count="$(tmux list-windows -t eip -F '#{window_name}' | wc -l)"
	[ "$count" -eq 2 ]
}

@test "adversarial task_file path (shell metacharacters) is neutralized via printf %q, never executed as code" {
	pwned="$BATS_TEST_TMPDIR/PWNED"
	base="$(mktemp -d)"
	name="$(printf 'has"back`tick$(touch %s);quote'\''end' "$pwned")"
	adv_dir="$base/$name"
	mkdir -p "$adv_dir"
	cp "$FIXTURE_DIR/valid-open.md" "$adv_dir/task.md"

	run vigil-task-spawn "$adv_dir/task.md"
	[ "$status" -eq 0 ]
	[[ "$output" == spawned:* ]]

	local i
	for i in 1 2 3 4 5 6 7 8 9 10; do
		[ -s "$VIGIL_TEST_CLAUDE_LOG" ] && break
		sleep 0.2
	done
	[ -s "$VIGIL_TEST_CLAUDE_LOG" ]
	grep -qF "$adv_dir/task.md" "$VIGIL_TEST_CLAUDE_LOG"
	[ ! -e "$pwned" ]

	rm -rf "$base"
}

@test "a second window created in an already-existing eip session never steals the session's active-window focus" {
	run vigil-task-spawn "$FIXTURE_DIR/valid-open.md"
	[ "$status" -eq 0 ]
	active_before="$(tmux display-message -p -t eip '#{window_name}')"
	[ "$active_before" = "vigil-task-20261110090000" ]

	run vigil-task-spawn "$FIXTURE_DIR/valid-open-prefix.md"
	[ "$status" -eq 0 ]

	active_after="$(tmux display-message -p -t eip '#{window_name}')"
	[ "$active_after" = "$active_before" ]
}

@test "DEBT-02: standalone spawn rejects a note whose assignee mismatches the configured slug (nonzero exit, stderr reason, no window)" {
	run --separate-stderr vigil-task-spawn "$FIXTURE_DIR/mismatched-assignee.md"
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"assignee mismatch"* ]]
	# fixed reason only -- the actual untrusted value is never echoed
	[[ "$stderr" != *"bob"* ]]
	run tmux has-session -t eip
	[ "$status" -ne 0 ]
}
