#!/usr/bin/env bats
# hook_notification.bats — behavior coverage for vigil-hook-notification,
# the Claude Code Notification hook client. Covers the DETECT-02
# allow-list precision (Pitfall 8): only idle_prompt, permission_prompt,
# and agent_needs_input enqueue; explicit noise subtypes AND any
# unknown/future/missing subtype are denied by default. Also covers
# fail-open exit 0 under a corrupted queue file and termination by
# SIGTERM while blocked reading stdin (DETECT-05).

load '../test_helper'

@test "idle_prompt enqueues" {
	TMUX_PANE='%7' run vigil-hook-notification <"$BATS_TEST_DIRNAME/../fixtures/hooks/notification_idle_prompt.json"
	[ "$status" -eq 0 ]
	[ "$(vigil-queue count)" = "1" ]
}

@test "permission_prompt enqueues" {
	TMUX_PANE='%7' run vigil-hook-notification <"$BATS_TEST_DIRNAME/../fixtures/hooks/notification_permission_prompt.json"
	[ "$status" -eq 0 ]
	[ "$(vigil-queue count)" = "1" ]
}

@test "agent_needs_input enqueues" {
	TMUX_PANE='%7' run vigil-hook-notification <"$BATS_TEST_DIRNAME/../fixtures/hooks/notification_agent_needs_input.json"
	[ "$status" -eq 0 ]
	[ "$(vigil-queue count)" = "1" ]
}

@test "auth_success (explicit noise) never enqueues" {
	TMUX_PANE='%7' run vigil-hook-notification <"$BATS_TEST_DIRNAME/../fixtures/hooks/notification_auth_success.json"
	[ "$status" -eq 0 ]
	[ "$(vigil-queue count)" = "0" ]
}

@test "quota_auto_resume_fired (explicit noise) never enqueues" {
	TMUX_PANE='%7' run vigil-hook-notification <"$BATS_TEST_DIRNAME/../fixtures/hooks/notification_quota_auto_resume.json"
	[ "$status" -eq 0 ]
	[ "$(vigil-queue count)" = "0" ]
}

@test "unknown/future notification_type default-denies (Pitfall 8 regression)" {
	TMUX_PANE='%7' run vigil-hook-notification <"$BATS_TEST_DIRNAME/../fixtures/hooks/notification_unknown_type.json"
	[ "$status" -eq 0 ]
	[ "$(vigil-queue count)" = "0" ]
}

@test "missing notification_type field default-denies (default is honored, not bypassed)" {
	TMUX_PANE='%7' run vigil-hook-notification <"$BATS_TEST_DIRNAME/../fixtures/hooks/notification_missing_type.json"
	[ "$status" -eq 0 ]
	[ "$(vigil-queue count)" = "0" ]
}

@test "DETECT-05: exits 0 even when queue.json is corrupted" {
	mkdir -p "$VIGIL_RUNTIME_DIR"
	echo 'not valid json' >"$VIGIL_RUNTIME_DIR/queue.json"
	TMUX_PANE='%7' run timeout 5 vigil-hook-notification <"$BATS_TEST_DIRNAME/../fixtures/hooks/notification_idle_prompt.json"
	[ "$status" -eq 0 ]
}

@test "DETECT-05: exits 0 even when the queue lock cannot be acquired" {
	mkdir -p "$VIGIL_RUNTIME_DIR"
	exec {lock_fd}>"$VIGIL_RUNTIME_DIR/queue.lock"
	flock "$lock_fd"
	(
		sleep 3
		flock -u "$lock_fd" 2>/dev/null
	) &
	local holder=$!

	TMUX_PANE='%7' run timeout 5 vigil-hook-notification <"$BATS_TEST_DIRNAME/../fixtures/hooks/notification_idle_prompt.json"
	[ "$status" -eq 0 ]

	wait "$holder" 2>/dev/null || true
}

@test "DETECT-05: exits 0 when killed by SIGTERM while blocked reading stdin" {
	# See the matching comment in hook_stop.bats for why this signals the
	# hook's whole process GROUP (via setsid) rather than its single pid:
	# bash never preempts a trap while blocked inside a foreign child
	# (the `cat` in vigil_hook_read_stdin), so a single-pid SIGTERM can
	# never reach it; Claude Code's own hook-timeout enforcement kills
	# the whole spawned subtree, which this reproduces realistically.
	mkfifo "$VIGIL_RUNTIME_DIR/hang.fifo"
	exec {writer_fd}<>"$VIGIL_RUNTIME_DIR/hang.fifo"

	setsid env TMUX_PANE='%7' vigil-hook-notification <"$VIGIL_RUNTIME_DIR/hang.fifo" >/dev/null 2>&1 &
	local hook_pid=$!
	sleep 0.3

	local hook_pgid
	hook_pgid="$(ps -o pgid= -p "$hook_pid" | tr -d ' ')"
	kill -TERM "-$hook_pgid"

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

@test "AUTO-02: an allow-listed notification with auto mode on fires a detached pull" {
	stub_dir="$(mktemp -d)"
	fake_tty="$stub_dir/pane_tty"
	: >"$fake_tty"
	cat >"$stub_dir/tmux" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$stub_dir/calls.log"
case "\$1" in
show-options)
	[[ "\$*" == *"@vigil_auto"* ]] && printf 'on'
	;;
display-message)
	printf '%s' "$fake_tty"
	;;
esac
exit 0
STUB
	chmod +x "$stub_dir/tmux"
	cat >"$stub_dir/kitten" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
	chmod +x "$stub_dir/kitten"

	PATH="$stub_dir:$PATH" TMUX="stub,0,0" TMUX_PANE='%7' run vigil-hook-notification <"$BATS_TEST_DIRNAME/../fixtures/hooks/notification_idle_prompt.json"
	[ "$status" -eq 0 ]

	for i in 1 2 3 4 5 6 7 8 9 10; do
		[ -s "$fake_tty" ] && break
		sleep 0.2
	done
	[ -s "$fake_tty" ]
	# AUTO-02's second half (checker BLOCKER fix): vigil-kitty-focus
	# pull (Plan 06-01) also synchronously selects the FIFO head pane
	# in tmux -- confirm the stub recorded that switch-client call.
	grep -Fq 'switch-client -t %7' "$stub_dir/calls.log"

	rm -rf "$stub_dir"
}

@test "AUTO-02: a denied notification type never fires a pull, even with auto mode on" {
	stub_dir="$(mktemp -d)"
	fake_tty="$stub_dir/pane_tty"
	: >"$fake_tty"
	cat >"$stub_dir/tmux" <<STUB
#!/usr/bin/env bash
case "\$1" in
show-options)
	[[ "\$*" == *"@vigil_auto"* ]] && printf 'on'
	;;
display-message)
	printf '%s' "$fake_tty"
	;;
esac
exit 0
STUB
	chmod +x "$stub_dir/tmux"

	PATH="$stub_dir:$PATH" TMUX="stub,0,0" TMUX_PANE='%7' run vigil-hook-notification <"$BATS_TEST_DIRNAME/../fixtures/hooks/notification_auth_success.json"
	[ "$status" -eq 0 ]
	sleep 0.3
	[ ! -s "$fake_tty" ]

	rm -rf "$stub_dir"
}
