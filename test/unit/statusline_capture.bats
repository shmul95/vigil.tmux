#!/usr/bin/env bats
# statusline_capture.bats — CLAUDE-01 / CLAUDE-02.
# Feeds fixture statusline stdin JSON to the capture wrapper; no network
# and no credentials are involved anywhere.

bats_require_minimum_version 1.5.0

load '../test_helper'

CAPTURE="$BATS_TEST_DIRNAME/../../scripts/vigil-statusline-capture"

setup() {
	export VIGIL_RUNTIME_DIR="$(mktemp -d)"
	CACHE="$VIGIL_RUNTIME_DIR/usage-cache.json"
	export VIGIL_USAGE_CACHE="$CACHE"
	WRAPPED="$VIGIL_RUNTIME_DIR/wrapped.sh"
	cat >"$WRAPPED" <<'EOF'
#!/usr/bin/env bash
cat >"$WRAPPED_STDIN"
printf 'ORIGINAL-STATUS\n'
EOF
	chmod +x "$WRAPPED"
	export WRAPPED_STDIN="$VIGIL_RUNTIME_DIR/wrapped.stdin"
}

teardown() {
	rm -rf "${VIGIL_RUNTIME_DIR:-}"
}

sample_stdin() {
	cat <<'EOF'
{"session_id":"abc","rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1790000000},"seven_day":{"used_percentage":17,"resets_at":1790500000}}}
EOF
}

@test "CLAUDE-01: caches the documented five_hour and seven_day percentages and resets" {
	sample_stdin | "$CAPTURE" >/dev/null
	[ "$(jq -r '.claude.five_hour_pct' "$CACHE")" = "42" ]
	[ "$(jq -r '.claude.seven_day_pct' "$CACHE")" = "17" ]
	[ "$(jq -r '.claude.five_hour_resets_at' "$CACHE")" = "1790000000" ]
	[ "$(jq -r '.claude.seven_day_resets_at' "$CACHE")" = "1790500000" ]
	[ "$(jq -r '.claude.error // "null"' "$CACHE")" = "null" ]
}

@test "CLAUDE-01: the wrapped command receives identical stdin and its output is returned" {
	LC_ALL=C
	sample_stdin >"$WRAPPED_STDIN.expected"
	out="$(sample_stdin | "$CAPTURE" "$WRAPPED")"
	[ "$out" = "ORIGINAL-STATUS" ]
	cmp -s "$WRAPPED_STDIN" "$WRAPPED_STDIN.expected"
}

@test "CLAUDE-01: the wrapped command's exit status is preserved" {
	FAILER="$VIGIL_RUNTIME_DIR/failer.sh"
	printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 3\n' >"$FAILER"
	chmod +x "$FAILER"
	run bash -c 'printf "%s" "{}" | "$1" "$2"' _ "$CAPTURE" "$FAILER"
	[ "$status" -eq 3 ]
}

@test "CLAUDE-02: an absent window is cached as null without a wrong number" {
	cat <<'EOF' | "$CAPTURE" >/dev/null
{"rate_limits":{"seven_day":{"used_percentage":17,"resets_at":1790500000}}}
EOF
	[ "$(jq -r '.claude.five_hour_pct // "null"' "$CACHE")" = "null" ]
	[ "$(jq -r '.claude.seven_day_pct' "$CACHE")" = "17" ]
}

@test "CLAUDE-01: input without rate_limits creates no claude entry but still passes through" {
	out="$(printf '%s' '{"session_id":"abc"}' | "$CAPTURE" "$WRAPPED")"
	[ "$out" = "ORIGINAL-STATUS" ]
	run jq -e 'has("claude")' "$CACHE"
	[ "$status" -ne 0 ]
}

@test "REFRESH-02: capturing Claude preserves an existing deepseek entry" {
	printf '%s\n' '{"deepseek":{"usd":"1.00","cny":"7.00"}}' >"$CACHE"
	sample_stdin | "$CAPTURE" >/dev/null
	[ "$(jq -r '.deepseek.usd' "$CACHE")" = "1.00" ]
	[ "$(jq -r '.claude.five_hour_pct' "$CACHE")" = "42" ]
}

@test "CLAUDE-02: an unchanged reading does not rewrite the cache (throttling)" {
	sample_stdin | "$CAPTURE" >/dev/null
	inode_before="$(stat -c %i "$CACHE")"
	sample_stdin | "$CAPTURE" >/dev/null
	inode_after="$(stat -c %i "$CACHE")"
	[ "$inode_before" = "$inode_after" ]
}

@test "CLAUDE-01: with no writable cache the wrapper still passes the status through" {
	export VIGIL_USAGE_CACHE="/nonexistent-dir/forbidden/cache.json"
	run bash -c 'printf "%s" "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":5}}}" | "$1" "$2"' _ "$CAPTURE" "$WRAPPED"
	[ "$status" -eq 0 ]
	[[ "$output" == *"ORIGINAL-STATUS"* ]]
}
