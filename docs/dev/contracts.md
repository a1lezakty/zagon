# Contracts between packages

Stable types other packages build on. Changing a field here is a contract change: update this file in the same commit.

## Records (`Sources/ZagonCore/Model/`)

All timestamps are `Timestamp` = `Double` seconds since the Unix epoch (UTC). Session ids are `<tool>:<native id>`
(`claude:174a7d2d-…`, `codex:019a…`, `cursor:<conversation id>`). `ToolKind` (0.1.5 added `cursor`) is also the `tool`
value of sessions, `day_agg` rows and exports; a reader that knows only `claude` / `codex` must skip or show the
others, not fail.

| Type | Meaning | Notes |
|---|---|---|
| `SessionMeta` | partial session description | `nil` = unknown here, never "clear". Title replaces the stored one only if `titleRank` >= stored (`TitleRank`: ai-title 1, agent-name 2, custom-title / external 3). `archived` (Codex `archived_sessions/`, `threads.archived`): archived sessions stay in history (days, weeks, ranges) but are left out of the live session list; `nil` keeps the stored value. `account` (v8): the Claude Code account (see Accounts); `nil` keeps the stored value. |
| `UsageRecord` | tokens of one API request | `messageId` set → dedup ledger: the **last** record with that id wins, a later copy of the id in another file is ignored. `messageId` nil → added as is (source emits per-request deltas, e.g. Codex `last_token_usage`). `agent` = sub-agent label, `""` for the main thread. `cacheWrite1h` = the part of `cacheWrite` kept for an hour (Claude `cache_creation.ephemeral_1h_input_tokens`; priced 2× input, the rest 1.25×). `cwd` = the directory of the request (Claude: the record's `cwd`; Codex: the turn's), the project its tokens count for. |
| `ToolCall` | one tool invocation | `callId` (`toolu_…`) drops duplicates of rewritten records; counted per hour and name. |
| `ActivityEvent` | the agent did something at `ts` | feeds `working` intervals; `cwd` = the record's working directory (Claude: every transcript line, so sub-agents get their own; Codex: `session_meta.cwd`, then `turn_context.cwd`) |
| `UserMessage` | the human typed a message at `ts` | starts a turn, counts as a user action (unless a `Relay` says another session typed it, see Time rules); `cwd` as for events; parsers always pass `text`: Ingest puts it into the contentless FTS index (only with `index_prompts`) and extracts task keys from it; it is never stored. Claude: `user` records typed by the human, messages through a channel plugin (`origin.kind = channel`, Telegram…; `channel = true`: always the human's) and messages sent while the agent was working (`attachment` `queued_command`, `commandMode = prompt`, origin `human` / `channel`, or no origin and not a generated prefix such as `<task-notification`; they never become `user` records) |
| `Relay` | the agent typed into a terminal at `ts` | Claude `Bash` tool calls that run `tmux send-keys` / `send` / `paste-buffer`; `targets` = the session names of their `-t` (lower case, `=`, `:window`, `.pane` cut off), `""` = no `-t` or not a plain name (`$s`, `%3`). Only the targets are kept, never the command |
| `BackgroundTask` | a background task of a Claude session launched or finished at `ts` | main transcript only. Launch (`until` = when it stops counting: `ts` + 12 h, `UserTime.driverIdle`; a non-persistent Monitor at its `timeoutMs` if sooner) from a `user` record's `toolUseResult`: `backgroundTaskId` (Bash in the background), `isAsync` + `agentId` (async Agent), `taskId` + `persistent` (Monitor). End (`until` nil): a `queue-operation` `enqueue` whose `content` holds `<task-notification>` blocks with a `<task-id>` and a `<status>` (completed / failed / killed …; a Monitor `<event>` without `<status>` is not an end), or a TaskStop result (`toolUseResult.task_id` + `task_type`). |
| `LimitSnapshot` | subscription limit reading | Claude windows `five_hour` / `seven_day`. Codex: the main limit (`rate_limits.limit_id` absent or `codex`) as `primary` (300 min ≈ 5 h) / `secondary` (10 080 min = week); any other `limit_id` (e.g. `premium`) as `<limit_id>:primary` / `<limit_id>:secondary`. Ingest stores them as readings (`limit_snapshot`, key tool + account + window + ts), not as file contributions. `account` (v8): whose subscription, `default` unless a Claude status line ran under another `CLAUDE_CONFIG_DIR` (Codex: always `default`). |

## Parsers (`Model/Parsing.swift`)

A source is a `SourceSpec { tool, root, accepts(relativePath), makeParser(path, relativePath, state) }`.
`Ingest` walks `root`, tails every accepted file and calls the parser's `parse(line:into:)` once per **complete** line
(a partial last line is not passed until its newline arrives). The parser appends records to `ParseOutput`; after each
chunk Ingest writes them, the new offset and `saveState()` in one transaction. Rules for parsers:

- never throw or crash on any input; count unusable relevant lines in `ParseOutput.badLines`;
- ignore unknown fields and record types;
- keep `saveState()` small (it is persisted per file); state is `nil` for a new file and after a reset;
- the session of a file is the `sessionId` of its first record (usage, event, message); records in the same file
  with another session id are still stored under their own id, but ledger (messageId) records always use the file's.

Ingest handles: offsets, inode/size/tail checks, truncation and replacement (retracts everything the file
contributed and recounts it from byte 0), deleted files (their contributions stay), working intervals, user time,
`session` rollups, `day_agg`.

Moves: a path without a `source_file` row is first matched against known files of the same tool (any root of
that tool, e.g. Codex `sessions/` → `archived_sessions/`): same inode, old path gone (or now another inode), size
>= stored offset and the same tail bytes before it. A match only updates `source_file.path`; nothing is retracted
or recounted and tailing goes on from the stored offset. The parser is not called for a move without new bytes, so
"archived" must come from another signal (Codex `threads.archived`), not from seeing the new path. A copy (new
inode) is a new file.

Compressed logs (Codex 0.16x: a rollout cold for 7 days becomes `<name>.jsonl.zst`, the same bytes, and the original is
deleted; to append Codex unpacks it back to `<name>.jsonl` under a new inode and deletes the `.zst`): for a source that
accepts `<rel>.zst`, the `source_file` row keeps the plain name `<name>` in both forms, with offsets, sizes and tails of
the unpacked content (unpacked into an unlinked temporary file next to the database, never leaving less than 256 MB free
there; a failure is retried when the file changes); `meta packed:file:<id>` marks a row last read from its `.zst`.
Between the forms a new inode is not a replacement: the bytes before the offset decide, so nothing is recounted. While
both forms exist the plain file is read and the `.zst` skipped; a `.zst` already read is skipped while its inode and
mtime stay. Moves between roots work in either form (inode), and a form changed on the way is matched by file name in
another root when the old file is gone in both forms. A zagon without this (0.1.4) sees a compressed file as gone and an
unpacked one as replaced, so it recounts rather than double counts. Our archive keeps copies of plain files only (a
`.zst` is one already: if it is deleted later, its counts stay but handoff and search lose it); `Archive.readLog` and
`transcript(id)` unpack it for handoff and search.

Cursor's agent (`Cursor/CursorSource.swift`, tool `cursor`): sessions, time and the tokens its hooks report; never
limits or prices (Cursor keeps them on its servers; Zagon reads no credentials). Three sources, all `CursorSource.specs`:

- hooks: `spool/<UTC day>.cursor.ndjson` (see Live status from hooks). `UserPromptSubmit` is a typed message whose
  text is only the prompt's task keys (found by the hook as Ingest finds them, no brief keys), `PostToolUse` /
  `SubagentStop` / `PreCompact` / `Stop` are agent events, so turns are exact; each line also gives `SessionMeta`
  (cwd = the first workspace root, model). The daemon passes these files to `Ingest.update` too. Each file is its own
  TurnBuilder: a turn across UTC midnight loses the stretch between its last event before and its first after.
  `afterAgentResponse` (only when wired in Cursor's own hooks.json: Claude Code has no such event) is an agent event
  too. Tokens: a line with `input_tokens` / `output_tokens` / `cache_read_tokens` / `cache_write_tokens` (`stop`,
  `afterAgentResponse`) is a usage record of model `cursor/<model>` (`cursor` without one), which `Pricing.rates`
  never prices (unpriced: "$ ?"). One `generation_id` counts its largest report per field (parser state keeps the
  last 64 generations of the file), so `stop` and `afterAgentResponse` of one answer never add up; a generation
  reported on two UTC days counts in both files, reports without a generation id add up. `requests` = the reports
  that added tokens. Whether a report is one answer's tokens (not the conversation's running total) is from Cursor's
  bundle, not yet seen live.
  These files are kept 40 days (SpoolIngest; other spool files 7): they are the only record of this time.
- transcripts: `~/.cursor/projects/<slug>/agent-transcripts/<id>/<id>.jsonl` (sub-agent logs and old `.txt` are
  left out). Lines hold no times; a typed message (`<user_query>`, its text for keys and search) is placed only when
  a `<timestamp>` tag (minutes, `UTC±h[:mm]`) precedes it, and its turn ends a second before the next placed one, the
  last at the file's mtime (also when only answer lines came since), each at most 10 minutes, and none when that end
  is over 30 minutes away: approximate time. User time too: a capped turn's end counts as the moment the user read
  the answer (TurnBuilder), so a reply within `idle_gap` of it joins the two stretches. The stamp is the last `<timestamp>` before the last `<user_query>`. Title
  = the first line of the first typed message (rank 0). The folder is found by matching the slug (`/` and other
  non-alphanumerics as `-`) against folder entries, never inside folders macOS guards nor, on macOS, through a link;
  unknown = no cwd, project = the part of the slug no folder matched. Archive copies
  neither source (Claude Code and Codex only).
  Only messages more than a minute before `<data-dir>/cursor-hooks` (the first Cursor hook's time, written once by
  `zagon hook`) count: after that the hooks do, and the two never overlap.
- conversation headers (Cursor 3 writes no transcripts): `CursorHeaders.sync` opens Cursor's
  `<User>/globalStorage/state.vscdb` (`<User>` = `~/Library/Application Support/Cursor/User` on macOS,
  `$XDG_CONFIG_HOME/Cursor/User` elsewhere) with `mode=ro` (no copy when that fails; busy timeout 0.25 s; closed
  before anything else is read) and reads only table `composerHeaders`: `composerId`, `workspaceId`, `createdAt` /
  `lastUpdatedAt` (ms), `isSubagent` and `json_extract(value, '$.name')` inside SQLite (the conversation's title,
  stored as the session title); never `ItemTable`, `cursorDiskKV` or the text of a conversation. Kept: main
  conversations without a transcript row in this database (`source_file`) whose workspace is local:
  `<User>/workspaceStorage/<workspaceId>/workspace.json` gives a `file://` `folder` (its decoded path = cwd) or
  `workspace` file (no cwd). A remote one (Remote SSH: its hooks run on the server, counted there) is left out; an
  unknown one (no `workspace.json`) adds nothing new but keeps its old line, as does a conversation gone from the
  list. Assumed, not yet seen live: `workspaceId` is the `workspaceStorage` folder name, `composerId` the hooks'
  `conversation_id`. File `<data-dir>/cursor/headers.ndjson` (`{"id","created","updated","cwd"?,"name"?}`, seconds,
  `updated` at most a second before the hooks' start; 0600): kept / gone lines first, then the listed ones oldest
  first; only new lines at the end → appended (Ingest tails it), else replaced by rename (a new inode: Ingest takes
  back what it counted and counts it again). The caller passes it to `Ingest.update` when `sync` returns true. At most
  every 5 minutes (`meta` `cursor_headers_at`): after `Ingest.scan` in the app's pass, `zagon scan` / report commands
  and the daemon's full passes. `CursorHeadersParser`: `name` is the title (rank `external`); before the hooks (a
  minute's margin) the creation is a typed message without text and its turn ends at `updated`, at most 10 minutes,
  none when that is over 30 minutes away: rougher than the transcripts.

## Store (`Sources/ZagonCore/Store/`)

`Store(path:)` opens SQLite in WAL mode and applies migrations (`PRAGMA user_version`); a database newer than the
binary's schema throws `StoreError` before any write. `Store.host` is the machine the database belongs to:
`meta.host`, fixed at the first open (gethostname, or for a database from before pinning the host most of its sessions
carry), so a renamed machine (`X.local` → `X-2.local`) keeps one host.
`IngestOptions.host` nil = that host (set it only to import another machine's data). Public write API for
hooks, status line and importers:

- `mergeSession(SessionMeta, host:)` — create or fill a session (e.g. Codex `threads` titles);
- `setStatus(sessionId:tool:status:at:detail:)` — live status from hooks (`working`, `waiting_permission`,
  `waiting_input`, `ended`); older events never overwrite newer ones; `detail` (`session.status_detail`, v3) = the
  tool waiting for approval in `waiting_permission` (hook `tool_name`), NULL otherwise; a session it creates gets
  `Store.host` (hooks run where the session runs; before v8 such sessions had no host, and a Mac took them for its own);
- `addLimitSnapshot(LimitSnapshot)`, `latestLimits()` (the current reading per tool, account and window; ordered by tool,
  the default account first), `Store.limitKey` (`<tool>:<window>`, another account `<tool>:<account>/<window>`: the
  key of `meta` `limit_src:` and of limit notifications);
- `addActivity(sessionId:start:end:kind:)` — an interval known from hooks (`file_id` NULL);
- `nextSeq()` — global change counter used by `export --since <seq>`;
- `db` — the raw connection for anything else (prefer adding a method).

Writes that belong together go in `store.db.transaction { … }` (BEGIN IMMEDIATE).

## Accounts (`Util/Accounts.swift`, v8)

Claude Code runs under several accounts on one machine: each `CLAUDE_CONFIG_DIR` has its own login, transcripts
(`<dir>/projects`) and subscription limits; `~/.claude` (no `CLAUDE_CONFIG_DIR`) is the account `default`.

- Name: `[accounts]` in config.toml (`"/root/.claude-corp" = "corp"`, `~/` expanded), else the folder's basename
  without leading dots and a `claude-` / `claude_` prefix (`.claude-corp` → `corp`). `[limits] account` labels the
  default account where several are shown (`Accounts.label`).
- Roots (`Accounts.claudeRoots`): `--claude-dir` (default account), then `<dir>/projects` of every folder in
  `[accounts]` and every folder a hook or the status line reported, remembered as `meta` `claude_dir:<folder>`
  (`Accounts.learn`: an absolute path without `..` that holds a `projects` folder, never `~/.claude`). No setting is
  needed for a second account whose `settings.json` runs zagon's hooks: its first hook after its first transcript adds
  it (`[accounts]` names it at once). `~/.claude` is always `default` (an `[accounts]` entry for it is ignored). The daemon
  checks the roots every 10 s while idle and restarts in place (`execve`) when they changed; CLI commands, MCP and
  `zagon handoff` read them at start (handoff looks for a session in every root).
- A Claude hook line carries `config_dir` (`CLAUDE_CONFIG_DIR`) when it is set; a status-line `limits` line always
  does (`""` = not set). SpoolIngest takes the folder from `config_dir`, else from `transcript_path`
  (`<dir>/projects/<project>/<id>.jsonl`); a `limits` line without `config_dir` (a zagon before v8) gets its session's
  `account`, else `default`. A hook sets its session's account (a session copied into another account's folder and
  resumed there moves to it); Ingest sets it on every Claude session from the root of its transcript. One session id
  in two roots (such a copy) is read from both: tokens count once (request ids), typed messages too (`humanActions`
  takes distinct `(session, ts, kind)`), search may list it twice.
- Day, week and task views of limit growth (`LimitUsage`: `QueryDay`, `TaskTime`) follow the default account.
- Shown: next to a session of another account `(corp)` (`Accounts.tag`: CLI, MCP, bot, notifications); limits per
  account (`Accounts.labeled`): a tool's readings of the default account alone are shown as before, without a label;
  once another account has readings within 8 days every reading of that tool is labeled (`Claude (corp)`, the
  default one by `[limits] account`, else `default`); another account's readings older than 8 days are left out.

## Tables (schema v9, `Store/Schema.swift`; migrations are append-only)

- `source_file` — per-file tail state; `usage_hour`, `tool_use`, `activity`, `user_action`, `fts_doc`, `msg`,
  `relay` carry `file_id`, so one file's contribution can be retracted. `recount` (v5) = 1: count the file again from
  byte 0 (the v5 migration sets it on every file to fill `cwd` and the 1-hour split). Ingest does that when it next
  reads the file; after a full pass, a due file whose original is gone is recounted from its archive copy
  (`meta archive:file:<id>`, unpacked to `<database>.recount`, created exclusively and removed) when the copy holds
  the counted bytes (size, and the tail before the offset), else its rows stay as they were (`cwd` '', no 1-hour
  split). A recount runs in a savepoint and is kept only when the file's tokens per (session, agent, hour, model) and
  tool calls come out as before (`Ingest.recount`); otherwise the old rows stay (request ids older than `dedup_days`
  are gone from the ledger, so a resumed session's copy of history would be counted again). History is never lost or
  counted twice. A due file whose root this process does not walk, or whose copy cannot be unpacked now (disk full),
  waits for a later pass.
- `usage_hour` (v5) — PK `(file_id, session_id, agent, hour, model, cwd)`; `cwd` '' = not known (rows from before v5
  that could not be recounted, imports); `cache_write_1h` is part of `cache_write`.
- `msg` — dedup ledger (64-bit FNV-1a hash of `messageId` → owner file, hour, model, cwd, counted tokens with
  `cache_write_1h`, tool call ids); pruned after `dedup_days` (default 40, longer than Claude Code's 30-day cleanup).
- `session` — rolled up from files; `status`/`status_at` belong to hooks and are never touched by ingest; `account`
  (v8) = the Claude Code account (Accounts), NULL = unknown (sessions from before v8 not read again, Codex, Cursor);
  `archived` (v2) NULL = unknown, 0/1 from `SessionMeta.archived`. `cwd`/`project` = the directory the session
  started in (its earliest `activity.cwd`; a later `cd` does not move it), else the last one a parser reported.
  `project` stays the parser's name (the folder's last component); reports, the live list and MCP show the project
  of `cwd` in `dir_project` instead, when there is one (`Projects.sessionSQL`).
  `user_msgs` = the human's messages (`msg` not relayed, plus `channel`). `driver` (v6) = the session that typed
  its last typed message (the sender of the relay that made it relayed, see Time rules), NULL = the human; set
  with `user_msgs`, only from a relay aimed at exactly the session's name, or from any relay when the session has no
  human messages at all (a looser match would hide a session that waits for you). A session waiting for input whose
  driver is live (not `ended`, not archived, active within the last 12 hours: one killed without `SessionEnd` stops
  counting then; `UserTime.driverIdle`) waits for that session, not for you: the live list
  (`LiveSessionInfo.drivenBy`) and `sessions` (`SessionLine.drivenBy`, JSON `driven_by`) carry the driver's title,
  else its project ("" = neither; `UserTime.driverSQL`); the CLI, the bot and MCP say "driven by <name>" (v9; "waits for session <name>" before),
  the Mac lists it with the idle ones, and no "waiting for you" or "finished" notification is sent for it (its
  driver watches it). The v6 migration also
  drops the Mac's `remote_seq:` cursors, so it pulls its servers' sessions (with their drivers) once again.
  `bg_tasks` (v9) = background tasks still running (`Background`: `id@launched@until` entries, epoch seconds, space
  separated), `bg_until` = the latest `until`; written by transcript ingest from `BackgroundTask` (a launch adds, an
  end removes, entries past their `until` by the batch's last record go), and on a Claude `SessionStart` that is not
  `compact` by the spool, which drops the entries launched before it (a new process: the old one's tasks died with
  it; transcripts are read before the spool in a pass). Hooks keep owning `status`. A session `waiting_input` with
  `bg_until > now` is "working in background" (`LiveSessionInfo.background`, `SessionLine.background` = the number
  of entries with `until > now`): the CLI, MCP and the bot say "working in background" / «работает в фоне», list it
  with the working ones, the Mac in its working group, and no "waiting for you" or "finished" notification is sent.
  Driven without background tasks it is neutral: "driven by <name> · turn ended N min ago" / «под управлением … ·
  ход окончен N мин». The v9 migration recounts (`recount`) the main Claude transcripts changed in the last 12 h, so
  tasks launched before the upgrade are known.
- `activity(kind = working | waiting)`, `user_action(kind = msg | channel | read)`, `user_activity` (derived: your
  time, see Time rules).
- `relay(file_id, session_id, ts, target)` (v5) — one row per `Relay` target.
- `dir_project(host, cwd, project, home, seq)` (v5, PK `(host, cwd)`) — every directory a record carried, resolved once
  by Ingest on the machine that recorded it, while it is on disk (`Projects.resolve`): inside a git checkout (a
  `.git` directory; a worktree's `.git` file → `commondir` → its main checkout; a submodule: its own; a checkout at
  the home directory itself is not used) `project` = the repository's name, the last segment of `url` in
  `[remote "origin"]` of its git config without `.git`, else the checkout's folder name (a worktree: its main
  checkout's); outside one, `(temp)` under `/tmp`, `/var/tmp`, `$TMPDIR`, `/var/folders` (also under `/private`) and
  `~/.claude` (a home directory inside them excepted), else the directory's last component (also when it is gone; on
  macOS also, without touching the disk, under the folders that ask for access: `~/Desktop`, `~/Documents`,
  `~/Downloads`, `~/Library/Mobile Documents`, `~/Library/CloudStorage`, `/Volumes`, `/Network`);
  `home` = 1 for the home directory (`IngestOptions.home`, else `$HOME`, also as its real path) and `/`. Looked up by
  the session's host. Exported, so a client counts another machine's directories the same way.
  `activity.cwd` (v4): the directory the interval was worked in; a new directory inside a turn splits the interval
  at the last event in the old one (no time lost); hook `waiting` intervals take the hook's cwd; NULL = unknown.
- `task_session(task_id, session_id, how, start, end)` (v4): the linked period of a session, `[start, end)`;
  the defaults `[0, 1e18)` mean the whole session, so `start <= t AND end > t` needs no special case.
  PK `(task_id, session_id, start)` — an upsert names that target.
- `task_key(file_id, session_id, key, at)` (v4): every task key in a message typed at `at` (pattern
  `[tasks] key_pattern`, default `[A-Z][A-Z0-9]+-\d+`, upper-cased, a match glued to a letter or digit before it is
  not a key; `""` = off). Only messages Ingest takes as actions (not history copied into a resumed file); filled
  with or without `index_prompts`; retracted with its file. No text is stored. Not from `<system-reminder>` spans
  (memory, CLAUDE.md) nor from a paragraph or numbered item holding a clock range (`09:00–10:15`: a pasted worklog list). `how` (v7):
  NULL = typed; `brief` = from the first non-empty line of a brief the message names (an absolute or `~/` path to a
  regular .md/.txt file of at most 256 KB on this machine, at most 5 paths per message; never the brief's body). A key
  typed and in a brief at once stays typed. The v7 migration marks Claude files changed in the last 14 days for one
  recount (`source_file.recount`, as in v5), so their keys follow these rules; older days keep their keys, and so does
  a file whose recount comes out with other totals. A brief is read when its message is scanned (also by the
  recount): its title then; the title is its first heading among the first 5 non-empty lines, else the first line.
- Worklog texts live in `meta` (no table): `wltext:<auto|manual>:<day>:<task>:<start>`, `wlsum:<auto|manual>:<day>:<task>`,
  `wltext_built:<day>`, `wltext_auto:<day>` (the 23:55 rebuild done), `wlsummary:<day>:<jira key>` and
  `wlcomment:<day>:<jira key>` (a day summary in Jira), see docs/dev/tasks.md. `log plan --json` (`DayPlan`) only gained
  fields in 0.1.5, all optional: `tz`, `summary_built_at`, `sessions_after_summary`, `excluded`, `unassigned`; per row
  `text_source`, `day_summary`, `summary`, `summary_source`, `sessions`.
- `day_agg` — per local day and host, built only from sessions of that host (`coalesce(session.host, host)`), so
  usage, tool calls, activity and user actions imported from other machines never count twice: rows with `model <> ''` hold tokens; `model = ''` rows hold `session_sec` per
  (tool, project); the `tool = project = model = ''` row holds the day totals `session_sec` and `user_sec`. `seq`
  = change counter. The project of tokens is the one of each request's `usage_hour.cwd`, of session time the one of
  each interval's `activity.cwd` (union per session and project, so parallel sub-agents in two directories count in
  both; the totals row stays the union per session), by `Projects.of`. `session_sec` is agent time (summed over
  sessions); "sessions worked" in every output (0.1.7: `today`/`day`/`week`, MCP, the bot, summaries, the Mac) is
  wall-clock instead, the union of all sessions' `activity` working intervals, computed when read (`SessionTime.wall`,
  not stored): `worked_sec` next to `session_sec` in `--json` / `DayReport`, `WeekReport` (`previous_worked_sec`),
  `DayDetail`, `PeriodTotals`; `Query.hours` is wall-clock. The session's own project is the
  `dir_project.project` of the folder it started in (`session.cwd`), else `session.project`: an unknown directory
  counts for it; for a session that started in a folder that is not `home` in `dir_project`, so does a directory
  inside that folder (`cd src`); any other directory, and every directory of a session started in the home directory
  or `/` (one that works in many projects), counts for its own `dir_project.project` (its last component when not
  resolved). Tool calls go to the session's own project. `cache_write_1h` (v5) as in `usage_hour`.
- `limit_snapshot` (v8: `account TEXT NOT NULL DEFAULT 'default'`, PK `(tool, account, window, ts)`; the v8 migration
  copies older readings as the default account's), `task*`, `worklog_plan`, `summary`, `handoff`, `fts` (contentless
  FTS5) + `fts_doc`. The v8 migration also gives sessions without a host `meta.host` and a new `seq`, and drops a
  Mac's `remote_seq:` cursors so it pulls its servers' sessions and accounts again.
- Limit sources live in `meta` (0.1.5, no column in `limit_snapshot`): `limit_src:<Store.limitKey>:<source>` = the `ts`
  of that source's newest reading of the window (`Store.addLimitSnapshot(_:source:)`; `<source>` "" = this store's own
  readings, else the ssh alias `ExportImport` was given), `limit_account:<alias>` = the server's `[limits] account`
  (from its default account's `limit` lines; removed when they come without one). `Query.limitSources` names the
  source of each current reading (its own newest reading, else the source's newest reading of the same window period),
  its `limitAccount` and label (`account`: another account's name, the default one's `[limits] account` of that
  source) and whether more than one source has a reading of that tool and account within 8 days. The Mac drops an
  alias's keys with its other rows (`Remote.forget`). The pace history (`Query.limitHistory(…, account:)`, default
  account unless given) still mixes sources; `Query.limits` gives each reading's `account`.

## Time rules

- `working`: from a typed message (or the first agent event) to the last agent event before the next typed
  message; a silence longer than `session_gap` (default 30 min) between agent events ends the interval. Computed
  per file, then merged per session (parallel sub-agents are not double counted).
- user time: user actions (typed messages, plus the end of the answer the user replied to within `idle_gap`)
  across all sessions, chained when the gap is at most `idle_gap` (default 20 min). A message one session sends to
  another (a worker driven over `tmux send-keys`) is not yours (`UserTime.humanActions`): a typed `msg` in session W at
  `t` is relayed when another session of this host has a `relay` in [t − 30 s, t + 5 s] (in the logs of a leader
  driving tmux workers, every worker message came 0–26 s after the driver's call; a message queued while the worker
  is busy is written when it is typed, not when it is handed over, so the same window holds). When W has a name (a
  Claude title of rank ≥ agent name: `claude --name`, `/rename`), only a relay whose target is that name counts
  (letters and digits, lower case; equal or one a prefix of the other, so `-t docs` matches `docs site`); without a
  name (the default, and every Codex session), a relay counts unless its target is another session's name; a relay
  without a plain target (`$s`, `%3`, none) counts for any session. The `read` before a relayed message goes with it;
  it still starts a turn (working time). A relay is a Bash tool call that runs `tmux send-keys` / `send` /
  `paste-buffer` (parsed as tmux reads its options: a command that only mentions them is not one). Limits:
  - a human typing into an unnamed session (or one named like the target) within those 35 s after another session's
    send-keys to a target that names no other session (`-t dev`, `$s`, `C-c` into some pane) is taken for a relay;
  - a driver that types some other way (a wrapper script that hides `tmux` from the Bash command, `screen`, another
    program, `ssh other-host tmux …` driving a session on another host) or whose call comes over 30 s before the
    message (a long `sleep` first) is not seen, so its messages stay yours;
  - a worker renamed to something unlike its tmux target only matches relays without a target;
  - a rename changes which past messages are yours: `user_activity` and `user_msgs` follow at once, `day_agg` of a day
    only when that day is rebuilt.
  Channel messages are always yours.
- days are local days in the top-level `timezone` of config.toml (the older `[notify] timezone` is still read),
  else `TZ` / `/etc/localtime`; every command applies it at start (`Settings.applyTimezone`). The zone the day rows
  were built in is kept in `meta.tz`, the version of the rules that build them in `meta.day_rules`
  (`Ingest.dayRules`, an integer; never lowered); a scan in another zone or with newer rules rebuilds all days of the
  host and writes both values only together with the rebuilt days. Rules 3 first resolve this host's `dir_project`
  rows again (directories still on disk, and gone ones that had only their last component; a gone one with a
  checkout's name, such as a removed worktree, takes the new name of the directories on disk that had that name when
  they agree on one; changed rows get a new `seq`)
  (one left empty keeps a zero totals row, so `export` tells clients). The zone is set by
  `zagon tz`, the bot's `/tz` and MCP `settings_timezone` (`Settings.setTimezone`); `zagon daemon` sees the change
  within ~10 s and restarts itself in place (`execve`, same pid), `zagon notify` switches in its loop. Usage is bucketed by UTC
  hour, so zones with a non-whole-hour offset get day edges rounded to the hour.

## Export (`zagon export --since <seq>`, `Export/Export.swift`)

NDJSON on stdout, keys in snake_case, one consistent read snapshot; the Mac app pulls it over SSH.

- first line `{"type":"export","schema":<user_version>,"since":<n>,"seq":<m>,"version":"<v>"}` — pass `m` as the next
  `--since`; `version` is what `zagon --version` prints (`0.1.0`, `dev` for a local build); a zagon without the key
  predates the releases (it has no `zagon update`);
- `{"type":"session", id, tool, host, project, cwd, git_branch, title, model, started_at, last_at, status, status_at,
  status_detail, user_msgs, archived, seq, driver, account, bg_tasks, bg_until}` for every session with `seq > since` (missing keys = NULL;
  `host` NULL is sent as the store's own since v8; `account` v8; `bg_tasks`, `bg_until` v9: a client before v9 ignores them), each followed
  by `{"type":"activity","session_id","kind","start","end","cwd"}` lines — the session's complete `working` /
  `waiting` intervals, merged per kind and directory (no overlaps inside one; `cwd` missing = not known): on a
  `session` line the client drops every interval it holds for that session and stores the ones that follow (none =
  the session has none);
- `{"type":"day","day","host","seq","start","end","rows":[…],"usage":[…],"tools":[…],"user":[…]}` for every
  (local day, host) with a `day_agg` row changed after `since`; `start`/`end` are the server's local day bounds in
  epoch seconds (use them, not the client's time zone). Everything in it replaces what the client holds for that
  day and host:
  - `rows`: the complete `day_agg` rows `{tool, project, model, input, output, cache_read, cache_write, cache_write_1h,
    requests, tool_calls, session_sec, user_sec}` (meaning as in `day_agg` above; a day emptied by a retraction comes with one
    all-zero totals row);
  - `usage`: `usage_hour` of the day summed over files and directories, one row per `{session_id, agent, hour, model}`
    with `input, output, cache_read, cache_write, cache_write_1h, requests, tool_calls` (`hour` = UTC hour start,
    `agent` = "" for the main thread; an export from before schema v5 has no `cache_write_1h`: read it as 0);
  - `usage_cwd` (v5): the same rows split by `cwd` (`""` = not known); a client that knows the key stores these instead
    of `usage` (older clients ignore it and keep working);
  - `tools`: `tool_use` of the day, one row per `{session_id, hour, name}` with `n`;
  - `user`: your-time intervals `{start, end}` clipped to the day (a stretch over midnight comes in both days);
  - the day's totals by agent, tool, hour, session or model are sums over `usage` / `tools`; they equal `rows`;
- `{"type":"dir", host, cwd, project, home, seq}` (v5) — `dir_project` rows with `seq > since`, before the `day` lines;
  the client stores them with `seq` 0 (it cannot resolve another machine's directories);
- `{"type":"summary", day, engine, text, created, seq}` — a kept day or period summary (`summary` row) changed after
  `since` (`meta` `summary_seq:<day>`; `since` 0 sends all): `day` = `YYYY-MM-DD` or `from..to`, `text` = the
  `SummaryDoc` JSON (`Notify/SummaryDoc.swift`); the client stores it as its `summary` row of that day and engine;
- `{"type":"limit", tool, window, used_pct, resets_at, window_minutes, ts, host, account, account_id}` — the current
  reading per (tool, account, window) (`Store.latestLimits`), in every export; `host` (0.1.5) = the exporting store's
  `meta.host`; `account` (0.1.5) = its `[limits] account`, left out when not set; a line without them (0.1.4) = no
  account. Only the default account's readings: another Claude Code account's are
  `{"type":"account_limit", tool, window, used_pct, resets_at, window_minutes, ts, account_id}` (v8; no `host`, no
  `account`; `ExportImport` stores them under `account_id`, labeled by that name), which a client before v8 skips
  instead of mixing them into the default account's (the Mac's
  `Remote.apply` takes host names of a server from its `session` / `day` lines only, not from this `host`);
- unknown line types and keys must be ignored (the format only grows).

`ExportImport(store:source:)` (`Export/ExportImport.swift`) is the reference client: it applies an export to
another store, keeping imported `usage_hour` / `tool_use` / `activity` rows on one `source_file` row
`export:<source>` (your time as `activity` with `kind = 'user'`, `session_id = ''`), so local ingest never touches
them and `Reports` on that store give the server's numbers. Its `limit` readings are stored with `<source>` as their
source (`limit_src:…:<source>`, `limit_account:<source>`). Tested: a full export imported into an empty store gives
the same `Reports.day`, per-agent and per-tool sums and intervals; incremental exports applied on top, each twice,
double nothing.

## Daemon (`zagon daemon`, `Daemon/`)

One full pass (`Ingest.scan`, `CodexThreads.sync`, `SpoolIngest.run`), then inotify on every source root
(recursive), `<data-dir>/spool` and the Codex home (`state_*.sqlite`); changes are applied in batches after
`--debounce` seconds (default 0.5) through `Ingest.update(paths:)`; a lost-events signal (queue overflow, a watched
directory moved) triggers a full pass. Missing roots are retried on each idle wake-up (once a minute). Linux only;
the Mac app follows files itself.

Memory: the static build links mimalloc, which keeps a thread's freed pages until that thread allocates again. The
daemon hands them back (`mi_collect`, glibc: `malloc_trim`) with the unused SQLite page cache after a full pass, 5 s
after the last batch, after each archive pass and on each notifier round; background connections use a 256 KB page
cache, the main one 512 KB after the first pass. Files quiet for an hour, read by a pass, and archive copies are
dropped from the page cache (`posix_fadvise(DONTNEED)`), so the service's cgroup does not fill with them. Batches
made only of spool lines wait 1.5 s instead of 0.5 s (statuses stay under 2 s).

After the first pass a second thread with its own connection runs `Notifier.tick()` and `Bot.pollOnce(timeout: 25)`
(or a 30 s sleep without the bot); `--no-notify` turns it off, no configured channel = off. A third thread (nice 10,
idle I/O class, own connection) runs `Archive.tick()` every 10 minutes; `--no-archive` turns it off. SIGTERM / SIGINT apply
the pending batch and stop. Log: `<data-dir>/logs/daemon.log` (+ `.1`, `.2`, at most 5 MB each), lines
`<UTC ISO time> <text>`: `start`, `full pass (<reason>)`, `watching <dir>`, `error (attempt n, …): <reason>`,
`notify: …`, `stop: signal n`, `exit: <error>`, and every `--health-minutes` (10) a line
`health: rss … (anon …, file …), cpu … s in … s (… %), db … MB, watched … dirs, batches …, files …, errors …, full passes …`
(counters since the previous health line). Only numbers, ids, paths and error reasons — never conversation text.
`zagon doctor` prints the last health line and the tail of the log.

## Live status from hooks (`Hooks/`)

`zagon hook <claude|codex> <Event>` appends one line per call to `~/.zagon/spool/<UTC day>.ndjson` (ids, paths,
event names; Cursor's prompts only as their task keys; never prompt text or tool input). A Claude line carries
`config_dir` = `CLAUDE_CONFIG_DIR` when set (v8, see Accounts); so does a status-line `limits` line. A hook line also carries `pid` (`Sys.clientPid()`: the Claude Code /
Codex process, skipping the `sh -c` around hook commands; Linux only). Only handoff reads it, to match `zagon mcp` to
its conversation; it is never stored in the database. `SpoolIngest.run` applies new lines to `session.status` /
`status_at` and records a `waiting` activity interval when a `waiting_*` status ends. Older events never overwrite
newer ones; a repeated status keeps the time it began.

| Event (Claude Code and Codex) | Status |
|---|---|
| `UserPromptSubmit`, `PostToolUse` | `working` (PostToolUse clears `waiting_permission` once a request was approved; ~3 ms per tool call) |
| `PermissionRequest`; Claude `Notification` with `permission_prompt` | `waiting_permission` |
| `Stop`; Codex `Interrupt`; Claude `Notification` with `idle_prompt`; `SessionStart` (not `compact`) | `waiting_input` |
| `SessionEnd` | `ended` |

A second source on Linux: the daemon runs `claude agents --json` (Claude Code 2.1.145+; `claude` from PATH and the
CLI's install places) every 30 s while a Claude session of this host not `ended` was seen in the last 30 minutes, and
applies it through the same `setStatus` (`ClaudeAgents`), dated 5 s before the call so a hook not yet ingested still
wins: `busy` → `working`; `waiting` for a permission prompt, sandbox / worker request or input needed →
`waiting_permission`, other `waiting` and `idle` → `waiting_input` (`idle` of a background session still `working`:
no change); an exited background session `done` → `waiting_input`, `blocked` → `waiting_permission`, `failed` /
`stopped` → `ended` (never reopens an `ended` one). Only sessions already in the database; one missing from the list is
left alone. A Claude Code without the command (non-zero exit, not a JSON array) is asked again an hour later.

Cursor's agent runs the hooks of `~/.claude/settings.json` too (Third-Party Imports, on by default; Cursor maps
`UserPromptSubmit`, `PostToolUse`, `Stop`, `SessionStart`, `SessionEnd`, … to its own events and has no
`Notification` / `PermissionRequest`). Its input is told by `cursor_version` and goes to
`spool/<UTC day>.cursor.ndjson` with `tool` = `cursor`, `session_id` = `conversation_id` (else `session_id`), `cwd` =
the first of `workspace_roots` (else `cwd`), `model`, `tool_name`, `transcript_path`, `generation_id`, the four token
counts (numbers only) and the Claude event name the hook was installed for; never `prompt`, `text`, `user_email`,
`model_params`, tool input or output. Cursor's `sessionEnd` mostly never runs (Cursor quits first): a `waiting`
interval of a Cursor session ends at most `Query.idleAfter` (30 min) after it began, not at the next prompt. The other editors' agents (Devin, Trae, VS
Code) are still dropped (`HookSpool.fromOtherAgent`). The field names are from Cursor's docs, not yet seen live.

The status line wrapper adds `limits` lines (`five_hour` / `seven_day`) only when the reading changed or a minute
passed for that session (the last one is kept in `spool/.limits-<session>`, removed with spool days); Claude Code
redraws the status line every few seconds and each spool line wakes the daemon. They become `limit_snapshot` rows (an
unchanged reading at most once a minute). A session left open re-sends its last reading, so `ts` is when a reading
was written, not measured: the current reading per (tool, window) (`Store.latestLimits`, also the `limit` export lines)
is the highest percent of the newest window period (`resets_at` within 2 minutes of the latest), and a pace starts
from the highest percent of the period up to its first reading (`Store.paceBase`).

## Settings (`~/.zagon/config.toml`)

Every key is optional; the defaults below apply when it is missing. Times are local `HH:MM`, `""` turns a clock
event off. The zone is the system's unless `timezone` is set.

```toml
timezone = ""             # top level, e.g. "Europe/Moscow": days, reports and notifications (system zone if empty)

[tasks]
key_pattern = "[A-Z][A-Z0-9]+-\\d+"   # task keys in typed messages and branches ("" = off)

[notify]
enabled = true            # this host sends notifications (one host per user, or they come twice)
limit_reset = true        # "limit reset" after a window that reached the first threshold of its category
waiting_minutes = 10      # a session waits for you longer than this (0 = off)
long_work_minutes = 15    # a turn that worked longer than this has finished (0 = off); not sent while the
                          # session's own sub-agents or `run_in_background` calls of that turn still run; a sent
                          # done also covers the wait of the same stop
summary_at = "20:00"      # day summary with the ribbon picture
worklog_at = "19:00"      # worklog plan (provided by the tasks package)
quiet = "23:00-08:00"     # nothing is sent inside; events in it are dropped, not delayed
lang = "auto"             # auto | ru | en: notifications, bot replies, day summary; auto = the system language
# timezone = ""           # older place of the top-level `timezone`; still read when the top level has none

[notify.limits]           # per category: ascending %, each 50...100 in steps of 5; [] = off; missing = [80, 95]
claude.five_hour = [80, 95]
claude.week = [80, 95]
codex.five_hour = [80, 95]
codex.week = [80, 95]
codex.<limit_id> = [80, 95]   # a Codex premium limit, both of its windows (stored as `<limit_id>:primary|secondary`)

[notify.limits.corp]      # the same keys for one Claude Code account (see Accounts); missing keys come from
claude.week = [90]        # [notify.limits]

[limits]
account = ""              # e.g. "work": names this machine's subscription (its default Claude Code account); with
                          # readings from more than one source (this Mac, servers) the Mac app shows
                          # "<server> · <account>" next to the rings; beside other accounts it labels the default one

[accounts]                # Claude Code accounts: CLAUDE_CONFIG_DIR folder = name (default: the folder's name without
"/root/.claude-corp" = "corp"   # dots and a "claude-" prefix); their transcripts are read too (see Accounts)

[telegram]
token_file = "~/.config/zagon/tg-bot-token"   # the user's own bot; the token is read from this file only
chat_id = ""              # the only chat the bot writes to and answers
commands = true           # answer /limits /sessions /today /week /day /tz on this host (one host per bot)
api = "https://api.telegram.org"

[ntfy]
topic = ""                # set = channel on
url = "https://ntfy.sh"

[summary]
engine = "claude"         # claude | codex | none (plain: titles, projects, time, files, commits)
model = "haiku"           # for claude -p
timeout = 120             # seconds; on failure or timeout the plain summary is used

[statusline]
original_command = ""     # written by `zagon install`: the status line command the wrapper runs
```

Each threshold of a category notifies once per limit window (crossing two at once sends only the higher one).
Notification state lives in `meta` (`notify:<event key>` = the occurrence it was sent for; `telegram:offset`).

## Transcript archive (`Archive/`, `Sources/CZstd`)

zstd 1.5.7 (single file, no multithreading or dictionary builder, binary-tree compressors left out), level 3.
`Archive.tick()` copies every file Ingest tracks (`source_file`) once its session has been quiet for an hour (all
its files' mtimes and `session.last_at`) and the copy is missing, of another size or older than the original; the
whole file is rewritten (`<copy>.tmp`, fsync, rename; files 0600, dirs 0700). A gone original never touches its copy.

- layout: `~/.zagon/archive/<tool>/<yyyy-mm of session start>/<native id>.jsonl.zst` (the session file, also in
  `session.archive_path`), sub-agents as `<native id>/<path below the session dir>.zst`, a second session file
  (session continued in another project dir) as `<native id>-<source_file.id>.jsonl.zst`;
- the copy of each file is fixed once in `meta` (`archive:file:<source_file.id>` = path), so it survives moves;
- one zstd frame per file, content size in the header, checksum on; `Archive.decompress`, `Archive.transcript(id)`
  (the original while complete, else the copy), `zagon archive run|stats|cat`. Ingest never reads the archive.
