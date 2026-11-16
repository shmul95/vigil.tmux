#!/usr/bin/env bats
# hook_stop.bats — behavior coverage for vigil-hook-stop, the Claude
# Code Stop hook client. Covers unconditional enqueue of $TMUX_PANE,
# idempotency across repeated firings (the DETECT-04 dedup mechanism
# this phase relies on), fail-closed no-op when $TMUX_PANE is unset,
# and fail-open exit 0 under both a corrupted queue file (internal
# failure) and termination by SIGTERM while blocked reading stdin
# (external signal, DETECT-05).

load '../test_helper'

@test "Stop with TMUX_PANE set enqueues the pane exactly once" {
	TMUX_PANE='%7' run vigil-hook-stop <"$BATS_TEST_DIRNAME/../fixtures/hooks/stop.json"
	[ "$status" -eq 0 ]
	[ "$(vigil-queue count)" = "1" ]
	[ "$(vigil-queue peek | jq -r '.pane_id')" = "%7" ]
}

@test "Stop fired twice for the same pane is idempotent (count stays 1)" {
	TMUX_PANE='%7' run vigil-hook-stop <"$BATS_TEST_DIRNAME/../fixtures/hooks/stop.json"
	[ "$status" -eq 0 ]
	TMUX_PANE='%7' run vigil-hook-stop <"$BATS_TEST_DIRNAME/../fixtures/hooks/stop.json"
	[ "$status" -eq 0 ]
	[ "$(vigil-queue count)" = "1" ]
}

@test "Stop with TMUX_PANE unset fails closed (no-op, exit 0, queue stays empty)" {
	unset TMUX_PANE
	run vigil-hook-stop <"$BATS_TEST_DIRNAME/../fixtures/hooks/stop.json"
	[ "$status" -eq 0 ]
	[ "$(vigil-queue count)" = "0" ]
}

@test "DETECT-05: exits 0 even when queue.json is corrupted" {
	mkdir -p "$VIGIL_RUNTIME_DIR"
	echo 'not valid json' >"$VIGIL_RUNTIME_DIR/queue.json"
	TMUX_PANE='%7' run timeout 5 vigil-hook-stop <"$BATS_TEST_DIRNAME/../fixtures/hooks/stop.json"
	[ "$status" -eq 0 ]
}

@test "DETECT-05: exits 0 when killed by SIGTERM while blocked reading stdin" {
	# Deviation from the plan's literal example (Rule 1 - bug): opening
	# the fifo write-only (`>`) with no reader yet blocks forever (POSIX
	# fifo(7) semantics), so the writer fd is opened read-write (`<>`)
	# instead, which never blocks. Separately, bash's documented trap
	# semantics mean a trap NEVER preempts a foreign child (here, the
	# `cat` inside vigil_hook_read_stdin) that the shell is currently
	# wait()-ing on -- sending SIGTERM only to the hook's own pid leaves
	# it stuck forever, since `cat` itself never receives the signal and
	# the EXIT/TERM trap cannot run until `cat` returns. Claude Code's own
	# hook-timeout enforcement kills the whole process subtree it spawned,
	# so the realistic -- and actually testable -- guarantee is signaling
	# the hook's entire process GROUP, which this reproduces via `setsid`
	# (isolates the hook into its own group) + `kill -TERM -<pgid>`.
	mkfifo "$VIGIL_RUNTIME_DIR/hang.fifo"
	exec {writer_fd}<>"$VIGIL_RUNTIME_DIR/hang.fifo"

	setsid env TMUX_PANE='%7' vigil-hook-stop <"$VIGIL_RUNTIME_DIR/hang.fifo" >/dev/null 2>&1 &
	local hook_pid=$!
	sleep 0.3

	local hook_pgid
	hook_pgid="$(ps -o pgid= -p "$hook_pid" | tr -d ' ')"
	kill -TERM "-$hook_pgid"

	# Safety net: force-kill the group after 5s so a regression can never
	# hang the suite, even though the group-wide TERM above is expected
	# to let the hook exit almost immediately.
	(
		sleep 5
		kill -KILL "-$hook_pgid" 2>/dev/null
	) &
	local watchdog_pid=$!

	wait "$hook_pid"
	local hook_status=$?
	kill "$watchdog_pid" 2>/dev/null || true
	wait "$watchdog_pid" 2>/dev/null || true

	[ "$hook_status" -eq 0 ]

	exec {writer_fd}>&-
}
