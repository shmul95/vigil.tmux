#!/usr/bin/env bats
# auto_toggle.bats — AUTO-01 coverage for scripts/vigil-auto-toggle:
# flips @vigil_auto to its opposite value by delegating to
# vigil-publish's own already-tested lock/refresh path, against a
# stub tmux binary (same multi-command-splitting stub convention
# as test/unit/publish.bats).

load '../test_helper'

setup() {
	setup_vigil_runtime

	TMUX_STUB_DIR="$(mktemp -d)"
	export TMUX_STUB_LOG="$TMUX_STUB_DIR/calls.log"
	mkdir -p "$TMUX_STUB_DIR/bin"

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
				if [[ "$opt" == "@vigil_auto" ]]; then
					printf '%s' "${TMUX_STUB_AUTO:-}"
				fi
				;;
			list-clients)
				printf 'client-0\n'
				;;
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

@test "AUTO-01: toggling from off (unset) flips to on" {
	TMUX_STUB_AUTO='' run vigil-auto-toggle
	[ "$status" -eq 0 ]
	grep -Fxq 'set-option -g @vigil_auto on' "$TMUX_STUB_LOG"
	grep -Fxq 'set-option -g @vigil_status #[fg=white]0 Vigil #[fg=green]●#[default]' "$TMUX_STUB_LOG"
}

@test "AUTO-01: toggling from on flips to off" {
	TMUX_STUB_AUTO='on' run vigil-auto-toggle
	[ "$status" -eq 0 ]
	grep -Fxq 'set-option -g @vigil_auto off' "$TMUX_STUB_LOG"
	grep -Fxq 'set-option -g @vigil_status #[fg=white]0 Vigil #[fg=red]●#[default]' "$TMUX_STUB_LOG"
}

@test "AUTO-01: refreshes every attached client after toggling" {
	TMUX_STUB_AUTO='off' run vigil-auto-toggle
	[ "$status" -eq 0 ]
	grep -Fxq 'refresh-client -S -t client-0' "$TMUX_STUB_LOG"
}

@test "AUTO-01: outside tmux is a silent no-op" {
	unset TMUX
	run vigil-auto-toggle
	[ "$status" -eq 0 ]
	[ ! -e "$TMUX_STUB_LOG" ]
}
