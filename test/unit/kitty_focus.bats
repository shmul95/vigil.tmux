#!/usr/bin/env bats
# kitty_focus.bats — AUTO-02/AUTO-04/FOCUS-01/FOCUS-02 coverage for
# scripts/vigil-kitty-focus, against stub tmux + stub kitten
# binaries (no real kitty process) plus one genuine throwaway
# unix-socket file (created via the REAL tmux binary, captured
# before any stub is prepended to PATH) so Tier 1's
# `[[ -S "$sock" ]]` glob-match check has something real to match.

load '../test_helper'

setup() {
	setup_vigil_runtime
	REAL_TMUX="$(command -v tmux)"

	FAKE_XDG="$(mktemp -d)"
	export XDG_RUNTIME_DIR="$FAKE_XDG"
	FAKE_SOCK="$FAKE_XDG/kitty-vigil-99999"
	"$REAL_TMUX" -S "$FAKE_SOCK" new-session -d -s fakekitty

	FAKE_PANE_TTY="$FAKE_XDG/pane_tty"
	: >"$FAKE_PANE_TTY"

	STUB_DIR="$(mktemp -d)"
	mkdir -p "$STUB_DIR/bin"
	export TMUX_STUB_LOG="$STUB_DIR/tmux_calls.log"
	export KITTEN_STUB_LOG="$STUB_DIR/kitten_calls.log"

	cat >"$STUB_DIR/bin/tmux" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMUX_STUB_LOG"
case "\$1" in
show-options)
	printf '%s' "\${TMUX_STUB_FOCUSED:-}"
	;;
display-message)
	printf '%s' "$FAKE_PANE_TTY"
	;;
esac
exit 0
STUB
	chmod +x "$STUB_DIR/bin/tmux"

	cat >"$STUB_DIR/bin/kitten" <<KITTENSTUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$KITTEN_STUB_LOG"
exit 0
KITTENSTUB
	chmod +x "$STUB_DIR/bin/kitten"

	export PATH="$STUB_DIR/bin:$PATH"
	export TMUX="stub,0,0"
}

teardown() {
	"$REAL_TMUX" -S "$FAKE_SOCK" kill-server 2>/dev/null || true
	unset TMUX
	rm -rf "${FAKE_XDG:-}" "${STUB_DIR:-}" "${VIGIL_RUNTIME_DIR:-}"
}

@test "vigil_valid_pane_id accepts tmux's own %N shape and rejects everything else" {
	source "$BATS_TEST_DIRNAME/../../scripts/lib/vigil-common.sh"
	run vigil_valid_pane_id '%7'
	[ "$status" -eq 0 ]
	run vigil_valid_pane_id '%0'
	[ "$status" -eq 0 ]
	run vigil_valid_pane_id '%123'
	[ "$status" -eq 0 ]
	run vigil_valid_pane_id 'rm -rf /'
	[ "$status" -eq 1 ]
	run vigil_valid_pane_id ''
	[ "$status" -eq 1 ]
	run vigil_valid_pane_id '7'
	[ "$status" -eq 1 ]
}

@test "rejects a malformed pane_id without touching tmux or kitten" {
	run vigil-kitty-focus pull 'rm -rf /'
	[ "$status" -eq 1 ]
	[[ "$output" == *"refusing malformed pane_id"* ]]
	[ ! -s "$TMUX_STUB_LOG" ]
	[ ! -s "$KITTEN_STUB_LOG" ]
}

@test "outside tmux is a silent no-op" {
	unset TMUX
	run vigil-kitty-focus pull '%7'
	[ "$status" -eq 0 ]
	[ ! -s "$KITTEN_STUB_LOG" ]
}

@test "AUTO-04: no kitten call, no switch-client, and no tty write when @vigil_kitty_focused is on" {
	TMUX_STUB_FOCUSED='on' run vigil-kitty-focus pull '%7'
	[ "$status" -eq 0 ]
	[ ! -s "$KITTEN_STUB_LOG" ]
	[ ! -s "$FAKE_PANE_TTY" ]
	! grep -q 'switch-client' "$TMUX_STUB_LOG"
}

@test "FOCUS-01: Tier 1 calls kitten focus-window against the discovered socket when unfocused" {
	TMUX_STUB_FOCUSED='off' run vigil-kitty-focus pull '%7'
	[ "$status" -eq 0 ]
	grep -Fq -- "--to unix:$FAKE_SOCK focus-window --match id:1 --no-response" "$KITTEN_STUB_LOG"
}

@test "AUTO-02: selects the FIFO head pane via tmux switch-client when unfocused" {
	TMUX_STUB_FOCUSED='off' run vigil-kitty-focus pull '%7'
	[ "$status" -eq 0 ]
	grep -Fq -- "switch-client -t %7" "$TMUX_STUB_LOG"
}

@test "FOCUS-01: an unset @vigil_kitty_focused is treated the same as off" {
	run vigil-kitty-focus pull '%7'
	[ "$status" -eq 0 ]
	[ -s "$KITTEN_STUB_LOG" ]
}

@test "FOCUS-02: Tier 2 writes the exact DCS-wrapped OSC 99 payload to the resolved pane_tty" {
	TMUX_STUB_FOCUSED='off' run vigil-kitty-focus pull '%7'
	[ "$status" -eq 0 ]

	esc=$'\x1b'
	payload="${esc}]99;i=vigil-%7;a=focus;Vigil: a session needs you${esc}\\"
	expected="${esc}Ptmux;${payload//$esc/$esc$esc}${esc}\\"
	[ "$(cat "$FAKE_PANE_TTY")" = "$expected" ]
}

@test "FOCUS-02: Tier 2 still fires even when Tier 1 finds no live socket" {
	rm -f "$FAKE_SOCK"
	TMUX_STUB_FOCUSED='off' run vigil-kitty-focus pull '%7'
	[ "$status" -eq 0 ]
	[ ! -s "$KITTEN_STUB_LOG" ]
	[ -s "$FAKE_PANE_TTY" ]
}

@test "unknown subcommand exits 1" {
	run vigil-kitty-focus bogus
	[ "$status" -eq 1 ]
	[[ "$output" == *"unknown subcommand"* ]]
}

@test "no subcommand exits 1" {
	run vigil-kitty-focus
	[ "$status" -eq 1 ]
}
