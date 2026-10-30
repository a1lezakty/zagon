# Zagon

Zagon keeps track of your Claude Code and Codex CLI sessions: subscription limits, which sessions are working or
waiting for you, tokens and time per day and per project, history, summaries, your own task list with worklogs, and
handoff of a session's context to a new session or another AI. Everything is collected and kept on your machine.

There are two versions on one core:

- **Server (Linux)**: a single static binary without dependencies. It runs as a user service, keeps daily totals
  in SQLite, answers in the terminal, and answers Claude and Codex through MCP.
- **macOS app**: a menu bar item and a window. It reads the same data locally and from your servers over SSH.

The macOS app (in development, sample data): the menu bar, then the Day, Week and Calendar windows.

<p align="center"><img src="docs/images/main.png" width="320" alt="Menu bar: 5-hour and weekly limits with a forecast, sessions waiting for you, sessions working, today's totals"></p>

![Day: totals, timeline of sessions working and waiting for you, where usage went, what was done](docs/images/day.png)

![Week: session hours by day and project, weekly limit, projects of the week](docs/images/week.png)

![Calendar: hours per day of the month, the selected day, search across sessions](docs/images/calendar.png)

> **Status: early development, no releases yet.** The table below shows what already works in `main` and what
> is still on its way. Commands in this README are the ones the current `main` build has.

| Feature | State |
|---|---|
| Claude Code transcripts and Codex sessions: tokens, models, tools, projects, sub-agents | works |
| Session time and your own time per day, live status from hooks (working / waiting for you) | works |
| CLI reports: `today`, `day`, `week`, `sessions` | works |
| Background service (`zagon daemon`), install / uninstall / doctor | works |
| Limits from the Claude Code status line and Codex session files: MCP `limits`, Telegram `/limits`, alerts | works |
| MCP server for Claude Code and Codex (`zagon mcp`): reports and search | works |
| Notifications (Telegram, ntfy) and a Telegram bot | works |
| Daily "what was done" summary (`zagon summary`, sent in the evening) | works |
| Compressed archive of transcripts, kept after Claude Code deletes them (`zagon archive`) | works |
| Context handoff between sessions and tools | coming |
| Task list, worklog plan, Jira | coming |
| macOS app | not yet released |
| Install script, release binaries, Homebrew | not yet |

## Privacy

- Everything stays local and there is no telemetry. The only network requests are the notifications you configure
  (Telegram Bot API or ntfy, through `curl`).
- It reads only local files: Claude Code transcripts (`~/.claude/projects`), Codex session files and its thread index
  (`~/.codex/sessions`, `~/.codex/archived_sessions`, `~/.codex/state_*.sqlite`), plus what its own hooks and status
  line wrapper record.
- Limits come only from what Claude Code passes to its status line (`rate_limits`, Claude Code 2.1.80+ on Pro and
  Max) and from Codex's own session files. Zagon never reads or stores OAuth tokens, cookies or credential files,
  and it does not call any usage API. So it shows the 5-hour and weekly windows, and the last reading when no
  session is running.
- The database does not hold the text of your conversations. It holds numbers, times, project names, git branches
  and session titles: the ones Claude Code generates or you set, and Codex thread names (never your first prompt).
  Hooks record ids, paths, event names and numbers only, never prompts or tool input.
- The archive does keep text: compressed copies of the transcript files, in `~/.zagon/archive`, so your history
  outlives Claude Code's 30-day cleanup. Run the service with `zagon daemon --no-archive` to turn that off.
- The daily summary written by an AI is one call a day on your own subscription: `claude -p --safe-mode` on a cheap
  model (no CLAUDE.md, hooks, plugins or MCP servers of yours), or `codex exec --ephemeral --ignore-user-config`.
  It gets a compact digest: titles, projects, times, edited files, your commit subjects and the first words of the
  day's first typed messages. With `[summary] engine = "none"` the summary is built without AI.
- Your typed messages go into a contentless full-text index used for search: the words can be searched, the text
  itself is not kept. Pass `--no-index-prompts` to `zagon scan` / `zagon daemon` to turn that off.
- Data lives in `~/.zagon` (or `$ZAGON_DIR`): `zagon.db`, `spool/`, `archive/`, `logs/`, `config.toml`, `backup/`.

## Install on a Linux server

There are no releases yet. Take the `zagon-linux-x86_64` or `zagon-linux-aarch64` binary from the latest successful
`core` workflow run (Actions → artifacts), or [build from source](#build-from-source).

```sh
install -m 755 zagon-linux-x86_64 ~/.local/bin/zagon
zagon install --enable-service
zagon doctor
```

`zagon doctor` lists what is installed, shows the service log, and exits with 1 if something is missing. Then set up
[notifications](#notifications) if you want them.

What `zagon install` changes:

- **`~/.claude/settings.json`**:
  - hooks for `SessionStart`, `UserPromptSubmit`, `PermissionRequest`, `PostToolUse`, `Notification`, `Stop` and
    `SessionEnd`, each running `zagon hook claude <event>`;
  - the status line command becomes `zagon statusline`. Your previous command is saved in `~/.zagon/config.toml`
    (`[statusline] original_command`) and still runs with the same input, so your status line looks the same.
  - Opt out with `--no-claude` or `--no-statusline`.
- **`~/.codex/hooks.json`**, if `~/.codex` exists:
  - hooks for `SessionStart`, `UserPromptSubmit`, `PermissionRequest`, `PostToolUse`, `Stop`, `Interrupt` and
    `SessionEnd`;
  - open `/hooks` in Codex once to trust them;
  - opt out with `--no-codex`.
- **MCP registration** (default `--mcp`): runs `claude mcp add --scope user zagon -- zagon mcp` and
  `codex mcp add zagon -- zagon mcp`. The second one writes `[mcp_servers.zagon]` into `~/.codex/config.toml`.
- **systemd units**:
  - `~/.config/systemd/user/zagon.service`, running `zagon daemon`;
  - `--enable-service` enables and starts it;
  - on a host without a user systemd, run `sudo zagon install --system-service --enable-service`. That writes
    `/etc/systemd/system/zagon-<user>.service` running as you: under sudo, install works for the user who ran sudo
    (or `--user <name>`), writes the files in that user's home as that user, and leaves the MCP registration to a
    plain `zagon install`.
- `--bin <path>` sets the binary that hooks, the status line and the service run (an absolute path to an
  executable; default: the running binary).

Before changing a file, `install` copies it to `~/.zagon/backup/<time>/`. Running `install` again changes nothing
that is already in place. Unknown keys and the formatting of your JSON files are kept.

**Undo**: `zagon uninstall`.

- It removes the hooks, the status line wrapper, the MCP registrations and the systemd units.
- A file you have not touched since install is restored from the backup byte for byte. In a file you changed since,
  only Zagon's entries are removed.
- The database in `~/.zagon` stays. Delete that directory yourself if you want it gone.

## Use

```sh
zagon today                    # tokens, session time, your time, models, projects, tools, top sessions
zagon day 2026-10-29           # any day
zagon week --end 2026-10-29    # seven days vs the seven before
zagon sessions --limit 10      # recent sessions; --day YYYY-MM-DD for one day
zagon scan                     # read new data once (reports do this anyway unless --no-scan)
zagon summary 2026-10-29       # what was done that day; --engine claude|codex|none, --png ribbon.png, --send
zagon archive stats            # archived sessions, bytes before / after compression
zagon archive cat <session>    # print an archived transcript (id or a unique prefix)
zagon notify test              # a test message to every configured channel
zagon tz Asia/Almaty           # the zone days are cut in (no argument: show it; `system` = the machine's)
zagon daemon --verbose         # what the service runs: follow files, keep totals current, notify, archive
zagon export --since 0         # changed totals as NDJSON, read by the macOS app over SSH
```

- Every report takes `--json`.
- Common options:
  - `--data-dir` (default `$ZAGON_DIR` or `~/.zagon`);
  - `--claude-dir` (default `~/.claude/projects`);
  - `--codex-dir` (default `$CODEX_HOME` or `~/.codex`);
  - `--idle-gap` minutes: your actions closer than this count as one stretch of work (default 20);
  - `--session-gap` minutes: agent silence that ends a working interval (default 30).

## MCP

`zagon mcp` serves the Zagon data to Claude Code, Codex and other MCP clients over stdio. Register it with:

```sh
claude mcp add --scope user zagon -- zagon mcp
codex mcp add zagon -- zagon mcp
```

`zagon install` does the same.

Tools that work now: `limits`, `sessions`, `day`, `week`, `range`, `search`, `export_day`. Answers are short and
carry numbers; a long one, such as a day exported to Markdown, goes to a file in `~/.zagon/exports`.

Coming: these are already listed, and until their packages land they answer "not available in this build":
- handoff: `handoff_create`, `handoff_get`, `handoff_list`, and the prompt `/mcp__zagon__resume <id|latest>`;
- tasks: `task_list`, `task_get`, `task_create`, `task_update`;
- worklogs: `worklog_plan`, `worklog_commit` (needs `confirm: true` and is meant only for an explicit request).

## Notifications

The service sends alerts through your own Telegram bot or an [ntfy](https://ntfy.sh) topic:
- a limit at 80 % and 95 % (5-hour and weekly, Claude and Codex), and a limit reset;
- a session waiting for you longer than 10 minutes (unless "finished" was already sent for that stop);
- a turn that worked longer than 15 minutes has finished, and its sub-agents and background commands too;
- the day summary at 20:00, with a picture of the day.

Nothing is sent during quiet hours (23:00–08:00). Keep notifications on one host only. Every key in
`~/.zagon/config.toml` is optional; the main ones with their defaults:

```toml
timezone = ""               # e.g. "Europe/Berlin"; empty = system zone. Days are cut at this zone's midnight.
                            # Also `zagon tz <zone>`, Telegram `/tz <zone>`, MCP `settings_timezone`.

[notify]
enabled = true              # this host sends notifications
limit_reset = true
waiting_minutes = 10        # 0 = off
long_work_minutes = 15      # 0 = off
summary_at = "20:00"        # "" = off
quiet = "23:00-08:00"       # "" = off
lang = "auto"               # auto | ru | en: notifications, bot replies, day summary; auto = the system language

[notify.limits]             # thresholds, 50...100 in steps of 5; [] = off
claude.five_hour = [80, 95]
claude.week = [80, 95]
codex.five_hour = [80, 95]
codex.week = [80, 95]

[telegram]
token_file = "~/.config/zagon/tg-bot-token"   # your bot's token from @BotFather, in a file only you can read
chat_id = "123456789"       # the only chat the bot writes to and answers
commands = true             # answer /limits /sessions /today /week /day /tz (one host per bot)

[ntfy]
topic = ""                  # set a topic to turn ntfy on
url = "https://ntfy.sh"

[summary]
engine = "claude"           # claude | codex | none
model = "haiku"
timeout = 120               # seconds; on failure the summary is built without AI
```

Check with `zagon notify test`. The service reads the file when it starts, so restart it after a change.

## macOS app (not yet released)

The app will ship as a DMG with an ad-hoc signature, because there is no paid Apple developer account. macOS
blocks such an app on first launch:

1. Open the DMG and drag Zagon to Applications.
2. Open it once. macOS says it cannot verify the developer.
3. Go to System Settings → Privacy & Security and click **Open Anyway** next to the Zagon message. On macOS 15 and
   later, right-click → Open no longer bypasses this.

It needs macOS 13 or later. It will add servers from `~/.ssh/config`, and each server needs the server version
installed.

## Build from source

You need Swift 6.4.1. On Linux the `swift:6.4.1-bookworm` Docker image works, so nothing goes on the host. On macOS
you need macOS 13 or later.

```sh
swift build -c release            # .build/release/zagon
TZ=UTC swift test                 # the tests expect to start in UTC, as CI does
```

Static Linux binary, with the Static Linux SDK 6.4.1:

```sh
swift sdk install https://download.swift.org/swift-6.4.1-release/static-sdk/swift-6.4.1-RELEASE/swift-6.4.1-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz \
  --checksum cef5592d7430ed3c5ae1ddda479849c6f5252bd94a5723db1559f984caf38a7c
swift build -c release --swift-sdk x86_64-swift-linux-musl -Xlinker -s   # or aarch64-swift-linux-musl
```

`scripts/dev.sh build|test|build-static` runs the same steps in a Docker container. CI (`.github/workflows/core.yml`)
does the following on every push:
- builds and tests;
- builds static x86_64 and aarch64 binaries and fails if one is over 20 MB;
- runs a smoke scan over the anonymized test fixtures.

Contracts between packages are in `docs/dev/contracts.md`.

## License

MIT, see [LICENSE](LICENSE).
