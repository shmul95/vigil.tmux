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

# NAV-01/NAV-02/NAV-03: Alt+v jump-or-rotate, no prefix key needed
# (05-CONTEXT.md: "Key binding: bind-key -n M-v"). bind-key is
# naturally idempotent -- re-binding the same key on every plugin
# (re)load simply overwrites to the identical command, unlike
# status-right's append-once logic below, so no extra guard is
# needed here.
#
# 05-REVIEW.md WR-05: warn (to stderr) whenever M-v was already bound
# to something before this line overwrites it, so a pre-existing
# tmux.conf binding -- or losing a program's own M-v keystroke
# server-wide (e.g. Emacs's default "scroll up a page") -- is at
# least observable instead of silently shadowed. This can only warn,
# not fully distinguish the two cases: idempotent reload means
# Vigil's own prior registration from an earlier plugin load looks,
# from this check's perspective, identical to a user's pre-existing
# binding. Documented as a known, accepted tradeoff rather than
# overengineered further.
if tmux list-keys -T root 2>/dev/null | grep -q -- ' M-v '; then
	echo "vigil: overwriting an existing M-v binding" >&2
fi
tmux bind-key -n M-v run-shell -b "$CURRENT_DIR/scripts/vigil-advance"

# QUEUE-03 fast path: prune immediately whenever any pane's own
# process exits normally. Does NOT fire for
# kill-pane/kill-session/kill-server (PITFALLS.md Pitfall 6) --
# vigil-advance's own lazy prune-on-read is the backstop for those
# (05-CONTEXT.md's two-layer design). set-hook without -a replaces
# the single action already registered for this hook name rather
# than appending another copy, so this is also safe to call on
# every plugin (re)load.
#
# 05-REVIEW.md CR-01 (reopened WR-06): the embedded '...' span below
# passes through TWO independent re-parses -- tmux's own parser when
# it resolves the stored hook action, then run-shell's internal
# `sh -c` on the resulting argument -- and a single round of
# '->'\'' escaping only protects the first. Verified empirically
# (including against the 'fixed' double-escaping attempted in the
# first review-fix pass, which was itself still broken) that no
# single string transformation survives both layers correctly for
# every path. Rather than risk a second silent escaping bug, refuse
# to register the fast-path hook at all when the install path
# contains a literal single quote -- vigil-advance's lazy
# prune-on-read backstop still fully covers QUEUE-03 in that case,
# just without the fast path's immediate reaction.
#
# IN-01: this guard checks only for a literal single quote, the one
# metacharacter actually exercised by this code's two-layer
# re-parse. A literal newline in the install path (permitted on
# Linux filesystems) carries the same category of risk and is not
# checked -- accepted as out of scope: an install path containing a
# raw newline byte is a vanishingly unlikely, self-inflicted
# scenario for a personal tmux plugin, not worth a broader
# metacharacter-sweeping guard.
if [[ "$CURRENT_DIR" == *"'"* ]]; then
	echo "vigil: install path contains a single quote; skipping the pane-exited fast-path hook (QUEUE-03's backstop still applies)" >&2
else
	tmux set-hook -g pane-exited "run-shell -b '${CURRENT_DIR}/scripts/vigil-prune'"
fi

# Sanitize @vigil_auto to exactly "on"/"off" and rewrite the option only
# when the sanitized value actually differs from what was read (covers
# both "unset" and an invalid pre-existing value, e.g. a bogus manual
# `tmux set-option -g @vigil_auto garbage`) -- WR-06, part 2: downstream
# consumers of the documented option contract must never see anything
# but "on" or "off".
raw_auto="$(tmux show-options -gv @vigil_auto 2>/dev/null || true)"
auto="$raw_auto"
[[ "$auto" == "on" ]] || auto="off"
if [[ "$auto" != "$raw_auto" ]]; then
	tmux set-option -g @vigil_auto "$auto"
fi

# WR-06, part 1: a fresh tmux server (restart/crash) has no @vigil_*
# options, but queue.json persists across that restart (it's keyed by
# socket path). Fabricating 0 here regardless would report an incorrect
# count until the next mutation. Derive the seeded value from the
# ACTUAL persisted queue instead -- vigil_read_queue_count is read-only
# (never creates the runtime dir), so the "first load seeds without
# resolving the runtime dir" contract still holds for a genuinely fresh
# runtime dir. Also repairs a non-numeric pre-existing value the same
# way @vigil_auto is sanitized above.
raw_count="$(tmux show-options -gv @vigil_queue_count 2>/dev/null || true)"
count="$raw_count"
if ! [[ "$count" =~ ^[0-9]+$ ]]; then
	count="$(vigil_read_queue_count)"
fi
if [[ "$count" != "$raw_count" ]]; then
	tmux set-option -g @vigil_queue_count "$count"
fi

# WR-03: re-render and rewrite @vigil_status whenever EITHER count or
# auto was just repaired above (not only when @vigil_status itself is
# empty). A genuine server restart clears all three @vigil_* options
# together, which the empty-status check alone already covers, but a
# user can independently clear/corrupt just @vigil_queue_count or
# @vigil_auto (e.g. a manual `tmux set-option -gu @vigil_queue_count`)
# while leaving @vigil_status untouched -- the WR-06 repair above fixes
# count/auto in that case, but without this check the stale rendered
# @vigil_status string would disagree with the just-repaired values
# until the next real mutation republishes all three together.
status_dirty=0
[[ "$count" != "$raw_count" ]] && status_dirty=1
[[ "$auto" != "$raw_auto" ]] && status_dirty=1
status="$(tmux show-options -gv @vigil_status 2>/dev/null || true)"
if [[ -z "$status" || "$status_dirty" -eq 1 ]]; then
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
#
# IN-01: 0x01 is assumed never to occur literally in the user's
# status-right. tmux options are arbitrary byte strings, so a status
# line that legitimately contains a raw 0x01 byte could in theory
# collide with a sentinel inserted elsewhere in the same string and
# produce a false match -- vanishingly unlikely for a terminal status
# line, and not worth a structural fix (e.g. a longer/rarer
# private-use-area sentinel) given the likelihood.
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
#
# WR-01: a substring search for the literal text "Vigil" in the
# truncated render is ambiguous -- it can false-negative if the user's
# OWN (untruncated) segment happens to contain that word somewhere
# before the real marker, making this check conclude the marker
# rendered fine when it was actually the cut-off text. Measure instead:
# render status-right with a deliberately huge truncation bound (9999,
# far beyond any realistic terminal width) to get its TRUE, fully
# expanded length with no truncation applied, and compare that length
# directly against the configured status-right-length. Because the
# Vigil marker is always appended LAST (D-02) and tmux's #{T;=/N:...}
# truncation always keeps the LEFTMOST N columns (cutting from the
# right), the marker is guaranteed to render in full whenever the full
# expansion's length fits within status-right-length -- no substring
# matching required, so no coincidental-substring false negative is
# possible.
#
# WR-02: vigil.tmux is a TPM entrypoint that runs exactly once per
# server start / plugin (re)install -- nothing re-invokes it
# automatically. A fixed "+24" increment only converges if the user
# happens to reload the plugin enough additional times to accumulate
# enough budget, which nothing prompts them to do. Set
# status-right-length to the EXACT length required in one shot instead
# of an arbitrary increment, so this always converges in the single
# pass vigil.tmux actually gets.
full_rendered="$(tmux display-message -p '#{T;=/9999:status-right}' 2>/dev/null || true)"
right_len="$(tmux show-options -gv status-right-length 2>/dev/null || true)"
[[ "$right_len" =~ ^[0-9]+$ ]] || right_len=40
if ((${#full_rendered} > right_len)); then
	tmux set-option -g status-right-length "${#full_rendered}"
fi
