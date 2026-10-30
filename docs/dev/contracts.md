# Contracts between packages

Stable types other packages build on. Changing a field here is a contract change: update this file in the same commit.

## Records (`Sources/ZagonCore/Model/`)

All timestamps are `Timestamp` = `Double` seconds since the Unix epoch (UTC). Session ids are `<tool>:<native id>`
(`claude:174a7d2d-…`, `codex:019a…`).

| Type | Meaning | Notes |
|---|---|---|
| `SessionMeta` | partial session description | `nil` = unknown here, never "clear". Title replaces the stored one only if `titleRank` >= stored (`TitleRank`: ai-title 1, agent-name 2, custom-title / external 3). `archived` (Codex `archived_sessions/`, `threads.archived`): archived sessions stay in history (days, weeks, ranges) but are left out of the live session list; `nil` keeps the stored value. |
| `UsageRecord` | tokens of one API request | `messageId` set → dedup ledger: the **last** record with that id wins, a later copy of the id in another file is ignored. `messageId` nil → added as is (source emits per-request deltas, e.g. Codex `last_token_usage`). `agent` = sub-agent label, `""` for the main thread. |
| `ToolCall` | one tool invocation | `callId` (`toolu_…`) drops duplicates of rewritten records; counted per hour and name. |
| `ActivityEvent` | the agent did something at `ts` | feeds `working` intervals; `cwd` = the record's working directory (Claude: every transcript line, so sub-agents get their own; Codex: `session_meta.cwd`, then `turn_context.cwd`) |
| `UserMessage` | the human typed a message at `ts` | starts a turn, counts as a user action; `cwd` as for events; parsers always pass `text`: Ingest puts it into the contentless FTS index (only with `index_prompts`) and extracts task keys from it; it is never stored |
| `LimitSnapshot` | subscription limit reading | Claude windows `five_hour` / `seven_day`. Codex: the main limit (`rate_limits.limit_id` absent or `codex`) as `primary` (300 min ≈ 5 h) / `secondary` (10 080 min = week); any other `limit_id` (e.g. `premium`) as `<limit_id>:primary` / `<limit_id>:secondary`. Ingest stores them as readings (`limit_snapshot`, key tool + window + ts), not as file contributions. |

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

## Store (`Sources/ZagonCore/Store/`)

`Store(path:)` opens SQLite in WAL mode and applies migrations (`PRAGMA user_version`). `Store.host` is the
machine the database belongs to: `meta.host`, fixed at the first open (gethostname, or for a database from before
pinning the host most of its sessions carry), so a renamed machine (`X.local` → `X-2.local`) keeps one host.
`IngestOptions.host` nil = that host (set it only to import another machine's data). Public write API for
hooks, status line and importers:

- `mergeSession(SessionMeta, host:)` — create or fill a session (e.g. Codex `threads` titles);
- `setStatus(sessionId:tool:status:at:detail:)` — live status from hooks (`working`, `waiting_permission`,
  `waiting_input`, `ended`); older events never overwrite newer ones; `detail` (`session.status_detail`, v3) = the
  tool waiting for approval in `waiting_permission` (hook `tool_name`), NULL otherwise;
- `addLimitSnapshot(LimitSnapshot)`, `latestLimits()`;
- `addActivity(sessionId:start:end:kind:)` — an interval known from hooks (`file_id` NULL);
- `nextSeq()` — global change counter used by `export --since <seq>`;
- `db` — the raw connection for anything else (prefer adding a method).

Writes that belong together go in `store.db.transaction { … }` (BEGIN IMMEDIATE).

## Tables (schema v4, `Store/Schema.swift`; migrations are append-only)

- `source_file` — per-file tail state; `usage_hour`, `tool_use`, `activity`, `user_action`, `fts_doc`, `msg` carry
  `file_id`, so one file's contribution can be retracted.
- `msg` — dedup ledger (64-bit FNV-1a hash of `messageId` → owner file, hour, model, counted tokens, tool call ids);
  pruned after `dedup_days` (default 40, longer than Claude Code's 30-day cleanup).
- `session` — rolled up from files; `status`/`status_at` belong to hooks and are never touched by ingest;
  `archived` (v2) NULL = unknown, 0/1 from `SessionMeta.archived`.
- `activity(kind = working | waiting)`, `user_action(kind = msg | read)`, `user_activity` (derived).
  `activity.cwd` (v4): the directory the interval was worked in; a new directory inside a turn splits the interval
  at the last event in the old one (no time lost); hook `waiting` intervals take the hook's cwd; NULL = unknown.
- `task_session(task_id, session_id, how, start, end)` (v4): the linked period of a session, `[start, end)`;
  the defaults `[0, 1e18)` mean the whole session, so `start <= t AND end > t` needs no special case.
  PK `(task_id, session_id, start)` — an upsert names that target.
- `task_key(file_id, session_id, key, at)` (v4): every task key in a message typed at `at` (pattern
  `[tasks] key_pattern`, default `[A-Z][A-Z0-9]+-\d+`, upper-cased, a match glued to a letter or digit before it is
  not a key; `""` = off). Only messages Ingest takes as actions (not history copied into a resumed file); filled
  with or without `index_prompts`; retracted with its file. No text is stored.
- `day_agg` — per local day and host, built only from sessions of that host (`coalesce(session.host, host)`), so
  usage, tool calls, activity and user actions imported from other machines never count twice: rows with `model <> ''` hold tokens; `model = ''` rows hold `session_sec` per
  (tool, project); the `tool = project = model = ''` row holds the day totals `session_sec` and `user_sec`. `seq`
  = change counter.
- `limit_snapshot`, `task*`, `worklog_plan`, `summary`, `handoff`, `fts` (contentless FTS5) + `fts_doc`.

## Time rules

- `working`: from a typed message (or the first agent event) to the last agent event before the next typed
  message; a silence longer than `session_gap` (default 30 min) between agent events ends the interval. Computed
  per file, then merged per session (parallel sub-agents are not double counted).
- user time: user actions (typed messages, plus the end of the answer the user replied to within `idle_gap`)
  across all sessions, chained when the gap is at most `idle_gap` (default 20 min).
- days are local days in the top-level `timezone` of config.toml (the older `[notify] timezone` is still read),
  else `TZ` / `/etc/localtime`; every command applies it at start (`Settings.applyTimezone`). The zone the day rows
  were built in is kept in `meta.tz`; a scan in another zone rebuilds all days of the host
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
  status_detail, user_msgs, archived, seq}` for every session with `seq > since` (missing keys = NULL), each followed
  by `{"type":"activity","session_id","kind","start","end"}` lines — the session's complete `working` / `waiting`
  intervals, merged per kind (no overlaps inside a kind): on a `session` line the client drops every interval it
  holds for that session and stores the ones that follow (none = the session has none);
- `{"type":"day","day","host","seq","start","end","rows":[…],"usage":[…],"tools":[…],"user":[…]}` for every
  (local day, host) with a `day_agg` row changed after `since`; `start`/`end` are the server's local day bounds in
  epoch seconds (use them, not the client's time zone). Everything in it replaces what the client holds for that
  day and host:
  - `rows`: the complete `day_agg` rows `{tool, project, model, input, output, cache_read, cache_write, requests,
    tool_calls, session_sec, user_sec}` (meaning as in `day_agg` above; a day emptied by a retraction comes with one
    all-zero totals row);
  - `usage`: `usage_hour` of the day summed over files, one row per `{session_id, agent, hour, model}` with `input,
    output, cache_read, cache_write, requests, tool_calls` (`hour` = UTC hour start, `agent` = "" for the main thread);
  - `tools`: `tool_use` of the day, one row per `{session_id, hour, name}` with `n`;
  - `user`: your-time intervals `{start, end}` clipped to the day (a stretch over midnight comes in both days);
  - the day's totals by agent, tool, hour, session or model are sums over `usage` / `tools`; they equal `rows`;
- `{"type":"limit", tool, window, used_pct, resets_at, window_minutes, ts}` — the latest reading per (tool, window),
  in every export;
- unknown line types and keys must be ignored (the format only grows).

`ExportImport(store:source:)` (`Export/ExportImport.swift`) is the reference client: it applies an export to
another store, keeping imported `usage_hour` / `tool_use` / `activity` rows on one `source_file` row
`export:<source>` (your time as `activity` with `kind = 'user'`, `session_id = ''`), so local ingest never touches
them and `Reports` on that store give the server's numbers. Tested: a full export imported into an empty store gives
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
event names; never prompt text or tool input). A hook line also carries `pid` (`Sys.clientPid()`: the Claude Code /
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

The status line wrapper adds `limits` lines (`five_hour` / `seven_day`) only when the reading changed or a minute
passed for that session (the last one is kept in `spool/.limits-<session>`, removed with spool days); Claude Code
redraws the status line every few seconds and each spool line wakes the daemon. They become `limit_snapshot` rows (an
unchanged reading at most once a minute).

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
