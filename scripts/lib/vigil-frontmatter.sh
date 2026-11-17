#!/usr/bin/env bash
# vigil-frontmatter.sh — dependency-free bash parser for Vigil's task-note
# frontmatter: flat "key: value" pairs between two bare "---" delimiter
# lines, no nested structures (07-RESEARCH.md: the schema this phase
# parses never needs anchors, multi-line block scalars, or nested maps).
# Meant to be `source`d (never executed directly) by scripts/vigil-task-
# reader and any later phase (8/9) that needs a task note's id/created/
# etc. fields. Does not `set -e`/`set -u` at the top level -- sourcing
# this must never mutate the caller's shell options (matches
# vigil-common.sh's own convention).

# vigil_frontmatter_parse <file>
#
# Parses <file>'s frontmatter block into the global associative array
# VIGIL_FM (re-initialized -- emptied -- on every call; callers must
# consume VIGIL_FM's contents before the next parse). Returns 0 only
# when the file starts with a bare "---" line, is readable throughout,
# and the block is explicitly closed by a second bare "---" line before
# EOF. Returns 1 on any parse failure -- missing opening/closing
# delimiter, unreadable file, or a non-blank/non-colon line inside the
# block -- callers cannot distinguish these failure modes from the
# return value alone, by design (07-RESEARCH.md Pitfall 4: all of them
# collapse to the caller's single generic "unparseable frontmatter"
# message).
#
# Values are never eval'd or used to construct shell syntax (ASVS V5):
# every field lands in VIGIL_FM via a plain string-indexed array
# assignment, so a frontmatter value can never be interpreted as code --
# task notes are written by an LLM-driven cron job reading arbitrary
# Discord message content, so every field value is untrusted input.
# This parser deliberately does NOT reject a value containing a literal
# tab or other control byte -- a tab inside a value is syntactically
# valid frontmatter content to this generic parser. Field-specific
# shape constraints (e.g. "id must be a 14-digit timestamp") are the
# caller's business rule, not this parser's -- see vigil-task-reader's
# own id-shape check (T-07-07) for why that distinction matters.
vigil_frontmatter_parse() {
	local file="$1"
	declare -gA VIGIL_FM=()
	local line lineno=0 closed=0 rc=0

	# 07-RESEARCH.md Pitfall 2: a bare `while ... done < "$file"`
	# followed by any unconditional statement silently swallows an
	# unreadable-file redirection failure. Wrapping the loop in a group
	# and capturing its exit status via `|| rc=$?` on the SAME
	# statement as `done < "$file"` is the verified fix; 2>/dev/null
	# also suppresses bash's own native "Permission denied" line so it
	# never leaks past this function's single-line error contract.
	{
		while IFS= read -r line || [[ -n "$line" ]]; do
			lineno=$((lineno + 1))
			line="${line%$'\r'}" # Pitfall 3: strip CRLF unconditionally

			if [[ $lineno -eq 1 ]]; then
				[[ "$line" == "---" ]] || return 1
				continue
			fi
			if [[ "$line" == "---" ]]; then
				closed=1
				break
			fi
			[[ -z "$line" ]] && continue
			[[ "$line" == *:* ]] || return 1

			local key="${line%%:*}" val="${line#*:}"
			key="${key#"${key%%[![:space:]]*}"}"
			key="${key%"${key##*[![:space:]]}"}"
			val="${val#"${val%%[![:space:]]*}"}"
			val="${val%"${val##*[![:space:]]}"}"
			if [[ "$val" =~ ^\".*\"$ ]] || [[ "$val" =~ ^\'.*\'$ ]]; then
				val="${val:1:-1}"
			fi
			# shellcheck disable=SC2034 # VIGIL_FM is the global output consumed by callers, not within this function
			VIGIL_FM["$key"]="$val"
		done <"$file"
	} 2>/dev/null || rc=$?

	[[ $rc -eq 0 ]] || return 1
	[[ $closed -eq 1 ]] || return 1
	return 0
}
