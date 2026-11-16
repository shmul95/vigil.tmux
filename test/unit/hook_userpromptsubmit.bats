#!/usr/bin/env bats
# hook_userpromptsubmit.bats — behavior coverage for
# vigil-hook-userpromptsubmit, the Claude Code UserPromptSubmit hook
# client (DETECT-03/NAV-04: submitting a prompt dequeues the firing
# pane). Also proves DETECT-05's fail-open guarantee via fault
# injection: a corrupted queue file, an unacquirable lock, and
# termination by SIGTERM while the hook is still running must all still
# result in the hook itself exiting 0.

load '../test_helper'

@test "dequeues the firing pane when it is currently queued" {
	vigil-queue enqueue '%7'
	TMUX_PANE='%7' run bash -c "vigil-hook-userpromptsubmit < '$BATS_TEST_DIRNAME/../fixtures/hooks/userpromptsubmit.json'"
	[ "$status" -eq 0 ]
	[ "$(vigil-queue count)" = "0" ]
}

@test "no-ops cleanly when the firing pane is not currently queued" {
	TMUX_PANE='%7' run bash -c "vigil-hook-userpromptsubmit < '$BATS_TEST_DIRNAME/../fixtures/hooks/userpromptsubmit.json'"
	[ "$status" -eq 0 ]
	[ "$(vigil-queue count)" = "0" ]
}

@test "fails closed (no dequeue) when TMUX_PANE is unset" {
	vigil-queue enqueue '%7'
	unset TMUX_PANE
	run bash -c "unset TMUX_PANE; vigil-hook-userpromptsubmit < '$BATS_TEST_DIRNAME/../fixtures/hooks/userpromptsubmit.json'"
	[ "$status" -eq 0 ]
	[ "$(vigil-queue count)" = "1" ]
}

@test "VIGIL_DEBUG=1 emits a stderr trace line mentioning the hook" {
	TMUX_PANE='%7' VIGIL_DEBUG=1 run bash -c "vigil-hook-userpromptsubmit < '$BATS_TEST_DIRNAME/../fixtures/hooks/userpromptsubmit.json'"
	[ "$status" -eq 0 ]
	[[ "$output" == *"UserPromptSubmit"* || "$output" == *"vigil-hook-userpromptsubmit"* ]]
}

@test "DETECT-05: exits 0 even when queue.json is corrupted" {
	echo 'not valid json' >"$VIGIL_RUNTIME_DIR/queue.json"
	TMUX_PANE='%7' run timeout 5 bash -c "vigil-hook-userpromptsubmit < '$BATS_TEST_DIRNAME/../fixtures/hooks/userpromptsubmit.json'"
	[ "$status" -eq 0 ]
}

@test "DETECT-05: exits 0 even when the queue lock cannot be acquired" {
	exec {lock_fd}>"$VIGIL_RUNTIME_DIR/queue.lock"
	flock "$lock_fd"
	(
		sleep 3
		flock -u "$lock_fd" 2>/dev/null
	) &
	local holder=$!

	TMUX_PANE='%7' run timeout 5 bash -c "vigil-hook-userpromptsubmit < '$BATS_TEST_DIRNAME/../fixtures/hooks/userpromptsubmit.json'"
	[ "$status" -eq 0 ]

	wait "$holder" 2>/dev/null || true
}

@test "DETECT-05: exits 0 when killed by SIGTERM while blocked reading stdin" {
	mkfifo "$VIGIL_RUNTIME_DIR/hang.fifo"
	# Open the fifo O_RDWR (not O_WRONLY via a plain `>` redirect) so this
	# open() call itself never blocks: a FIFO's write-only open blocks
	# until a reader connects, and nothing has opened the read end yet at
	# this point -- `<>` sidesteps that by opening both directions on one
	# fd, which Linux never blocks on for a FIFO. This keeps a writer
	# connected (without ever writing or closing it) so the hook's own
	# read redirection below connects immediately and the hook blocks
	# INSIDE its stdin read (after its traps are already registered), not
	# at the shell's own open() before the script body even runs.
	exec {writer_fd}<>"$VIGIL_RUNTIME_DIR/hang.fifo"

	# Launched via `setsid` (its own process group) rather than a bare
	# background job: the hook's blocking read (vigil_hook_read_stdin's
	# `cat`, invoked through a command-substitution subshell) means the
	# actual process blocked on the fifo is a FORKED CHILD of the hook
	# script's own bash interpreter, not the interpreter itself. Bash
	# defers running a pending trap until it finishes waiting on whatever
	# foreground child it is currently blocked on (this is documented
	# bash behavior, not a bug in this test) -- so a plain `kill -TERM` to
	# only the top-level hook_pid would be silently deferred forever,
	# since that wait never completes on its own in this fixture. Signal
	# the whole process group instead (`kill -TERM -- "-$hook_pid"`),
	# matching how a real process supervisor (Claude Code's own hook
	# `timeout`) tears down a subprocess tree -- this reaches the blocked
	# `cat` child directly, which dies immediately on default SIGTERM,
	# unblocking the parent's wait so its own TERM trap then runs.
	TMUX_PANE='%7' setsid vigil-hook-userpromptsubmit <"$VIGIL_RUNTIME_DIR/hang.fifo" &
	local hook_pid=$!
	sleep 0.3
	kill -TERM -- "-$hook_pid"
	wait "$hook_pid"
	local hook_status=$?
	[ "$hook_status" -eq 0 ]

	exec {writer_fd}>&-
}
