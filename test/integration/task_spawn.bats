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

	# SPAWN-04: a plain PATH-prepend `gh` stub, mirroring
	# test/unit/task_done_check.bats's pattern exactly. None of the
	# pre-existing fixtures' bodies contain a "github.com/.../pull/"
	# substring, so this stub is never invoked by any pre-existing
	# test in this file -- zero risk of interference with
	# DEDUP-01/DEDUP-02/T-08-02/no-focus-steal/DEBT-02.
	GH_STUB_DIR="$(mktemp -d)"
	mkdir -p "$GH_STUB_DIR/bin"
	GH_CALLS_LOG="$GH_STUB_DIR/gh_calls.log"
	: >"$GH_CALLS_LOG"
	export GH_CALLS_LOG
	cat >"$GH_STUB_DIR/bin/gh" <<STUB
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
	chmod +x "$GH_STUB_DIR/bin/gh"
	export PATH="$GH_STUB_DIR/bin:$PATH"
}

teardown() {
	vigil_test_stub_claude_cleanup
	vigil_test_server_stop
	rm -rf "${VIGIL_RUNTIME_DIR:-}" "${GH_STUB_DIR:-}"
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

	# The task window is created first (so a fresh session's active
	# window is the one the human wants), then the keeper window.
	windows="$(tmux list-windows -t eip -F '#{window_name}')"
	[ "$windows" = $'vigil-task-20261110090000\nvigil-home' ]

	local i
	for i in 1 2 3 4 5 6 7 8 9 10; do
		[ -s "$VIGIL_TEST_CLAUDE_LOG" ] && break
		sleep 0.2
	done
	[ -s "$VIGIL_TEST_CLAUDE_LOG" ]
	[ "$(cat "$VIGIL_TEST_CLAUDE_LOG")" = "--permission-mode auto /thinking-partner Please review the staging deploy and confirm the new worker pool is healthy." ]
}

@test "DEDUP-01: an exact-match pre-existing window is recognized as already running and is never re-spawned" {
	tmux new-session -d -s eip -n "vigil-task-20261110090000" "sleep 86400"

	run vigil-task-spawn "$FIXTURE_DIR/valid-open.md"
	[ "$status" -eq 0 ]
	[ "$output" = "skipped: vigil-task-20261110090000 (already running)" ]

	# The pre-existing session is retrofitted with the keeper window,
	# but the matching task window is still not duplicated.
	count="$(tmux list-windows -t eip -F '#{window_name}' | wc -l)"
	[ "$count" -eq 2 ]
	windows="$(tmux list-windows -t eip -F '#{window_name}')"
	[ "$(grep -Fxc "vigil-task-20261110090000" <<<"$windows")" -eq 1 ]
	[ "$(grep -Fxc "vigil-home" <<<"$windows")" -eq 1 ]
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

	# Two task windows plus the keeper window.
	count="$(tmux list-windows -t eip -F '#{window_name}' | wc -l)"
	[ "$count" -eq 3 ]
}

@test "adversarial task note body (shell metacharacters) is handed over as a file, never executed as code" {
	pwned="$BATS_TEST_TMPDIR/PWNED"
	base="$(mktemp -d)"
	adv_dir="$base/adv"
	mkdir -p "$adv_dir"
	adversarial_line="Reminder: run \`touch $pwned\`; then \"finish up\" and \$(echo pwned) now."
	printf '%s\n' "---" "id: 20261110090099" "status: open" "assignee: samuel" "created: 2026-11-10T09:00:00Z" "---" "" "$adversarial_line" >"$adv_dir/task.md"

	run vigil-task-spawn "$adv_dir/task.md"
	[ "$status" -eq 0 ]
	[[ "$output" == spawned:* ]]

	local i
	for i in 1 2 3 4 5 6 7 8 9 10; do
		[ -s "$VIGIL_TEST_CLAUDE_LOG" ] && break
		sleep 0.2
	done
	[ -s "$VIGIL_TEST_CLAUDE_LOG" ]
	grep -qF -- "$adversarial_line" "$VIGIL_TEST_CLAUDE_LOG"
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

@test "SPAWN-04: a PR-linked task note renders the PR's body/reviews/comments into the prompt instead of the raw note body" {
	export GH_STUB_STDOUT='{"body":"Adds the worker pool healthcheck endpoint.","reviews":[{"author":{"login":"alice"},"state":"CHANGES_REQUESTED","body":"Please add a timeout to the healthcheck call."}],"comments":[{"author":{"login":"bob"},"body":"LGTM once the timeout is added."}]}'

	run vigil-task-spawn "$FIXTURE_DIR/pr-linked.md"
	[ "$status" -eq 0 ]
	[[ "$output" == spawned:* ]]

	local i
	for i in 1 2 3 4 5 6 7 8 9 10; do
		[ -s "$VIGIL_TEST_CLAUDE_LOG" ] && break
		sleep 0.2
	done
	[ -s "$VIGIL_TEST_CLAUDE_LOG" ]
	expected=$'--permission-mode auto /thinking-partner Adds the worker pool healthcheck endpoint.\n\nReview by alice: Please add a timeout to the healthcheck call.\n\nComment by bob: LGTM once the timeout is added.'
	[ "$(cat "$VIGIL_TEST_CLAUDE_LOG")" = "$expected" ]

	grep -qF -- "--repo EIP-memtide/memtide-dev" "$GH_CALLS_LOG"
	grep -qF -- "--json reviews,comments,body" "$GH_CALLS_LOG"
	grep -qF -- "123" "$GH_CALLS_LOG"
}

@test "SPAWN-04: a gh failure on a PR-linked task note falls back to the raw note body without aborting the spawn" {
	export GH_STUB_EXIT=1
	export GH_STUB_STDERR='non-200 OK status code: 401 Unauthorized'

	run vigil-task-spawn "$FIXTURE_DIR/pr-linked.md"
	[ "$status" -eq 0 ]
	[[ "$output" == spawned:* ]]

	local i
	for i in 1 2 3 4 5 6 7 8 9 10; do
		[ -s "$VIGIL_TEST_CLAUDE_LOG" ] && break
		sleep 0.2
	done
	[ -s "$VIGIL_TEST_CLAUDE_LOG" ]
	[ "$(cat "$VIGIL_TEST_CLAUDE_LOG")" = "--permission-mode auto /thinking-partner Please address the review feedback on https://github.com/EIP-memtide/memtide-dev/pull/123 before merging." ]
}

@test "quitting a task window leaves eip (and its keeper window) alive" {
	run vigil-task-spawn "$FIXTURE_DIR/valid-open.md"
	[ "$status" -eq 0 ]
	[[ "$output" == spawned:* ]]

	# Simulate the human quitting claude: the task window closes.
	tmux kill-window -t "eip:vigil-task-20261110090000"

	run tmux has-session -t eip
	[ "$status" -eq 0 ]
	[ "$(tmux list-windows -t eip -F '#{window_name}')" = "vigil-home" ]
}

@test "a prompt larger than tmux's command-string limit still spawns intact" {
	# SPAWN-04 folds PR review content into the prompt; a busy PR is
	# tens of KB, which previously died inside tmux with "command too
	# long" (~16 KiB limit). The body must travel via file, not the
	# tmux command string.
	base="$(mktemp -d)"
	big_dir="$base/big"
	mkdir -p "$big_dir"
	{
		printf '%s\n' "---" "id: 20261110090123" "status: open" "assignee: samuel" "created: 2026-11-10T09:01:23Z" "---" ""
		printf 'BEGIN\n'
		head -c 20000 /dev/zero | tr '\0' 'x'
		printf '\nEND\n'
	} >"$big_dir/task.md"

	run vigil-task-spawn "$big_dir/task.md"
	[ "$status" -eq 0 ]
	[[ "$output" == spawned:* ]]

	local i
	for i in 1 2 3 4 5 6 7 8 9 10; do
		[ -s "$VIGIL_TEST_CLAUDE_LOG" ] && break
		sleep 0.2
	done
	[ -s "$VIGIL_TEST_CLAUDE_LOG" ]
	# Full body arrived (well over the ~16 KiB tmux limit), with its
	# first and last lines intact.
	[ "$(wc -c <"$VIGIL_TEST_CLAUDE_LOG")" -gt 20000 ]
	grep -qF "BEGIN" "$VIGIL_TEST_CLAUDE_LOG"
	grep -qF "END" "$VIGIL_TEST_CLAUDE_LOG"

	rm -rf "$base"
}
