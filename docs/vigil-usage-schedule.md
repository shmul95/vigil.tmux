# Provider usage segment — refresh timer and statusline wrap

**NOT applied automatically.** Nothing in this repository writes to your
systemd user units or to `~/.claude/settings.json`. Both steps below are
manual, and both change machine-global, user-scoped state — apply them
deliberately.

The usage segment itself needs neither step to exist; it simply renders
nothing until the cache has data.

---

## What each piece does

| Piece | Purpose | Needs |
|---|---|---|
| `scripts/vigil-usage-refresh` | Fetches DeepSeek balance into the cache | `curl`, `jq`, `DEEPSEEK_API_KEY` |
| `scripts/vigil-statusline-capture` | Caches Claude's documented `rate_limits` from statusline stdin, then passes the statusline through unchanged | `jq` |
| `vigil_usage_segment` (in `scripts/lib/vigil-common.sh`) | Renders the cache into `@vigil_status` | `jq` |

Cache path: `$XDG_RUNTIME_DIR/vigil-usage-<uid>.json` (override with
`VIGIL_USAGE_CACHE`). It is deliberately **not** tmux-socket-scoped, so the
timer (no `$TMUX`) and the in-tmux renderer agree on one file.

---

## Step 1 — 15-minute refresh timer (DeepSeek)

Create `~/.config/systemd/user/vigil-usage-refresh.service`:

```ini
[Unit]
Description=Vigil provider usage refresh
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=%h/.config/vigil/usage.env
ExecStart=%h/Repositories/vigil/scripts/vigil-usage-refresh
```

Create `~/.config/systemd/user/vigil-usage-refresh.timer`:

```ini
[Unit]
Description=Vigil provider usage refresh every 15 minutes

[Timer]
OnCalendar=*:0/15
Persistent=true

[Install]
WantedBy=timers.target
```

`~/.config/vigil/usage.env` (chmod 600) holds the secret:

```
DEEPSEEK_API_KEY=sk-...
```

### If the key already lives in agenix (e.g. the `deepcode` env file)

Don't copy the raw key. Point the unit at the same decrypted file and map
the variable at runtime:

```ini
EnvironmentFile=%t/agenix/deepcode-env
ExecStart=/bin/sh -c 'DEEPSEEK_API_KEY="$ANTHROPIC_API_KEY" exec %h/Repositories/vigil/scripts/vigil-usage-refresh'
```

(`%t` is the per-user runtime dir; agenix keeps the file 0600 there.)

Note the coupling: `ANTHROPIC_API_KEY` is only the DeepSeek key while
`deepcode` is DeepSeek-backed. If that ever changes, add an explicit
`DEEPSEEK_API_KEY=` line to the agenix secret source and use the plain
`EnvironmentFile` form instead.

One-off run without writing anything:

```bash
set -a; . "${XDG_RUNTIME_DIR}/agenix/deepcode-env"; set +a
DEEPSEEK_API_KEY="$ANTHROPIC_API_KEY" /path/to/scripts/vigil-usage-refresh
```

Enable:

```bash
systemctl --user daemon-reload
systemctl --user enable --now vigil-usage-refresh.timer
journalctl --user -u vigil-usage-refresh.service -f   # verify it runs
```

**Why `OnCalendar` not `OnUnitActiveSec`:** `OnCalendar=*:0/15` fires at
wall-clock quarter-hours and, with `Persistent=true`, catches up after
suspend/boot. `OnUnitActiveSec` is monotonic (pauses during suspend) and
does not catch up.

**Failure behavior:** the refresher exits 0 even on failure; the reason is
stored in the cache and the segment shows a `!` marker. Check
`journalctl --user -u vigil-usage-refresh` if the marker appears.

**Environment notes**
- Use a **systemd user** unit (as above), not a system unit: the cache path
  is `$XDG_RUNTIME_DIR/vigil-usage-<uid>.json`, and the user manager sets
  `XDG_RUNTIME_DIR` for you. A system/cron invocation without it would
  fall back to `/tmp` and write a different file than the in-tmux renderer
  reads.
- `curl`, `jq`, and `flock` (util-linux) must be on the unit's PATH.
  `systemctl --user show-environment` shows what it inherits; add
  `Environment=PATH=...` if your Nix profile tools are not visible there.
- After a successful refresh the script republishes `@vigil_status`
  best-effort by talking to the default tmux socket, so the balance moves
  without waiting for a queue event. If you run tmux on a non-default
  socket, the next queue change or `vigil-publish` will refresh it.

---

## Step 2 — Claude usage via the statusline wrapper

Claude Code's statusline receives a JSON document on stdin that includes
`rate_limits.five_hour.used_percentage` and
`rate_limits.seven_day.used_percentage` (documented at
<https://code.claude.com/docs/en/statusline>). The wrapper caches those
values, then runs your existing statusline command with the same input.

**It wraps — it does not replace.** Keep your current command as the
arguments.

Current command (example, from this machine's GSD setup):

```json
"statusLine": {
  "type": "command",
  "command": "\"/nix/store/.../node\" \"/home/shmul95/.claude/hooks/gsd-statusline.js\""
}
```

Change it to put the wrapper first:

```json
"statusLine": {
  "type": "command",
  "command": "/home/shmul95/Repositories/vigil/scripts/vigil-statusline-capture \"/nix/store/.../node\" \"/home/shmul95/.claude/hooks/gsd-statusline.js\""
}
```

This edits `~/.claude/settings.json`, which is global to every Claude Code
session on this machine. Make the edit by hand; do not have a script rewrite
that file.

**Rendering:** Claude shows as two dots, one per rate-limit window
(`five_hour`, `seven_day`) — `●` filled while under
`VIGIL_CLAUDE_EXHAUST_PCT` (default 90), `○` hollow at/over it, `◌` when
that window has no cached percentage. DeepSeek shows as a single dollar
figure — the API's own USD balance when present, else its CNY balance
converted at a fixed approximate rate (`VIGIL_DEEPSEEK_CNY_PER_USD`,
default 7.1 — a local estimate, not a live lookup) and prefixed with `≈`.
Both env vars are overridable; override `VIGIL_DEEPSEEK_CNY_PER_USD` if
the rate drifts enough to matter.

**Notes**
- Subscriber-only: the `rate_limits` object appears after the first API
  response and only for Pro/Max/Ultra plans. No object → no Claude entry,
  and the segment simply omits Claude.
- Claude Code drops each window after it resets; the wrapper stores the
  missing window as `null`, and the segment renders `◌` for that window
  rather than a stale dot. If the input has no `rate_limits` object at
  all (e.g. a non-subscriber plan), any previously cached Claude entry is
  dropped.
- A `~` marker prefixes either provider's text when its cache is older
  than 45 minutes.
- The status-right segment is variable-length. If your `status-right`
  is very long, the segment can be truncated by tmux's
  `status-right-length`; raise it in your tmux config if needed.
- The wrapper never refreshes tokens, never reads credential files, and
  makes no network calls.

---

## Verifying

```bash
# After enabling the timer and wrapping the statusline:
jq . "$XDG_RUNTIME_DIR/vigil-usage-<uid>.json"
# inside tmux, republish:
/home/shmul95/Repositories/vigil/scripts/vigil-publish
```

The segment appears in status-right after the next publish or queue change.

---

## Not included

- Mimo balance — no known public endpoint.
- Credential/OAuth management — out of scope by design.
- Auto-registration — both steps here are manual on purpose.
