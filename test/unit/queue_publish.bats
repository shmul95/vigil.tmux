#!/usr/bin/env bats
# queue_publish.bats — proves every vigil-queue mutation publishes state
# inside the shared lock, without altering stdout/exit status, and that a
# mode flip and an enqueue serialized through the same lock lose neither
# update.

load '../test_helper'

setup() {
	setup_vigil_runtime

	export TMUX_STUB_DIR="$(mktemp -d)"
	export TMUX_STUB_LOG="$TMUX_STUB_DIR/calls.log"
	mkdir -p "$TMUX_STUB_DIR/bin" "$TMUX_STUB_DIR/opt"

	# Stateful stub tmux: persists option values to files so concurrent
	# readers observe the latest published state. WR-05 batches multiple
	# set-option writes into a single tmux invocation using tmux's own
	# "cmd1 \; cmd2 \; cmd3" multi-command syntax (each "\;" arrives here
	# as a literal standalone ";" argv element, exactly as real tmux
	# receives it) -- split on that so each sub-command is still logged
	# and handled individually, as if it had been its own invocation.
	cat >"$TMUX_STUB_DIR/bin/tmux" <<'STUB'
#!/usr/bin/env bash
args=("$@")
n=${#args[@]}
start=0
i=0
while [[ $i -le $n ]]; do
	if [[ $i -eq $n || "${args[$i]}" == ";" ]]; then
		if [[ $i -gt $start ]]; then
			sub=("${args[@]:$start:$((i - start))}")
			printf '%s\n' "${sub[*]}" >>"$TMUX_STUB_LOG"
			case "${sub[0]:-}" in
			show-options)
				opt="${sub[-1]}"
				if [[ -f "$TMUX_STUB_DIR/opt/$opt" ]]; then
					cat "$TMUX_STUB_DIR/opt/$opt"
				elif [[ "$opt" == "@vigil_auto" ]]; then
					printf '%s' "${TMUX_STUB_AUTO:-}"
				fi
				;;
			set-option)
				mkdir -p "$TMUX_STUB_DIR/opt"
				printf '%s' "${sub[3]:-}" >"$TMUX_STUB_DIR/opt/${sub[2]}"
				;;
			list-clients)
				printf 'client-0\n'
				;;
			refresh-client) ;;
			esac
		fi
		start=$((i + 1))
	fi
	i=$((i + 1))
done
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

stub_opt() {
	cat "$TMUX_STUB_DIR/opt/$1" 2>/dev/null || true
}

@test "enqueue publishes count, auto, and rendered status through one batch" {
	run vigil-queue enqueue '%1'
	[ "$status" -eq 0 ]
	[ "$(stub_opt @vigil_queue_count)" = "1" ]
	[ "$(stub_opt @vigil_auto)" = "off" ]
	[ "$(stub_opt @vigil_status)" = '#[fg=white]1 Vigil #[fg=red]●#[default]' ]
	[ "$(grep -c '^set-option -g @vigil_status' "$TMUX_STUB_LOG")" -eq 1 ]
}

@test "every mutation publishes exactly one batch whose count matches the queue" {
	vigil-queue enqueue '%1'
	vigil-queue enqueue '%2'
	: >"$TMUX_STUB_LOG"

	vigil-queue rotate
	[ "$(grep -c '^set-option -g @vigil_status' "$TMUX_STUB_LOG")" -eq 1 ]
	[ "$(stub_opt @vigil_queue_count)" = "$(vigil-queue count)" ]
	: >"$TMUX_STUB_LOG"

	vigil-queue prune '%1' '%2'
	[ "$(grep -c '^set-option -g @vigil_status' "$TMUX_STUB_LOG")" -eq 1 ]
	[ "$(stub_opt @vigil_queue_count)" = "$(vigil-queue count)" ]
	: >"$TMUX_STUB_LOG"

	vigil-queue dequeue '%1'
	[ "$(grep -c '^set-option -g @vigil_status' "$TMUX_STUB_LOG")" -eq 1 ]
	[ "$(stub_opt @vigil_queue_count)" = "$(vigil-queue count)" ]
	: >"$TMUX_STUB_LOG"

	vigil-queue enqueue '%3'
	[ "$(grep -c '^set-option -g @vigil_status' "$TMUX_STUB_LOG")" -eq 1 ]
	[ "$(stub_opt @vigil_queue_count)" = "$(vigil-queue count)" ]
}

@test "re-enqueueing an already-queued pane still publishes (count unchanged)" {
	vigil-queue enqueue '%1'
	: >"$TMUX_STUB_LOG"

	run vigil-queue enqueue '%1'
	[ "$status" -eq 0 ]
	[ "$(grep -c '^set-option -g @vigil_status' "$TMUX_STUB_LOG")" -eq 1 ]
	[ "$(vigil-queue count)" = "1" ]
	[ "$(stub_opt @vigil_queue_count)" = "1" ]
}

@test "an existing auto=on is preserved and publishes the white/green status" {
	export TMUX_STUB_AUTO=on

	run vigil-queue enqueue '%1'
	[ "$status" -eq 0 ]
	[ "$(stub_opt @vigil_auto)" = "on" ]
	[ "$(stub_opt @vigil_status)" = '#[fg=white]1 Vigil #[fg=green]●#[default]' ]
}

@test "outside tmux mutations still succeed and never invoke the tmux stub" {
	unset TMUX

	run vigil-queue enqueue '%1'
	[ "$status" -eq 0 ]
	run vigil-queue dequeue '%1'
	[ "$status" -eq 0 ]
	[ ! -e "$TMUX_STUB_LOG" ]
	[ "$(vigil-queue count)" = "0" ]
}

@test "rotate still prints only the new head pane id while publishing" {
	vigil-queue enqueue '%1'
	vigil-queue enqueue '%2'
	: >"$TMUX_STUB_LOG"

	run vigil-queue rotate
	[ "$status" -eq 0 ]
	[ "$output" = "%2" ]
	[ "$(stub_opt @vigil_queue_count)" = "2" ]
}

@test "concurrent publish-on and enqueue lose neither the mode flip nor the count" {
	vigil-publish on &
	publish_pid=$!
	vigil-queue enqueue '%1' &
	enqueue_pid=$!
	wait "$publish_pid" "$enqueue_pid"

	[ "$(stub_opt @vigil_auto)" = "on" ]
	[ "$(vigil-queue count)" = "1" ]
	[ "$(stub_opt @vigil_queue_count)" = "1" ]
}

@test "WR-05: 5 concurrent enqueues against a stubbed tmux never time out" {
	# Before WR-05, the critical section covered 4+ separate tmux execs
	# (3 set-option writes plus the per-client refresh-client walk)
	# under the hardcoded 2s flock timeout. Batching the option writes
	# into one invocation and moving refresh-client out of the lock
	# shrinks that window; this proves 5-way contention against it never
	# produces a dropped mutation (exit 2).
	local pids=() pid i wstatus
	for i in 1 2 3 4 5; do
		vigil-queue enqueue "%wr05-$i" &
		pids+=("$!")
	done
	for pid in "${pids[@]}"; do
		wstatus=0
		wait "$pid" || wstatus=$?
		[ "$wstatus" -ne 2 ]
	done
	[ "$(vigil-queue count)" = "5" ]
	[ "$(stub_opt @vigil_queue_count)" = "5" ]
}
