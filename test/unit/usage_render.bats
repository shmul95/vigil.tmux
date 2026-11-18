#!/usr/bin/env bats
# usage_render.bats — DEEPSEEK-02 / RENDER-01 / RENDER-02.
# The usage segment is cache-only: these tests never touch the network.

bats_require_minimum_version 1.5.0

load '../test_helper'

LIB="$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"

setup() {
	export VIGIL_RUNTIME_DIR="$(mktemp -d)"
	CACHE="$VIGIL_RUNTIME_DIR/usage-cache.json"
	export VIGIL_USAGE_CACHE="$CACHE"
}

teardown() {
	rm -rf "${VIGIL_RUNTIME_DIR:-}"
}

render_status() {
	bash -c 'source "$1"; vigil_render_status 2 off' _ "$LIB"
}

render_usage() {
	bash -c 'source "$1"; vigil_usage_segment' _ "$LIB"
}

@test "RENDER-02: an absent cache adds nothing to the status string" {
	run render_status
	[ "$output" = '#[fg=white]2 Vigil #[fg=red]●#[default]' ]
}

@test "DEEPSEEK-02: a cached balance renders as \$USD/CNY元 in its fixed color" {
	printf '%s\n' '{"deepseek":{"usd":"12.34","cny":"88.00","fetched_at":"2026-11-18T08:00:00Z","error":null}}' >"$CACHE"
	run render_usage
	[[ "$output" == *'#[fg=#4d6bfe]'* ]]
	[[ "$output" == *'$12.34/88.00元'* ]]
}

@test "DEEPSEEK-03: an error state is clearly marked, never silently wrong" {
	printf '%s\n' '{"deepseek":{"usd":"12.34","cny":"88.00","fetched_at":"2026-11-18T08:00:00Z","error":"fetch failed (exit 22)"}}' >"$CACHE"
	run render_usage
	[[ "$output" == *'!$12.34/88.00元'* ]]
}

@test "DEEPSEEK-03: an error with no cached values renders a marked placeholder" {
	printf '%s\n' '{"deepseek":{"error":"DEEPSEEK_API_KEY not set"}}' >"$CACHE"
	run render_usage
	[[ "$output" == *'!DS'* ]]
}

@test "RENDER-02: a cache older than 45 minutes is marked stale" {
	printf '%s\n' '{"deepseek":{"usd":"1.00","cny":"7.00","fetched_at":"2020-01-01T00:00:00Z","error":null}}' >"$CACHE"
	run render_usage
	[[ "$output" == *'~$1.00/7.00元'* ]]
}

@test "CLAUDE render path: percentages render in Claude's fixed color" {
	printf '%s\n' '{"claude":{"five_hour_pct":42,"seven_day_pct":17,"fetched_at":"2026-11-18T08:00:00Z","error":null}}' >"$CACHE"
	run render_usage
	[[ "$output" == *'#[fg=#d97757]42%/17%'* ]]
}

@test "CLAUDE render path: a missing window renders a placeholder, not a wrong number" {
	printf '%s\n' '{"claude":{"seven_day_pct":17,"fetched_at":"2026-11-18T08:00:00Z","error":null}}' >"$CACHE"
	run render_usage
	[[ "$output" == *'–/17%'* ]]
}

@test "RENDER-02: a stale Claude cache is marked the same way as DeepSeek" {
	printf '%s\n' '{"claude":{"five_hour_pct":42,"seven_day_pct":17,"fetched_at":"2020-01-01T00:00:00Z","error":null}}' >"$CACHE"
	run render_usage
	[[ "$output" == *'~42%/17%'* ]]
}

@test "RENDER-01: the queue/auto segment is preserved and the usage segment appended" {
	printf '%s\n' '{"deepseek":{"usd":"1.00","cny":"7.00","fetched_at":"2999-01-01T00:00:00Z","error":null}}' >"$CACHE"
	run render_status
	[[ "$output" == '#[fg=white]2 Vigil #[fg=red]●#[default] '* ]]
	[[ "$output" == *'$1.00/7.00元'* ]]
}

@test "RENDER-01: the render path contains no network client" {
	run grep -cE '\b(curl|wget)\b' "$LIB"
	[ "$output" -eq 0 ]
}
