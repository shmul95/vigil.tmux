# Vigil task cron — schedule registration (systemd user timer)

**This timer is NOT applied automatically by Vigil.** Nothing in this
repository writes unit files, edits a crontab, or invokes `systemctl`.
`scripts/vigil-task-cron` never registers its own schedule (CRON-02).
Registering the schedule below is a separate, explicitly-confirmed human
step — the same gate category as the `~/.claude/settings.json` hook
deployment documented in `docs/claude-code-settings.md`.

## What the script does

`scripts/vigil-task-cron` takes no arguments. Each run:

1. runs `vigil-task-reader` to list open task notes (one absolute path
   per line on stdout),
2. checks each task with `vigil-task-done-check` for a merged PR,
3. spawns a tmux window + Claude Code session for every task that is not
   already done and not already running (`vigil-task-spawn`),
4. prints every sub-script outcome line verbatim, then exactly one
   summary line:

   ```
   vigil-task-cron: N tasks found, S spawned, R already running, D done (PR merged), E errors
   ```

It always exits 0 (fail-open): a degraded run is reported in the summary
rather than stopping the schedule. Malformed task notes are warned about
on stderr and skipped; they are not counted as errors. A task whose
merged PR is found is never respawned, and its stale tmux window (if any)
is left alone — Vigil never kills windows.

The script is idempotent: tmux window-name existence is the only liveness
signal, so repeated runs never spawn the same task twice. A missed run is
therefore safe to catch up.

## Cadence

Every 15 minutes on the wall clock. `OnCalendar=*:0/15` (rather than the
monotonic `OnUnitActiveSec=15min`) stays aligned to :00/:15/:30/:45 and,
with `Persistent=true`, catches up one missed run after downtime.

## Hard prerequisites

All of these must resolve on the scheduler's PATH:

| Binary | Why |
|--------|-----|
| `bash` | runs `vigil-task-cron` and every sub-script |
| `tmux` | liveness check and window creation (default socket; the `eip` session) |
| `gh` | merged-PR lookup, authenticated to the `EIP-memtide` org |
| `jq` | required by `vigil-task-done-check` to extract the PR number/URL |
| `claude` | launched inside each spawned window (or set `VIGIL_CLAUDE_BIN` to an absolute path) |

**`jq` matters:** the systemd user manager's PATH is much shorter than an
interactive shell's. If `jq` is missing, `vigil-task-cron` prints
`vigil-task-cron: warning: jq not found -- completion detection disabled`
to stderr and counts one error, then keeps spawning. Completion detection
then degrades to "not done" for every task, so already-merged tasks could
be respawned. Install `jq` into your user profile (for example
`nix profile install nixpkgs#jq`) or add its directory to
`Environment=PATH`.

Also confirm `VIGIL_TASKS_DIR` exists. The reader's built-in default path
may not exist on every machine; set it explicitly in the service unit if
needed (the default vault path is typically absent until the producer is
registered).

## Unit files (NOT applied automatically)

Write these two files by hand. `%h` expands to your home directory.

`~/.config/systemd/user/vigil-task-cron.service`:

```ini
[Unit]
Description=Vigil task cron: read open memtide tasks and spawn sessions

[Service]
Type=oneshot
# The systemd user manager's PATH is shorter than an interactive shell's.
# Include every directory your binaries live in; jq MUST be resolvable.
Environment=PATH=%h/.nix-profile/bin:/run/current-system/sw/bin
ExecStart=%h/Repositories/vigil/scripts/vigil-task-cron
# Optional overrides:
# Environment=VIGIL_TASKS_DIR=/abs/path/to/memtide/Tasks/samuel
# Environment=VIGIL_CLAUDE_BIN=%h/.local/bin/claude
```

`~/.config/systemd/user/vigil-task-cron.timer`:

```ini
[Unit]
Description=Run vigil-task-cron every 15 minutes

[Timer]
OnCalendar=*:0/15
Persistent=true
Unit=vigil-task-cron.service

[Install]
WantedBy=timers.target
```

## Enable (human step)

```bash
mkdir -p ~/.config/systemd/user
# write the two unit files above, then:
systemctl --user daemon-reload
systemctl --user enable --now vigil-task-cron.timer
systemctl --user list-timers vigil-task-cron.timer   # verify the next elapse
systemctl --user start vigil-task-cron.service       # optional one-shot
journalctl --user -u vigil-task-cron -f              # watch per-run output

# Optional: keep the timer running after logout
loginctl enable-linger "$USER"
```

## Checking that it is working

- `systemctl --user list-timers vigil-task-cron.timer` shows the next run.
- `journalctl --user -u vigil-task-cron` shows every run's summary line.
- If every run reports `0 tasks found`, either the vault is genuinely
  empty or `VIGIL_TASKS_DIR` is wrong (see prerequisites above).
- A `warning: jq not found` line means completion detection is disabled
  until `jq` is added to the unit's PATH.

## crontab alternative (not recommended on this host)

`cron` has an even shorter PATH and no built-in catch-up after downtime.
If used, redirect both streams:

```cron
*/15 * * * * /home/you/Repositories/vigil/scripts/vigil-task-cron >>/home/you/.local/state/vigil-task-cron.log 2>&1
```
