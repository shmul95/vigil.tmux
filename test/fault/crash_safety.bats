#!/usr/bin/env bats
# crash_safety.bats — fault injection proving SIGKILL mid-write never
# corrupts queue.json (phase success criterion 3). Exploits
# VIGIL_QUEUE_TEST_DELAY, the fault-injection seam inside
# _vigil_write_queue_atomic (scripts/vigil-queue), to kill the process
# inside the window between the temp-file write and the atomic `mv`.

load '../test_helper'

@test "SIGKILL mid-write across 10 iterations never corrupts queue.json" {
	source "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"

	for i in $(seq 1 10); do
		VIGIL_QUEUE_TEST_DELAY=0.2 vigil-queue enqueue "%kill$i" &
		local pid=$!
		sleep "0.0$(((RANDOM % 9) + 1))"
		kill -9 "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true

		run jq empty "$(vigil_queue_file)" 2>/dev/null
		if [ "$status" -ne 0 ] && [ -e "$(vigil_queue_file)" ]; then
			echo "iteration $i: queue file exists but is invalid JSON" >&2
			false
		fi
	done

	# Sanity check: the helper never resolves to a .tmp path.
	[ "$(basename "$(vigil_queue_file)")" = "queue.json" ]

	# Leftover *.tmp.* files from killed processes are harmless clutter,
	# not corruption — the real queue file (if it exists at all; a killed
	# writer may never have completed its mv) must never be present-and-invalid.
	run jq empty "$(vigil_queue_file)" 2>/dev/null
	[ "$status" -eq 0 ] || [ ! -e "$(vigil_queue_file)" ]
}

@test "CR-01: SIGKILL while holding the lock releases it immediately, not after the 2s timeout" {
	source "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"

	# Hold the lock via the fault-injection delay, then kill the holder
	# mid-sleep. Before the CR-01 fix, the orphaned `sleep` inherited a
	# copy of the lock FD and kept flock held, so the next mutation below
	# would block for the full 2s `flock -w 2` and exit 2.
	VIGIL_QUEUE_TEST_DELAY=3 vigil-queue enqueue '%victim' &
	local holder=$!
	sleep 0.5
	kill -9 "$holder" 2>/dev/null || true
	wait "$holder" 2>/dev/null || true

	# The lock must be acquirable well within the 2s timeout now that the
	# orphaned sleep no longer holds a copy of the FD -- bound this with a
	# 1s wall-clock timeout so a regression (silently waiting the full 2s
	# and exiting 2) fails this assertion rather than just being slow.
	run timeout 1 vigil-queue enqueue '%second'
	[ "$status" -eq 0 ]
	[ "$(vigil-queue count)" = "1" ]
	[ "$(vigil-queue peek | jq -r '.pane_id')" = "%second" ]
}

# WR-02 (iteration 3): the CR-01 regression test above only ever drove the
# fault-injection seam through `enqueue`. `dequeue` and `rotate` each
# independently write through the SAME `_vigil_write_queue_atomic`
# (scripts/vigil-queue), so VIGIL_QUEUE_TEST_DELAY already covers them --
# but nothing in the shipped suite exercised that until now. These two
# tests mirror the CR-01 case exactly, just driving a different
# subcommand, so a future regression confined to one of these call sites
# (rather than enqueue's) would actually be caught.

@test "WR-02: SIGKILL while holding the lock during dequeue releases it immediately" {
	source "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"

	vigil-queue enqueue '%victim'

	VIGIL_QUEUE_TEST_DELAY=3 vigil-queue dequeue '%victim' &
	local holder=$!
	sleep 0.5
	kill -9 "$holder" 2>/dev/null || true
	wait "$holder" 2>/dev/null || true

	# Killed mid-delay, before the atomic `mv` -- the queued '%victim' is
	# never actually removed (the write that would have removed it never
	# landed), so it is still the head after '%second' is appended. The
	# assertion that matters here is lock-release timing, not which
	# entries survive -- D-05 is covered by crash_safety.bats's first
	# test, not this one.
	run timeout 1 vigil-queue enqueue '%second'
	[ "$status" -eq 0 ]
	[ "$(vigil-queue count)" = "2" ]
	[ "$(vigil-queue peek | jq -r '.pane_id')" = "%victim" ]
}

@test "WR-02: SIGKILL while holding the lock during rotate releases it immediately" {
	source "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"

	vigil-queue enqueue '%a'
	vigil-queue enqueue '%b'

	VIGIL_QUEUE_TEST_DELAY=3 vigil-queue rotate &
	local holder=$!
	sleep 0.5
	kill -9 "$holder" 2>/dev/null || true
	wait "$holder" 2>/dev/null || true

	run timeout 1 vigil-queue enqueue '%second'
	[ "$status" -eq 0 ]
	[ "$(vigil-queue count)" = "3" ]
}

@test "WR-02: SIGKILL while holding the lock during vigil_publish_state's batched tmux call releases it immediately" {
	# Reproduces the reviewer's manual fault injection (REVIEW.md iteration
	# 3, WR-02) in an automated form: shadow `tmux` with a slow stub so
	# the batched `set-option` call inside vigil_publish_state
	# (scripts/lib/vigil-common.sh, called from inside the lock by every
	# vigil-queue mutation) is still forked-and-running when the holder is
	# killed. Before _vigil_close_lock_fd covered this call site, the
	# orphaned tmux child would inherit a copy of the lock FD and keep
	# flock held past the holder's death.
	source "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"

	vigil-queue enqueue '%pre'

	local stub_dir real_path
	stub_dir="$(mktemp -d)"
	cat >"$stub_dir/tmux" <<'STUB'
#!/usr/bin/env bash
case "$1" in
set-option)
	sleep 3
	;;
esac
exit 0
STUB
	chmod +x "$stub_dir/tmux"

	real_path="$PATH"
	export TMUX="stub,0,0"
	export PATH="$stub_dir:$PATH"

	# Direct background of the literal vigil-queue invocation (no shell
	# function or `eval` wrapper in between) -- backgrounding either of
	# those defeats bash's tail-call `exec` optimization, so `$!` would
	# capture a wrapper subshell's PID instead of the real holder's, and
	# `kill -9` would miss the actual process (see REVIEW.md's note on
	# its own false-positive fault-injection attempts).
	vigil-queue enqueue '%victim' &
	local holder=$!
	sleep 0.5
	kill -9 "$holder" 2>/dev/null || true
	wait "$holder" 2>/dev/null || true

	unset TMUX
	export PATH="$real_path"
	rm -rf "$stub_dir"

	# Outside the stubbed TMUX/PATH now -- a plain, fast mutation proves
	# the lock released promptly rather than waiting out the stub's 3s
	# sleep or the flock's 2s timeout.
	run timeout 1 vigil-queue enqueue '%second'
	[ "$status" -eq 0 ]
	[ "$(vigil-queue count)" = "3" ]
}
