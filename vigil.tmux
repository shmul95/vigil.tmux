#!/usr/bin/env bash
# vigil.tmux — TPM entry point. TPM executes this file at plugin load, so it
# must be safe to run repeatedly. It never replaces the user's status-right
# and never resolves runtime paths (D-04): it only seeds options and appends
# the published-status marker.
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091 # dynamic, self-locating path; not statically resolvable
source "$CURRENT_DIR/scripts/lib/vigil-common.sh"

if ! command -v tmux >/dev/null 2>&1 || [[ -z "${TMUX:-}" ]]; then
	exit 0
fi

auto="$(tmux show-options -gv @vigil_auto 2>/dev/null || true)"
if [[ -z "$auto" ]]; then
	auto="off"
	tmux set-option -g @vigil_auto "$auto"
fi

count="$(tmux show-options -gv @vigil_queue_count 2>/dev/null || true)"
if [[ -z "$count" ]]; then
	count="0"
	tmux set-option -g @vigil_queue_count "$count"
fi

status="$(tmux show-options -gv @vigil_status 2>/dev/null || true)"
if [[ -z "$status" ]]; then
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	[[ "$auto" == "on" ]] || auto=off
	status="$(vigil_render_status "$count" "$auto")"
	tmux set-option -g @vigil_status "$status"
fi

# Append the segment exactly once; never replace the user's status-right (D-02).
current="$(tmux show-options -gv status-right 2>/dev/null || true)"
case "$current" in
*'#{@vigil_status}'*) ;;
*)
	if [[ -n "$current" ]]; then
		tmux set-option -g status-right "$current #{@vigil_status}"
	else
		tmux set-option -g status-right '#{@vigil_status}'
	fi
	;;
esac
