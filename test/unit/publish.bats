#!/usr/bin/env bats
# publish.bats — render/publish/refresh/no-op coverage for the state
# publishing seam, exercised against a stub tmux binary so no live server
# is required (and none is ever touched).

load '../test_helper'

setup() {
	setup_vigil_runtime

	export TMUX_STUB_DIR="$(mktemp -d)"
	export TMUX_STUB_LOG="$TMUX_STUB_DIR/calls.log"
	mkdir -p "$TMUX_STUB_DIR/bin"

	# Stub tmux: log every invocation, answer show-options/list-clients,
	# and succeed for everything else.
	cat >"$TMUX_STUB_DIR/bin/tmux" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TMUX_STUB_LOG"
case "${1:-}" in
show-options)
	opt="${*: -1}"
	if [[ "$opt" == "@vigil_auto" ]]; then
		printf '%s' "${TMUX_STUB_AUTO:-}"
	fi
	;;
list-clients)
	printf 'client-0\n'
	;;
esac
exit 0
STUB
	chmod +x "$TMUX_STUB_DIR/bin/tmux"

	export PATH="$TMUX_STUB_DIR/bin:$PATH"
	export TMUX="stub,0,0"
}

teardown() {
	unset TMUX
	rm -rf "${VIGIL_RUNTIME_DIR:-}" "${TMUX_STUB_DIR:-}"
}

@test "vigil_render_status renders the on-mode white/green string exactly" {
	source "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"

	run vigil_render_status 3 on
	[ "$status" -eq 0 ]
	[ "$output" = '#[fg=white]3 Vigil #[fg=green]●#[default]' ]
}

@test "vigil_render_status renders the off-mode red string exactly" {
	source "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"

	run vigil_render_status 0 off
	[ "$status" -eq 0 ]
	[ "$output" = '0 Vigil #[fg=red]●#[default]' ]
}

@test "vigil_render_status treats anything other than the literal on as off" {
	source "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"

	run vigil_render_status 2 anything-else
	[ "$status" -eq 0 ]
	[ "$output" = '2 Vigil #[fg=red]●#[default]' ]
}

@test "vigil_read_queue_count is 0 when the queue file is absent" {
	source "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"

	run vigil_read_queue_count
	[ "$status" -eq 0 ]
	[ "$output" = "0" ]
}

@test "vigil_read_queue_count counts a well-formed queue" {
	source "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"
	vigil_ensure_runtime_dir
	printf '%s' '{"queue":[{"pane_id":"%1"},{"pane_id":"%2"}]}' >"$(vigil_queue_file)"

	run vigil_read_queue_count
	[ "$status" -eq 0 ]
	[ "$output" = "2" ]
}

@test "vigil_read_queue_count is 0 for corrupt JSON" {
	source "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"
	vigil_ensure_runtime_dir
	printf 'not json' >"$(vigil_queue_file)"

	run vigil_read_queue_count
	[ "$status" -eq 0 ]
	[ "$output" = "0" ]
}

@test "vigil_with_lock runs the function while holding the lock and propagates its status" {
	source "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"

	test_fn() {
		printf 'ran\n'
		return 7
	}

	run vigil_with_lock test_fn
	[ "$status" -eq 7 ]
	[ "$output" = "ran" ]
}

@test "a second process attempting the same lock times out with exit 2" {
	source "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"
	vigil_ensure_runtime_dir

	(
		exec 9>"$(vigil_lock_file)"
		flock -w 2 9
		sleep 5
	) &
	local holder=$!
	sleep 0.5

	run vigil_with_lock true
	[ "$status" -eq 2 ]
	[[ "$output" == *"lock acquisition timed out after 2s"* ]]

	kill "$holder" 2>/dev/null || true
	wait "$holder" 2>/dev/null || true
}

@test "vigil-publish with no argument publishes count, auto, status, then refreshes each client" {
	run vigil-publish
	[ "$status" -eq 0 ]

	expected="$(printf '%s\n' \
		'show-options -gv @vigil_auto' \
		'set-option -g @vigil_queue_count 0' \
		'set-option -g @vigil_auto off' \
		'set-option -g @vigil_status 0 Vigil #[fg=red]●#[default]' \
		'list-clients -F #{client_name}' \
		'refresh-client -S -t client-0')"
	[ "$(cat "$TMUX_STUB_LOG")" = "$expected" ]
}

@test "vigil-publish on publishes auto on and the white/green status string" {
	run vigil-publish on
	[ "$status" -eq 0 ]

	grep -Fxq 'set-option -g @vigil_auto on' "$TMUX_STUB_LOG"
	grep -Fxq 'set-option -g @vigil_status #[fg=white]0 Vigil #[fg=green]●#[default]' "$TMUX_STUB_LOG"
}

@test "vigil-publish off publishes auto off and the red status string" {
	run vigil-publish off
	[ "$status" -eq 0 ]

	grep -Fxq 'set-option -g @vigil_auto off' "$TMUX_STUB_LOG"
	grep -Fxq 'set-option -g @vigil_status 0 Vigil #[fg=red]●#[default]' "$TMUX_STUB_LOG"
}

@test "vigil-publish with a bogus argument exits 1 and publishes nothing" {
	run vigil-publish bogus
	[ "$status" -eq 1 ]
	[[ "$output" == *"expected 'on', 'off', or no argument"* ]]
	[ ! -e "$TMUX_STUB_LOG" ]
}

@test "vigil-publish outside tmux exits 0 and never locks or invokes tmux" {
	unset TMUX

	run vigil-publish
	[ "$status" -eq 0 ]
	[ ! -e "$TMUX_STUB_LOG" ]
	[ ! -e "$VIGIL_RUNTIME_DIR/queue.lock" ]
}
