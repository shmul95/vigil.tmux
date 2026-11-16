#!/usr/bin/env bash
# vigil-hook-common.sh — shared helpers for Vigil's Claude Code hook
# client scripts (vigil-hook-stop, vigil-hook-notification,
# vigil-hook-userpromptsubmit). Sourced only, never executed directly —
# mirrors vigil-common.sh's convention of no top-level `set -e`/`set -u`
# so sourcing this never mutates the caller's shell options.

# vigil_hook_pane_id — echoes $TMUX_PANE captured at hook invocation
# time. Never queries tmux for "the current pane" (Pitfall 9 /
# CONTEXT.md Pane Identity decision): $TMUX_PANE is inherited from the
# pane's own shell by the agent CLI process tree, so it always
# identifies the pane that actually fired this hook, even if the user
# has since navigated elsewhere. Returns 1 and echoes nothing if unset
# — callers MUST fail closed (no-op), never fall back to a tmux query.
vigil_hook_pane_id() {
	if [[ -z "${TMUX_PANE:-}" ]]; then
		return 1
	fi
	printf '%s' "$TMUX_PANE"
}

# vigil_hook_read_stdin — echoes the full stdin payload. Hook scripts
# must call this exactly once (stdin can only be consumed once) and
# pass the captured string to vigil_hook_jq_field for every field read.
vigil_hook_read_stdin() {
	cat
}

# vigil_hook_jq_field <json> <field> <default>
#
# Defensive single-field extraction: echoes <default> instead of
# aborting on a missing field, an explicit null, OR fully malformed
# JSON (jq parse failure) — this is what lets hook parsing survive
# Claude Code's actively-evolving hook schema (STACK.md already caught
# one field-name correction: `prompt` not `prompt_text`) without
# crashing before the hook script's own fail-open trap even matters.
# <field> is always a fixed literal supplied by our own call sites
# (e.g. "notification_type"), never attacker/payload-controlled, so
# interpolating it into the jq program text is safe; <default> is
# passed via --arg (never interpolated into the program text) since
# callers may someday pass a caller-supplied string there too.
vigil_hook_jq_field() {
	local json="$1" field="$2" default="${3:-}"
	local value
	if ! value="$(jq -r --arg d "$default" ".${field} // \$d" <<<"$json" 2>/dev/null)"; then
		value="$default"
	fi
	printf '%s' "$value"
}

# vigil_hook_debug <message> — one-line stderr trace, silent unless
# VIGIL_DEBUG is set to any non-empty value (CONTEXT.md: "silent by
# default"). Never writes to a file — stderr only, scoped to this
# single invocation.
vigil_hook_debug() {
	if [[ -n "${VIGIL_DEBUG:-}" ]]; then
		echo "${0##*/}: $*" >&2
	fi
}
