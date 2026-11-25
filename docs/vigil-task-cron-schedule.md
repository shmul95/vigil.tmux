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

## Spawned windows

Each spawned window runs `claude --permission-mode auto "/thinking-partner
<task content>"`. The flag is explicit rather than relying on
`~/.claude/settings.json`'s `permissions.defaultMode`, because a
cron-spawned window resolves whichever `claude` the systemd user manager's
PATH finds first — which can be a different Claude Code build than the
interactive shell's — and nobody is attached to Shift+Tab the session by
hand. Pin the intended binary with `VIGIL_CLAUDE_BIN` (see below).

The prompt (the task note's body, or the linked PR's review/comment
content) is written to a temp file and read back by the window's own shell,
not passed in the tmux command string: tmux rejects command strings over
roughly 16 KiB (`command too long`), and PR-rendered prompts routinely
exceed that. The temp file is removed by the spawned shell immediately
after it is read.

`eip` always keeps one dedicated `vigil-home` shell window in addition to
the task windows. A tmux session dies with its last window, so without it,
quitting a spawned Claude (`/exit`, Ctrl-D) would close the task window,
destroy `eip`, and drop any attached client out of tmux. With the keeper
window, quitting a task closes only that task's window — the next sweep can
respawn it — while `eip` and the client survive. `vigil-home` is never
matched by the `vigil-task-<id>` dedup check.

## Cadence

Once a day at 8am on the wall clock. `OnCalendar=*-*-* 08:00:00` (rather
than the monotonic `OnUnitActiveSec=1d`) stays pinned to 08:00 regardless
of when the timer was last enabled, and, with `Persistent=true`, catches
up one missed run (e.g. the machine was asleep at 8am) the next time the
user logs in.

## Manual runs — the `vigil` CLI

`scripts/vigil` is the manual control surface. It is installed as `vigil`
on PATH (the home-manager module does this):

```bash
vigil cron eip     # run the sweep now (the same script the timer runs)
vigil attach eip   # attach to the eip session (switch-client if already
                   # inside tmux); creates it with a vigil-home window if absent
vigil attach thu   # attach to any other tmux session by name
```

General form: `vigil <action> <workflow>`. The workflow is the tmux session
it owns. `thu` now also has a real cron: `vigil cron thu` triggers the
tsinghua-lms producer+consumer systemd units (`systemctl --user start
--wait`, in order, producer before consumer) rather than being implemented
in this script. Adding another workflow's cron means adding a branch to
`scripts/vigil`. `attach` rejects a session that does not exist unless
Vigil owns it.

## Hard prerequisites

All of these must resolve on the scheduler's PATH:

| Binary | Why |
|--------|-----|
| `bash` | runs `vigil-task-cron` and every sub-script |
| `tmux` | liveness check and window creation (default socket; the `eip` session) |
| `gh` | merged-PR lookup, authenticated to the `EIP-memtide` org |
| `jq` | required by `vigil-task-done-check` to extract the PR number/URL |
| `claude` | launched inside each spawned window; pin it with `VIGIL_CLAUDE_BIN` so the cron does not pick up a stale build that happens to come first on the scheduler's PATH |

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
# Pin the same Claude Code build the interactive shell uses. The system
# profile's claude can lag the wrapper in ~/.local/bin; without this the
# spawned session silently runs whichever one PATH finds first.
Environment=VIGIL_CLAUDE_BIN=%h/.local/bin/claude
ExecStart=%h/Repositories/vigil/scripts/vigil-task-cron
# Optional overrides:
# Environment=VIGIL_TASKS_DIR=/abs/path/to/memtide/Tasks/samuel
```

`~/.config/systemd/user/vigil-task-cron.timer`:

```ini
[Unit]
Description=Run vigil-task-cron daily at 8am

[Timer]
OnCalendar=*-*-* 08:00:00
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
- `vigil cron eip` runs the same sweep on demand and prints its summary;
  `vigil attach eip` jumps straight to the spawned sessions.
- If every run reports `0 tasks found`, either the vault is genuinely
  empty or `VIGIL_TASKS_DIR` is wrong (see prerequisites above).
- A `warning: jq not found` line means completion detection is disabled
  until `jq` is added to the unit's PATH.

## crontab alternative (not recommended on this host)

`cron` has an even shorter PATH and no built-in catch-up after downtime.
If used, redirect both streams:

```cron
0 8 * * * /home/you/Repositories/vigil/scripts/vigil-task-cron >>/home/you/.local/state/vigil-task-cron.log 2>&1
```
