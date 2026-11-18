#!/usr/bin/env bats
# usage_refresh.bats — DEEPSEEK-01/DEEPSEEK-03/REFRESH-01 proof for
# `vigil-usage-refresh`. `curl` is stubbed on PATH; no test touches the
# network and no real credential is ever read.

bats_require_minimum_version 1.5.0

load '../test_helper'

REFRESH="$BATS_TEST_DIRNAME/../../scripts/vigil-usage-refresh"

setup() {
	export VIGIL_RUNTIME_DIR="$(mktemp -d)"
	CACHE="$VIGIL_RUNTIME_DIR/usage-cache.json"
	STUB_DIR="$(mktemp -d)"
	mkdir -p "$STUB_DIR/bin"
	cat >"$STUB_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_CALLS_LOG"
if [[ -n "${CURL_BODY_FILE:-}" ]]; then
	cat "$CURL_BODY_FILE"
fi
exit "${CURL_EXIT:-0}"
EOF
	chmod +x "$STUB_DIR/bin/curl"
	export CURL_CALLS_LOG="$STUB_DIR/calls.log"
	: >"$CURL_CALLS_LOG"
	export PATH="$STUB_DIR/bin:$PATH"
	export DEEPSEEK_API_KEY="test-key-not-real"
}

teardown() {
	rm -rf "${VIGIL_RUNTIME_DIR:-}" "${STUB_DIR:-}"
}

stub_body() {
	BODY_FILE="$STUB_DIR/body.json"
	cat >"$BODY_FILE"
	export CURL_BODY_FILE="$BODY_FILE"
}

@test "DEEPSEEK-01: a 200 response caches USD and CNY total balances plus a timestamp" {
	stub_body <<'EOF'
{"is_available":true,"balance_infos":[
 {"currency":"USD","total_balance":"12.34","granted_balance":"0.00","topped_up_balance":"12.34"},
 {"currency":"CNY","total_balance":"88.00","granted_balance":"0.00","topped_up_balance":"88.00"}]}
EOF
	run --separate-stderr "$REFRESH"
	[ "$status" -eq 0 ]
	run jq -r '.deepseek.usd' "$CACHE"
	[ "$output" = "12.34" ]
	run jq -r '.deepseek.cny' "$CACHE"
	[ "$output" = "88.00" ]
	run jq -r '.deepseek.fetched_at // empty' "$CACHE"
	[ -n "$output" ]
	run jq -r '.deepseek.error // "null"' "$CACHE"
	[ "$output" = "null" ]
}

@test "DEEPSEEK-01: selects currencies by the currency field, never by array index" {
	stub_body <<'EOF'
{"is_available":true,"balance_infos":[
 {"currency":"CNY","total_balance":"70.00"},
 {"currency":"USD","total_balance":"10.00"}]}
EOF
	run "$REFRESH"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.deepseek.usd' "$CACHE")" = "10.00" ]
	[ "$(jq -r '.deepseek.cny' "$CACHE")" = "70.00" ]
}

@test "DEEPSEEK-01: a response with no USD entry leaves usd null without erroring" {
	stub_body <<'EOF'
{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"70.00"}]}
EOF
	run "$REFRESH"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.deepseek.usd // "null"' "$CACHE")" = "null" ]
	[ "$(jq -r '.deepseek.cny' "$CACHE")" = "70.00" ]
	[ "$(jq -r '.deepseek.error // "null"' "$CACHE")" = "null" ]
}

@test "DEEPSEEK-03: a non-200 leaves the previous cache intact and records an error" {
	stub_body <<'EOF'
{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"5.00"},{"currency":"CNY","total_balance":"35.00"}]}
EOF
	run "$REFRESH"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.deepseek.usd' "$CACHE")" = "5.00" ]

	export CURL_EXIT=22
	run --separate-stderr "$REFRESH"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.deepseek.usd' "$CACHE")" = "5.00" ]
	[ "$(jq -r '.deepseek.cny' "$CACHE")" = "35.00" ]
	run jq -r '.deepseek.error // empty' "$CACHE"
	[ -n "$output" ]
}

@test "DEEPSEEK-03: a missing key records an error and never invokes curl" {
	unset DEEPSEEK_API_KEY
	run --separate-stderr "$REFRESH"
	[ "$status" -eq 0 ]
	[ -s "$CACHE" ]
	run jq -r '.deepseek.error // empty' "$CACHE"
	[ -n "$output" ]
	[ ! -s "$CURL_CALLS_LOG" ]
}

@test "DEEPSEEK-03: malformed JSON leaves the previous cache intact and records an error" {
	stub_body <<'EOF'
{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"9.99"}]}
EOF
	run "$REFRESH"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.deepseek.usd' "$CACHE")" = "9.99" ]

	stub_body <<'EOF'
this is not json
EOF
	run --separate-stderr "$REFRESH"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.deepseek.usd' "$CACHE")" = "9.99" ]
	run jq -r '.deepseek.error // empty' "$CACHE"
	[ -n "$output" ]
}

@test "REFRESH-02: a deepseek-only refresh preserves an existing claude entry" {
	mkdir -p "$VIGIL_RUNTIME_DIR"
	printf '%s\n' '{"claude":{"five_hour_pct":42,"seven_day_pct":17}}' >"$CACHE"
	stub_body <<'EOF'
{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"1.00"}]}
EOF
	run "$REFRESH"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.claude.five_hour_pct' "$CACHE")" = "42" ]
	[ "$(jq -r '.deepseek.cny' "$CACHE")" = "1.00" ]
}

@test "REFRESH-01: concurrent refreshes never leave a corrupt cache" {
	stub_body <<'EOF'
{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"1.00"},{"currency":"CNY","total_balance":"7.00"}]}
EOF
	for _ in 1 2 3 4 5; do "$REFRESH" & done
	wait
	run jq -e . "$CACHE"
	[ "$status" -eq 0 ]
}

@test "REFRESH-01: no partial cache file is left behind after a successful run" {
	stub_body <<'EOF'
{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"3.00"}]}
EOF
	run "$REFRESH"
	[ "$status" -eq 0 ]
	run bash -c 'ls "$VIGIL_RUNTIME_DIR" | grep -c "usage-cache.json.tmp" || true'
	[ "$output" -eq 0 ]
}
