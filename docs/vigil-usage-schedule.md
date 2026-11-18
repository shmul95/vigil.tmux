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

**Notes**
- Subscriber-only: the `rate_limits` object appears after the first API
  response and only for Pro/Max/Ultra plans. No object → no Claude entry,
  and the segment simply omits Claude.
- Claude Code drops each window after it resets; the wrapper stores the
  missing window as `null`, and the segment renders `–` rather than a
  stale number.
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
