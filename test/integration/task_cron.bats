#!/usr/bin/env bats
# task_cron.bats — CRON-01 proof for scripts/vigil-task-cron against a
# REAL, disposable tmux server. Both the Phase 8 claude stub
# (vigil_test_stub_claude) and a Phase 9-style inline gh stub are active
# at once: they touch disjoint env vars/temp dirs (10-RESEARCH.md).

bats_require_minimum_version 1.5.0

load '../test_helper'
load 'integration_helper'

FIXTURE_DIR="$BATS_TEST_DIRNAME/../fixtures/tasks/samuel"
CRON="$BATS_TEST_DIRNAME/../../scripts/vigil-task-cron"

setup() {
	setup_vigil_runtime
	unset TMUX
	vigil_test_server_start
	vigil_test_stub_claude

	GH_STUB_DIR="$(mktemp -d)"
	mkdir -p "$GH_STUB_DIR/bin"
	GH_CALLS_LOG="$GH_STUB_DIR/gh_calls.log"
	: >"$GH_CALLS_LOG"
	export GH_CALLS_LOG
	cat >"$GH_STUB_DIR/bin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\$GH_CALLS_LOG"
if [[ -n "\${GH_STUB_MATCH_ID:-}" && "\$*" == *"\$GH_STUB_MATCH_ID"* ]]; then
  printf '{"number":77,"title":"Fix vigil-task-%s","body":"","url":"https://github.com/EIP-memtide/x/pull/77","repository":{"nameWithOwner":"EIP-memtide/x"}}' "\$GH_STUB_MATCH_ID"
else
  printf 'null'
fi
exit "\${GH_STUB_EXIT:-0}"
STUB
	chmod +x "$GH_STUB_DIR/bin/gh"
	export PATH="$GH_STUB_DIR/bin:$PATH"
	export VIGIL_TASKS_DIR="$FIXTURE_DIR"
	CANON="$(cd "$FIXTURE_DIR" && pwd)"
	export CANON
}

teardown() {
	vigil_test_stub_claude_cleanup
	vigil_test_server_stop
	rm -rf "${VIGIL_RUNTIME_DIR:-}" "${GH_STUB_DIR:-}"
}

@test "CRON-01: cold run spawns all 3 open tasks and prints the locked summary" {
	run --separate-stderr "$CRON"
	[ "$status" -eq 0 ]
	[[ "$output" == *"not done: vigil-task-20261110090000"* ]]
	[[ "$output" == *"spawned: vigil-task-20261110090000 (window created in eip)"* ]]
	[[ "$output" == *"spawned: vigil-task-20261110090001 (window created in eip)"* ]]
	[[ "$output" == *"spawned: vigil-task-20261112100000 (window created in eip)"* ]]
	[ "$(printf '%s\n' "$output" | tail -n 1)" = "vigil-task-cron: 3 tasks found, 3 spawned, 0 already running, 0 done (PR merged), 0 errors" ]
	[ "$(tmux list-windows -t eip -F '#{window_name}' | wc -l)" -eq 3 ]

	local i
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
		[ "$(wc -l <"$VIGIL_TEST_CLAUDE_LOG")" -ge 3 ] && break
		sleep 0.2
	done
	[ "$(wc -l <"$VIGIL_TEST_CLAUDE_LOG")" -ge 3 ]
	grep -qF "/thinking-partner @$CANON/valid-open.md" "$VIGIL_TEST_CLAUDE_LOG"
}

@test "CRON-01: a back-to-back second run reports already-running tasks and creates no duplicate windows" {
	run --separate-stderr "$CRON"
	[ "$status" -eq 0 ]
	[[ "$output" == *"3 spawned"* ]]

	run --separate-stderr "$CRON"
	[ "$status" -eq 0 ]
	[[ "$output" == *"skipped: vigil-task-20261110090000 (already running)"* ]]
	[ "$(printf '%s\n' "$output" | tail -n 1)" = "vigil-task-cron: 3 tasks found, 0 spawned, 3 already running, 0 done (PR merged), 0 errors" ]
	[ "$(tmux list-windows -t eip -F '#{window_name}' | wc -l)" -eq 3 ]
}

@test "CRON-01: a merged PR suppresses respawning for exactly that task while others are spawned" {
	export GH_STUB_MATCH_ID="20261110090000"
	run --separate-stderr "$CRON"
	[ "$status" -eq 0 ]
	[[ "$output" == *"done: vigil-task-20261110090000 (merged PR #77: https://github.com/EIP-memtide/x/pull/77)"* ]]
	[[ "$output" == *"spawned: vigil-task-20261110090001 (window created in eip)"* ]]
	[[ "$output" == *"spawned: vigil-task-20261112100000 (window created in eip)"* ]]
	[ "$(printf '%s\n' "$output" | tail -n 1)" = "vigil-task-cron: 3 tasks found, 2 spawned, 0 already running, 1 done (PR merged), 0 errors" ]

	run tmux list-windows -t eip -F '#{window_name}'
	[[ "$output" != *"vigil-task-20261110090000"* ]]
	[ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]
}

@test "CRON-01: one run mixes new, already-running, and PR-done tasks without double-spawning or reaping" {
	# Pre-spawn task 20261110090000 directly so it is already running
	# before the cron run (spawn never consults gh).
	"$BATS_TEST_DIRNAME/../../scripts/vigil-task-spawn" "$CANON/valid-open.md"
	export GH_STUB_MATCH_ID="20261110090001"

	run --separate-stderr "$CRON"
	[ "$status" -eq 0 ]
	[[ "$output" == *"done: vigil-task-20261110090001"* ]]
	[[ "$output" == *"skipped: vigil-task-20261110090000 (already running)"* ]]
	[[ "$output" == *"spawned: vigil-task-20261112100000 (window created in eip)"* ]]
	[ "$(printf '%s\n' "$output" | tail -n 1)" = "vigil-task-cron: 3 tasks found, 1 spawned, 1 already running, 1 done (PR merged), 0 errors" ]

	run tmux list-windows -t eip -F '#{window_name}'
	[ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]
	[[ "$output" != *"vigil-task-20261110090001"* ]]
}

@test "CRON-01: a true no-op on an empty tasks directory still prints a non-empty summary and exits 0" {
	local empty
	empty="$(mktemp -d)"
	export VIGIL_TASKS_DIR="$empty"
	run --separate-stderr "$CRON"
	[ "$status" -eq 0 ]
	[ "$output" = "vigil-task-cron: 0 tasks found, 0 spawned, 0 already running, 0 done (PR merged), 0 errors" ]
	rmdir "$empty"
}

@test "CRON-01: a failing reader is counted as an error, still summarised, and exits 0" {
	local tmp_scripts
	tmp_scripts="$(mktemp -d)"
	cp -R "$BATS_TEST_DIRNAME/../../scripts/." "$tmp_scripts/"
	chmod +x "$tmp_scripts"/vigil-task-*
	cat >"$tmp_scripts/vigil-task-reader" <<'EOF'
#!/usr/bin/env bash
echo "reader exploded" >&2
exit 3
EOF
	chmod +x "$tmp_scripts/vigil-task-reader"

	run --separate-stderr "$tmp_scripts/vigil-task-cron"
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"vigil-task-reader failed (exit 3)"* ]]
	[ "$output" = "vigil-task-cron: 0 tasks found, 0 spawned, 0 already running, 0 done (PR merged), 1 errors" ]
	rm -rf "$tmp_scripts"
}

@test "CRON-01: a done-check that exits 1 with no done: line is an error, never a silent done" {
	local tmp_scripts
	tmp_scripts="$(mktemp -d)"
	cp -R "$BATS_TEST_DIRNAME/../../scripts/." "$tmp_scripts/"
	chmod +x "$tmp_scripts"/vigil-task-*
	cat >"$tmp_scripts/vigil-task-done-check" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
	chmod +x "$tmp_scripts/vigil-task-done-check"

	run --separate-stderr "$tmp_scripts/vigil-task-cron"
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$output" | tail -n 1)" = "vigil-task-cron: 3 tasks found, 0 spawned, 0 already running, 0 done (PR merged), 3 errors" ]
	run tmux has-session -t eip
	[ "$status" -ne 0 ]
	rm -rf "$tmp_scripts"
}

@test "CRON-01: a spawn failure is counted per task, still summarised, and exits 0" {
	export VIGIL_CLAUDE_BIN="/nonexistent/claude-for-task-cron-test"
	run --separate-stderr "$CRON"
	[ "$status" -eq 0 ]
	[ "$(printf '%s\n' "$output" | tail -n 1)" = "vigil-task-cron: 3 tasks found, 0 spawned, 0 already running, 0 done (PR merged), 3 errors" ]

	run tmux has-session -t eip
	[ "$status" -ne 0 ]
}

@test "CRON-01: a gh failure fails open -- all tasks are spawned and no error is counted" {
	export GH_STUB_EXIT=1
	run --separate-stderr "$CRON"
	[ "$status" -eq 0 ]
	[[ "$output" == *"spawned: vigil-task-20261110090000"* ]]
	[ "$(printf '%s\n' "$output" | tail -n 1)" = "vigil-task-cron: 3 tasks found, 3 spawned, 0 already running, 0 done (PR merged), 0 errors" ]
}

@test "CRON-01: missing jq prints a loud warning, counts an error, and still spawns" {
	local p out
	out=""
	IFS=: read -r -a _path_parts <<<"$PATH"
	for p in "${_path_parts[@]}"; do
		[[ -x "$p/jq" ]] && continue
		out="${out:+$out:}$p"
	done
	PATH="$out" command -v jq >/dev/null 2>&1 && fail "jq unexpectedly still resolvable on the reduced PATH"

	run --separate-stderr env PATH="$out" "$CRON"
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"jq not found"* ]]
	[[ "$stderr" == *"completion detection disabled"* ]]
	[[ "$output" == *"spawned: vigil-task-20261110090000"* ]]
	[ "$(printf '%s\n' "$output" | tail -n 1)" = "vigil-task-cron: 3 tasks found, 3 spawned, 0 already running, 0 done (PR merged), 1 errors" ]
}

@test "CRON-01: missing gh prints a loud warning and counts an error too, symmetric with jq" {
	local p out
	out=""
	IFS=: read -r -a _path_parts <<<"$PATH"
	for p in "${_path_parts[@]}"; do
		[[ -x "$p/gh" ]] && continue
		out="${out:+$out:}$p"
	done
	PATH="$out" command -v gh >/dev/null 2>&1 && fail "gh unexpectedly still resolvable on the reduced PATH"

	run --separate-stderr env PATH="$out" "$CRON"
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"gh not found"* ]]
	[[ "$stderr" == *"completion detection disabled"* ]]
	[[ "$output" == *"spawned: vigil-task-20261110090000"* ]]
	[ "$(printf '%s\n' "$output" | tail -n 1)" = "vigil-task-cron: 3 tasks found, 3 spawned, 0 already running, 0 done (PR merged), 1 errors" ]
}
