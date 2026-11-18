#!/usr/bin/env bats
# task_reader.bats — behavior coverage for vigil-task-reader
# (TASKREAD-01/TASKREAD-02) and the shared frontmatter parser it sources,
# scripts/lib/vigil-frontmatter.sh. No tmux/network dependency -- pure
# file I/O against the fixtures in test/fixtures/tasks/samuel/.

bats_require_minimum_version 1.5.0

load '../test_helper'

FIXTURES_DIR_GLOBAL=""

setup() {
	setup_vigil_runtime
	FIXTURES_DIR_GLOBAL="$(cd "${BATS_TEST_DIRNAME}/../fixtures/tasks/samuel" && pwd)"
}

# make_tasks_dir <fixture-name>... — copies only the named fixtures into a
# fresh mktemp -d directory and echoes that directory's path, so each
# test's expected output is unambiguous regardless of what other fixtures
# exist in the repo.
make_tasks_dir() {
	local dir
	dir="$(mktemp -d)"
	local fixture
	for fixture in "$@"; do
		cp "${FIXTURES_DIR_GLOBAL}/${fixture}" "${dir}/${fixture}"
	done
	echo "$dir"
}

@test "lists only the open, assignee-matched note when run against valid-open.md and valid-done.md" {
	local dir
	dir="$(make_tasks_dir valid-open.md valid-done.md)"
	export VIGIL_TASKS_DIR="$dir"
	run vigil-task-reader
	[ "$status" -eq 0 ]
	[ "$output" = "${dir}/valid-open.md" ]
}

@test "output format is absolute paths only, one per line, no other text" {
	local dir
	dir="$(make_tasks_dir valid-open.md valid-done.md)"
	export VIGIL_TASKS_DIR="$dir"
	run vigil-task-reader
	[ "$status" -eq 0 ]
	local line
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		[[ "$line" == /* ]]
	done <<<"$output"
}

@test "empty tasks directory produces zero stdout lines and exit 0" {
	local dir
	dir="$(mktemp -d)"
	export VIGIL_TASKS_DIR="$dir"
	run --separate-stderr vigil-task-reader
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
	[ "$stderr" = "" ]
}

@test "nonexistent tasks directory produces zero stdout lines and exit 0" {
	export VIGIL_TASKS_DIR="/nonexistent/path/does/not/exist-$$"
	run --separate-stderr vigil-task-reader
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
	[ "$stderr" = "" ]
}

@test "missing field (missing-id.md) is logged to stderr and skipped, valid-open.md still appears" {
	local dir
	dir="$(make_tasks_dir valid-open.md missing-id.md)"
	export VIGIL_TASKS_DIR="$dir"
	run --separate-stderr vigil-task-reader
	[ "$status" -eq 0 ]
	[ "$output" = "${dir}/valid-open.md" ]
	[[ "$stderr" == *"missing-id.md"* ]]
	[[ "$stderr" == *"id"* ]]
}

@test "missing field (missing-status.md) is logged to stderr and skipped, valid-open.md still appears" {
	local dir
	dir="$(make_tasks_dir valid-open.md missing-status.md)"
	export VIGIL_TASKS_DIR="$dir"
	run --separate-stderr vigil-task-reader
	[ "$status" -eq 0 ]
	[ "$output" = "${dir}/valid-open.md" ]
	[[ "$stderr" == *"missing-status.md"* ]]
	[[ "$stderr" == *"status"* ]]
}

@test "missing field (missing-assignee.md) is logged to stderr and skipped, valid-open.md still appears" {
	local dir
	dir="$(make_tasks_dir valid-open.md missing-assignee.md)"
	export VIGIL_TASKS_DIR="$dir"
	run --separate-stderr vigil-task-reader
	[ "$status" -eq 0 ]
	[ "$output" = "${dir}/valid-open.md" ]
	[[ "$stderr" == *"missing-assignee.md"* ]]
	[[ "$stderr" == *"assignee"* ]]
}

@test "missing field (missing-created.md) is logged to stderr and skipped, valid-open.md still appears" {
	local dir
	dir="$(make_tasks_dir valid-open.md missing-created.md)"
	export VIGIL_TASKS_DIR="$dir"
	run --separate-stderr vigil-task-reader
	[ "$status" -eq 0 ]
	[ "$output" = "${dir}/valid-open.md" ]
	[[ "$stderr" == *"missing-created.md"* ]]
	# Exact reason, not just the substring "created" (which the fixture
	# filename alone would satisfy).
	[[ "$stderr" == *"missing field 'created'"* ]]
}

@test "unparseable frontmatter (unparseable-no-close.md) is logged to stderr and skipped, valid-open.md still appears" {
	local dir
	dir="$(make_tasks_dir valid-open.md unparseable-no-close.md)"
	export VIGIL_TASKS_DIR="$dir"
	run --separate-stderr vigil-task-reader
	[ "$status" -eq 0 ]
	[ "$output" = "${dir}/valid-open.md" ]
	[[ "$stderr" == *"unparseable-no-close.md"* ]]
	[[ "$stderr" == *"unparseable frontmatter"* ]]
}

@test "unparseable frontmatter (unparseable-no-open.md) is logged to stderr and skipped, valid-open.md still appears" {
	local dir
	dir="$(make_tasks_dir valid-open.md unparseable-no-open.md)"
	export VIGIL_TASKS_DIR="$dir"
	run --separate-stderr vigil-task-reader
	[ "$status" -eq 0 ]
	[ "$output" = "${dir}/valid-open.md" ]
	[[ "$stderr" == *"unparseable-no-open.md"* ]]
	[[ "$stderr" == *"unparseable frontmatter"* ]]
}

@test "mismatched assignee (mismatched-assignee.md) is logged to stderr, skipped, and never on stdout" {
	local dir
	dir="$(make_tasks_dir valid-open.md mismatched-assignee.md)"
	export VIGIL_TASKS_DIR="$dir"
	run --separate-stderr vigil-task-reader
	[ "$status" -eq 0 ]
	[ "$output" = "${dir}/valid-open.md" ]
	[[ "$stderr" == *"mismatched-assignee.md"* ]]
	[[ "$output" != *"mismatched-assignee.md"* ]]
}

@test "id shape: malformed-id-shape.md is rejected with the exact reason and never corrupts the sort/join pipeline" {
	local dir
	dir="$(make_tasks_dir valid-open.md malformed-id-shape.md)"
	export VIGIL_TASKS_DIR="$dir"
	run --separate-stderr vigil-task-reader
	[ "$status" -eq 0 ]
	# (1) valid-open.md's path appears on stdout
	[[ "$output" == *"${dir}/valid-open.md"* ]]
	# (2) stdout contains exactly that one line -- no extra/truncated line
	local line_count
	line_count="$(printf '%s\n' "$output" | grep -c . || true)"
	[ "$line_count" -eq 1 ]
	# (3) stderr names the fixture and the exact reason string
	[[ "$stderr" == *"malformed-id-shape.md"* ]]
	[[ "$stderr" == *"id field is not a 14-digit timestamp"* ]]
}

@test "valid note with quoted frontmatter values (quoted-values.md) is accepted as open" {
	local dir
	dir="$(make_tasks_dir quoted-values.md)"
	export VIGIL_TASKS_DIR="$dir"
	run vigil-task-reader
	[ "$status" -eq 0 ]
	[ "$output" = "${dir}/quoted-values.md" ]
}

@test "fail-open: all ten fixtures together yield exactly the two valid open notes, exit 0" {
	local dir
	dir="$(make_tasks_dir \
		valid-open.md valid-done.md missing-id.md missing-status.md \
		missing-assignee.md mismatched-assignee.md unparseable-no-close.md \
		unparseable-no-open.md quoted-values.md malformed-id-shape.md)"
	export VIGIL_TASKS_DIR="$dir"
	run --separate-stderr vigil-task-reader
	[ "$status" -eq 0 ]
	local line_count
	line_count="$(printf '%s\n' "$output" | grep -c . || true)"
	[ "$line_count" -eq 2 ]
	echo "$output" | grep -qF "${dir}/valid-open.md"
	echo "$output" | grep -qF "${dir}/quoted-values.md"
}
