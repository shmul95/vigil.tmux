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
#
# WR-03: unlike the @vigil_* user options above (which have no value at
# all until first seeded -- show-options legitimately fails with "exit
# 1" on EVERY first load, so failure there is the expected signal to
# seed a default, not an anomaly), status-right is a built-in tmux
# option that always has a value (tmux's own default if the user never
# set one), so show-options on it succeeds in every normal case,
# including an explicitly empty string. A failed read here is therefore
# unambiguous and must not be conflated with "empty": `2>/dev/null` only
# discards the stderr text, the failure is still observable via the
# command's own exit status. If the read ever does fail (a tmux shim
# missing show-options, a transient server failure, a future option
# rename) while the following set-option still succeeds, treating the
# failure as "empty" would overwrite the user's real status-right with
# nothing but the Vigil marker -- exactly the data loss D-02 exists to
# prevent. Refuse to modify status-right at all rather than risk that.
if ! current="$(tmux show-options -gv status-right 2>/dev/null)"; then
	echo "vigil: unable to read status-right; leaving it unchanged" >&2
	exit 0
fi
# WR-02: tmux treats "##" as an escaped literal "#", so a status-right
# containing "##{@vigil_status}" (the user displaying that literal text,
# not referencing the option) must NOT be mistaken for an already-wired
# marker -- a plain substring search is fooled by it, leaving the plugin
# believing it has nothing to append. Replace every escaped "##" with a
# sentinel byte before searching so an escaped occurrence can never
# satisfy the unescaped pattern below. $current itself is left
# untouched so the append below still reproduces the user's literal text
# exactly.
haystack="${current//'##'/$'\x01'}"
case "$haystack" in
*'#{@vigil_status}'*) ;;
*)
	if [[ -n "$current" ]]; then
		tmux set-option -g status-right "$current #{@vigil_status}"
	else
		tmux set-option -g status-right '#{@vigil_status}'
	fi
	;;
esac

# CR-02: tmux's status-format[0] renders status-right through
# #{T;=/#{status-right-length}:status-right}, which keeps only the
# LEFTMOST status-right-length columns (default 40). Because the Vigil
# segment is appended at the END of status-right, it is the first thing
# cut whenever the user's existing segment already fills (or nearly
# fills) that budget -- so the marker can be wired correctly above and
# still never render. Verify the marker actually survives that
# truncation and, if not, widen the limit just enough to fit it.
# "Vigil" is the one literal substring vigil_render_status() always
# emits (in both auto states), so it is a stable rendering witness
# independent of the live count.
rendered="$(tmux display-message -p '#{T;=/#{status-right-length}:status-right}' 2>/dev/null || true)"
if [[ "$rendered" != *'Vigil'* ]]; then
	right_len="$(tmux show-options -gv status-right-length 2>/dev/null || true)"
	[[ "$right_len" =~ ^[0-9]+$ ]] || right_len=40
	tmux set-option -g status-right-length "$((right_len + 24))"
fi
