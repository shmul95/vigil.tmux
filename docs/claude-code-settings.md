# Claude Code `settings.json` hook registration

**This stanza is NOT applied automatically by Vigil.** Nothing in this
repository writes to `~/.claude/settings.json`. The user (or a later,
separately-confirmed step) must merge the JSON below into that file by
hand.

## Go/no-go: hook sharing across `claude`, `deepcode`, `mimocode`

Hook-sharing across all three CLIs is confirmed by **static proof**: the
installed `deepcode` and `mimocode` wrapper scripts were read directly and
are thin `set -euo pipefail` wrappers that validate/source an env file for
API credentials, then `exec` the identical `claude` binary as their final
statement, with no hook-related overrides anywhere in either wrapper (see
`PROJECT.md` Key Decisions table for the recorded outcome). This proves
hook sharing by construction — all three CLIs resolve the same
`~/.claude/settings.json` because they all end up running the same
process.

This go/no-go was **not** re-verified by a live three-CLI smoke test. That
live test is **deliberately deferred** until Phase 1's agenix secrets
exist for `deepcode`/`mimocode` (see `04-CONTEXT.md` Deferred Ideas). Do
not re-run or re-propose that live test here — it is out of scope for
this plan.

## The hook stanza

Replace `<VIGIL_REPO>` with the absolute path to this repository (the
directory containing `scripts/`) on the machine where the hooks will
actually run. Hook `command` entries **must** be absolute paths — Claude
Code invokes hook commands with the session's own `cwd`, which is not
this repo, so a relative path would resolve incorrectly or not at all.

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "<VIGIL_REPO>/scripts/vigil-hook-stop" }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "<VIGIL_REPO>/scripts/vigil-hook-notification" }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "<VIGIL_REPO>/scripts/vigil-hook-userpromptsubmit" }
        ]
      }
    ]
  }
}
```

For example, if this repo lives at `/home/shmul95/Repositories/vigil`,
the `Stop` hook's `command` becomes
`/home/shmul95/Repositories/vigil/scripts/vigil-hook-stop`.

## Why this covers all three CLIs for free

`~/.claude/settings.json` is a **global, user-scope** file, not
per-project and not per-CLI. Because `deepcode` and `mimocode` both
`exec` the identical `claude` binary (see Go/no-go above), all three
CLIs resolve and read this exact same settings file — registering the
stanza once wires hook delivery for `claude`, `deepcode`, and `mimocode`
simultaneously, with no per-CLI configuration needed.

## Merging into an existing `settings.json`

If `~/.claude/settings.json` already has a `hooks` key (e.g. other tools'
hooks, or hooks for other event types), **append** to the existing array
for each event (`Stop`, `Notification`, `UserPromptSubmit`) rather than
replacing the whole `hooks` key. Replacing it outright would silently
delete any pre-existing hook registrations for events not listed above.

## Why `matcher` is left empty

The `matcher` field above is intentionally left as `""` (fires for every
event of that type), **not** because `matcher` is structurally incapable
of filtering by subtype — per `FEATURES.md` (HIGH confidence), Claude
Code's hook system can match `Notification` events by `notification_type`
via `matcher` (e.g. `permission_prompt`, `idle_prompt`,
`agent_needs_input`, `agent_completed`).

It is left empty because of a locked implementation decision
(`04-CONTEXT.md`): the Notification allow-list (DETECT-02) and the
fail-open guarantee (DETECT-05) both live **inside**
`vigil-hook-notification` itself, as a hard-coded bash array, not in
`settings.json`'s `matcher` field. This keeps:

- a single source of truth for the allow-list logic (the script, not
  scattered across the script and the user's global config),
- defense-in-depth (filtering still applies even if a future
  `settings.json` edit drops or mis-types a `matcher`), and
- easy extension of the allow-list later without ever touching the
  user's global `settings.json` again.
