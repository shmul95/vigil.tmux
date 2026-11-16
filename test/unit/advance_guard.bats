#!/usr/bin/env bats
# advance_guard.bats — outside-tmux no-op guard coverage for
# vigil-advance and vigil-prune, plus a stub-tmux fault-injection
# proof for 05-REVIEW.md's CR-01 fix (IN-01: this scenario had no
# automated coverage). Both scripts otherwise genuinely require a
# real tmux server to exercise their actual navigation/prune
# behavior (see test/integration/advance.bats and prune.bats in
# 05-02) -- this file covers only the zero-tmux-dependency guard
# clause each script shares with vigil.tmux/vigil-publish, and the
# list-panes-failure case below, which is cheaper and more
# deterministic to fault-inject against a stub than a real server.

load '../test_helper'

@test "vigil-advance is a silent no-op outside tmux" {
	run env -u TMUX bash "$BATS_TEST_DIRNAME/../../scripts/vigil-advance"
	[ "$status" -eq 0 ]
	[ ! -e "${VIGIL_RUNTIME_DIR}/queue.json" ]
}

@test "vigil-prune is a silent no-op outside tmux" {
	run env -u TMUX bash "$BATS_TEST_DIRNAME/../../scripts/vigil-prune"
	[ "$status" -eq 0 ]
	[ ! -e "${VIGIL_RUNTIME_DIR}/queue.json" ]
}

@test "CR-01: a transient tmux list-panes failure never wipes a genuinely live queue" {
	# Stub tmux: list-panes always fails (simulating a transient
	# socket/server hiccup); everything else (display-message,
	# switch-client, show-options, etc.) succeeds harmlessly so the
	# rest of vigil-advance's flow can still run to completion.
	TMUX_STUB_DIR="$(mktemp -d)"
	mkdir -p "$TMUX_STUB_DIR/bin"
	cat >"$TMUX_STUB_DIR/bin/tmux" <<'STUB'
#!/usr/bin/env bash
case "$1" in
list-panes)
	echo "tmux: stubbed list-panes failure" >&2
	exit 1
	;;
display-message)
	# vigil-advance's own current-pane check and flash message both
	# call display-message; answer the pane_id query with a fixed,
	# never-equal-to-the-queued-head id so the script takes the
	# NAV-01 (jump, no mutation) branch rather than NAV-02 (rotate).
	echo "%not-the-head"
	exit 0
	;;
switch-client)
	exit 0
	;;
esac
exit 0
STUB
	chmod +x "$TMUX_STUB_DIR/bin/tmux"

	"$BATS_TEST_DIRNAME/../../scripts/vigil-queue" enqueue "%real-live-pane"
	[ "$(vigil-queue count)" = "1" ]

	PATH="$TMUX_STUB_DIR/bin:$PATH" TMUX="stub,0,0" \
		run bash "$BATS_TEST_DIRNAME/../../scripts/vigil-advance"
	[ "$status" -eq 0 ]

	# The queue entry must survive: prune must have been skipped for
	# this attempt, not treated as "list-panes succeeded with zero
	# panes" (which would have wiped it).
	[ "$(vigil-queue count)" = "1" ]
	[ "$(vigil-queue peek | jq -r '.pane_id')" = "%real-live-pane" ]

	rm -rf "$TMUX_STUB_DIR"
}

@test "CR-01 (WR-A): vigil-prune's identical list-panes-failure guard also never wipes a live queue" {
	# scripts/vigil-prune received the identical CR-01 fix as
	# vigil-advance in the same commit, but only vigil-advance's copy
	# had a regression test. Same fault-injection, targeting
	# vigil-prune directly (as the pane-exited hook action would).
	TMUX_STUB_DIR="$(mktemp -d)"
	mkdir -p "$TMUX_STUB_DIR/bin"
	cat >"$TMUX_STUB_DIR/bin/tmux" <<'STUB'
#!/usr/bin/env bash
case "$1" in
list-panes)
	echo "tmux: stubbed list-panes failure" >&2
	exit 1
	;;
esac
exit 0
STUB
	chmod +x "$TMUX_STUB_DIR/bin/tmux"

	"$BATS_TEST_DIRNAME/../../scripts/vigil-queue" enqueue "%real-live-pane-2"
	[ "$(vigil-queue count)" = "1" ]

	PATH="$TMUX_STUB_DIR/bin:$PATH" TMUX="stub,0,0" \
		run bash "$BATS_TEST_DIRNAME/../../scripts/vigil-prune"
	[ "$status" -eq 0 ]

	[ "$(vigil-queue count)" = "1" ]
	[ "$(vigil-queue peek | jq -r '.pane_id')" = "%real-live-pane-2" ]

	rm -rf "$TMUX_STUB_DIR"
}
