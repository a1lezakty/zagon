# Tasks, worklog plan, Jira

`Sources/ZagonCore/Tasks`, `Worklog`, `Jira`; CLI in `Sources/zagon/Commands/{Task,Log}Command.swift`. Uses the `task*`,
`worklog_plan` tables and `activity.cwd` of schema v4 as they are.

## Registry (`Tasks`)

- Key: own `ZAG-N` (next free number) or external (`PROJ-123`); an external key is also the Jira key unless told
  otherwise. Status `planned | in_progress | review | done` (a stored `open` reads as `planned`). In JSON `status`
  keeps to the three values a zagon before 0.1.1 reads (`review` goes as `in_progress`) and `stage` says `review`.
- The list is built from work (`Tasks.overview`): a line is `worked` when the task has time in the last 7 days, a link
  whose period reaches into them, your Jira worklogs of those days (`JiraCache.logged`), TODO / notes / "what was done"
  of those days or an open TODO, or is an own task (no Jira key) not done before them. `task list` shows those, most
  time first; `--all` adds the rest and your open Jira issues that are no task here (id 0, from `JiraCache`). `task show`
  of such an issue shows it; changing it (`todo`, `note`, `status`, `link`…) makes it a task (`findOrAdopt`).
- TODO (numbered in creation order), notes, "what was done" per day: one text per (day, source), `source` =
  `auto` (summaries) | `manual`; manual wins as the worklog text.
- `task_session` (schema v4): a link has a period `[start, end)` (default the whole session) and `how`:
  `manual` 4 > `commit` = `message` 3 > `branch` = `worktree` = `title` 2; `unlinked` = manual "not this task" for the
  whole session, which also drops the task's other links to that session and keeps automatic ones out. At any moment
  a session's time goes to the strongest links covering it, split equally. The table's key has no `how`, so period
  links of each kind are stored a fraction of a millisecond early by their own amount and never merge across kinds.

## Linking (`TaskLinker`)

Pattern `[A-Z][A-Z0-9]+-\d+` (config `[tasks] key_pattern`; matches are upper-cased, a match glued to a letter or digit
before it is ignored). Only existing tasks are linked (by key or Jira key). A key takes only the working intervals it
is about (of the session and its sub-agents, by the folder of each interval, `activity.cwd`):
- title: the whole session;
- branch the agent recorded (`session.git_branch`): the intervals in the session's folder;
- typed key (`task_key`, written at ingest, no text; works with `index_prompts` off): from the message on through
  the following intervals while no pause is longer than `idle_gap`, until a message with other keys;
- `worktree`: the branch checked out in the interval's folder at that time (checkouts from the folder's HEAD
  reflog; the current branch if there were none);
- commits: your commits (`--author=<repo user.email>`, none without it; all branches; by author time, which a
  rebase keeps) in the repositories where intervals were worked; worktrees of one repository are one group
  (`--git-common-dir`). A commit's keys take the group's intervals since the previous commit, at most 2 h back; the
  day's last commit also 30 min after it. A folder above repositories that is not one itself (`~`, a projects
  folder) counts for the repositories one or two levels below it: agents there commit with `git -C` or full paths.
  Known limits: a session there gets those commits whatever it did (nothing tells which repository it touched);
  an amended or squashed commit keeps its first author time, so work done before the amend is not covered by it.
`linkSessions` rebuilds title/branch/message links, `linkDay` the day's commit/worktree links; manual links are
never touched. `unknownKeys` lists keys in branches, titles and typed messages of the day that match no task (the
plan suggests adding them). A key that is no task but one of your Jira issues (`JiraCache.mine`) becomes a task as its
work is linked (`TaskLinker.Known`); keys of other issues stay unknown. `task_done` with source `auto` is written when a
suggestion is accepted (the AI's worklog text for the day, if the day has none).

## Time (`TaskTime.compute`)

Base: `sessions` (default: wall-clock union of all working intervals, people log the time their agents worked) or
`user` (only your time around your own actions); `--time …` on `task list|show`, `log plan|commit`, or `[worklog] time`.

Time is cut at the edges of every session's cover (working intervals + chained user actions of that session, gap
`idle_gap`) and of its link periods. A piece goes to the linked sessions active in it, one share per session, split
between the tasks linked at that moment; a session with no link there does not dilute the linked ones (the piece is
"no task" only when no linked session is active). On the `user` base, pieces of your time where no session was
active follow the proportions of the rest of the same stretch.
Session time and tokens per task are split the same way. Weekly limit share: growth of `seven_day` (Claude) /
`secondary` (Codex) used % in the range × the task's share of price-weighted tokens of that tool.

## Plan (`WorklogPlanner.plan`, `Worklog.plan`)

Per task: your time − already logged (Jira worklogs on its issue that day + Zagon rows logged/skipped), rounded to
5 min, spread over the stretches it came from (largest remainder; a piece under 15 min moves to the task's biggest
stretch). Inside a stretch each task starts at its first activity
there (earlier free time of the stretch after that), in order of first activity, on a 5-minute grid, only in free time (day − Jira worklogs of any issue − logged/skipped
rows, both widened to the grid). What does not fit goes to the free time nearest to its stretch; if the day is
full it is reported as unplaced. Invariant (tested on random days): no overlap with each other or with busy time.
Text: the day's "what was done" for the task, else the titles of its sessions that day, else the task title.
Rows: `planned` (rebuilt on every plan), `logged` (with `jira_worklog_id`), `skipped`. With Jira connected, every
worklog Jira shows counts as Jira has it (Zagon's own too, also when moved there); logged rows Jira does not show and
skipped rows count as local rows.

## Jira cache (`JiraCache`, Jira/JiraCache.swift)

Jira is a reference, not the task list: `task import` no longer copies the backlog into the registry. `meta`
`jira:issues` keeps your issues (assigned to you, open or updated in the last 30 days: `mine`), the registry's Jira
keys (`key in (…)`, 100 per query; a refused query keeps their last read), and the issues with your worklogs of the
last 7 days (`logged`, by `myWorklogs`: your account and those days only). Read again by `task import` (now: "read
Jira"), and at most once an hour by `task list`, MCP task tools, the day plan and suggestions (`current`; a failed
read is retried after 10 min, only its time is written). On a read, a task whose Jira status changed since the last
read takes it (`TaskStatus(jira:review:)`); on the first read only a task still `planned` or with the status its
category gives. Status mapping: a name with a part of `[jira] review_statuses` (default `review, qa, test, release,
deploy` and Russian `ревью, провер, тест, релиз`; one-line TOML array) is `review` unless Jira counts it done; the rest
by category (`new` → planned, `indeterminate` → in progress, `done` → done). Live 30.10: "Ready to release" and "Ready
to test" are category `new` there, hence the name list.

## Jira (`JiraClient`)

Config `[jira] url, email, token_file` (token = last non-empty line; `~/` expanded; `https` only; plain `http` only to `localhost`, `127.0.0.1` or `[::1]` exactly, for a local mock). curl subprocess, credentials in curl's config
on stdin. Reads: `/rest/api/2/myself`, `/rest/api/3/search/jql` (pages by `nextPageToken`),
`/rest/api/2/issue/<key>`, `/rest/api/2/issue/<key>/worklog` (`startedAfter` is applied client-side too).
Your day = `worklogAuthor = currentUser()` over day±1, then worklogs by your account id that overlap the day.
Write: `addWorklog` (`POST /rest/api/2/issue/<key>/worklog`, `started` in UTC `+0000`) — called only from
`zagon log commit`: it re-scans and re-plans against fresh Jira, shows the rows, asks (or `--yes`), checks each row
against Jira once more and goes on after a failed row (exit 1 at the end). `log plan` / `task show` work without Jira
when it fails (the error is printed); `commit` does not.
Write: `createIssue` (`POST /rest/api/2/issue`: project, the project's Task type — `untranslatedName` "Task", else the
first plain type, from `/rest/api/3/issue/createmeta/<project>/issuetypes` —, summary, description, assignee = you) —
only from `TaskSuggester.createInJira` (below). Also read for that: `/rest/api/3/project/search?action=create`; for
style samples `myTexts`: `/rest/api/2/search/jql` `creator = currentUser()` (plain-text description), your worklog
comments, your comments (`/rest/api/2/issue/<key>/comment`, author = `myself`) on your 8 latest issues.

## Shared flow and MCP

`DayWorklog` (Worklog/DayWorklog.swift) is the one flow behind `zagon log`, MCP and the bot: link the day, read Jira,
plan (`strict` = a Jira failure throws, else the plan is made without Jira), `write` rows. A row planned again
unchanged keeps its id. `TaskViews.swift` holds the data (`TaskListLine`, `TaskCard`) and the text both CLI and MCP print.

`TaskTools` implements `TaskService` (MCP/ServiceTools.swift), wired in `zagon mcp`: `task_list`, `task_get`,
`task_create`, `task_update` (title, description, status, Jira key, note, TODO, TODO done, what was done today),
`worklog_plan` (writes nothing), `worklog_commit` (only with `confirm: true`). The server remembers, per day, the
planned Jira rows its last `worklog_plan` showed (id, task, start, end, Jira key, text). Commit re-plans against fresh
data and writes only if the rows to write are still exactly those (all of them without `ids`, else each given id);
otherwise it writes nothing and returns the new plan to show. No plan shown by this server for the day → refused.
`DayWorklog.write` claims each row (`planned` → `writing`, claim time in `meta` `worklog:claim:<id>`) before the POST,
so two writers at once cannot both write it. Before the POST the issue's own worklog list is read (directly: the
search index behind `myWorklogs` lags a POST by minutes): the same worklog (start to the second, length) there means it
was written before → `logged`, no second POST; an overlap → not written. A 4xx answer or a request that never left
(`JiraError.notSent`) puts the row back to `planned`; a timeout, a lost reply, a 5xx or a failed local update leaves
it `writing`. `settle` (at the start of every plan with Jira and of every write) looks such rows up on their issue:
found → `logged`; not found and the claim older than 5 min → `planned` again; newer → left (may be in flight). Blank fields from MCP or CLI mean "not given".

## Reconcile (`DayWorklog.reconcile`, Worklog/Reconcile.swift)

`zagon log reconcile --from --to [--json|--md|--csv]`, MCP `worklog_reconcile`, the Mac app: your time per task and
day over a range (at most 400 days; days after today are not counted, `to` says the last one) against your worklogs
started in it, matched by Jira key and local day. Links are refreshed once for the range, then `TaskTime.compute` per
day (as `log plan` counts it). Jira is only read: the `worklogAuthor` search a day wider (paged), then each issue's own
worklog list (one request per issue, not per day); the issues of tasks worked in the range and of rows Zagon logged
are read directly too (the search index lags a new worklog). Jira failing or not connected leaves the sessions part,
with `jira` = `failed` / `not_connected`.
Status of a task's day: `only_sessions`, `only_jira`, `mismatch` (apart by more than `[worklog]
reconcile_tolerance_min`, default 15), `match`; over the range a task matches only when every day does. A task with
no Jira key is `zagon_only`, work with no task is `no_task`, a row per project and branch (its time split by each
session's working time that day). `coverage_from`: Claude Code deletes transcripts after `cleanupPeriodDays`, so
history is whole from the earliest end of a Claude session on (no Claude sessions: the first session); earlier days are
not reconciled, their worklogs only sum to `jira_before_coverage_sec`. Totals: `session_sec - jira_sec ==
unlogged_sec - jira_only_sec`. Markdown, CSV (a line per task and day, minutes) and JSON come from `ReconcileText`.

## Suggestions (`TaskSuggester`, Tasks/Suggest.swift)

For work no key linked. Stretches: per session, runs of working time no link covers (pauses up to `idle_gap` join,
linked work between ends a run), 10 min to 2 h of work each (longer work is cut). Candidates (at most 20, best
first): updated in Jira on the day or the next, your Jira worklogs of the 14 days before (recent weigh more), links of
the days before (not of the day itself: work with a key is linked already), in progress, created or updated in those
days. Jira is only read (`myWorklogs`, two searches, `issue?fields=description,comment`), once per day, cached in
`meta` (`suggest:jira:<day>`, `suggest:jira-ctx:<day>`); a Jira failure drops only the Jira part.
Your Jira issues with those signals that are no task here become tasks (hidden: no work) so they can be offered.
One AI call per day with the summary's engine (`[summary] engine, model, timeout`; `DaySummary.complete`: `claude -p
--safe-mode --tools "" …` from `~/.zagon/run` with `ZAGON_INTERNAL=1`, or `codex exec`), also when there is no
candidate, digest ≤ 16 000 characters: samples of your style (`styleSamples`: issues you created — title and the start
of the description —, your worklog comments, your comments; ≤ 3 000 characters, read once per day, `meta`
`suggest:style` keeps the text and the counts), tasks (key, title, status, clipped description, last comment, your
earlier worklog texts) and stretches (time, project, folder, title, first words of up to 3 typed messages, edited file
names, commits). The answer is a JSON array of `{segment, key, confidence, reason, done}` (a task, only when sure) or
`{segment, new, description, done, confidence}` (a new task: title ≤ 70, description ≤ 600 with its lines, worklog text
≤ 300; written in your style, plain without samples); malformed items, keys or stretches not offered and confidence
under `[tasks] suggest_min_confidence` (0.7) are dropped, per stretch the most confident key is kept, else its new
task; new tasks with the same title (case, spaces aside) are one. Engine `none` (or a failed call): the task whose name
shares the most words (6-letter stems of words of 4+) with the session's title, project and folder; 2+ words = 0.7; no
new tasks.
New tasks (`NewTaskDraft`, Tasks/Drafts.swift) are kept in `meta` `suggest:new` (ids `N<n>`, one counter
`suggest:new-seq`), count nowhere and are not asked again (their stretches are asked periods). A stretch any link
covers since is left out; a draft with none left is not shown. Accept (`acceptNew`) → an own task `ZAG-n` (title and
description editable), its stretches linked `manual` for their periods, the worklog text as the day's `auto` "what was
done"; all its time linked meanwhile → dropped. Reject → dropped. `createInJira` (CLI `task accept N3 --create-in-jira
[--project P] [--title …] [--description …]` with y/N or `--yes`, MCP `task_create_in_jira` with `confirm: true`, the
Mac app's sheet) shows the plan first (`jiraPlan`: projects, default = last used `jira:last-project`, else the project
most of your issues are in), creates the issue, then accepts the draft under the new key. A create that may have
reached Jira without an answer leaves `jira:create:N<n>`; the next try first searches your issues of the project made in
the last two days for that exact title and takes it instead of creating a second one; a refused create (4xx, not sent)
clears it. `--again` also drops the day's drafts.
Stored as `task_session.how = 'suggested'` over the stretch (confidence and reason in `meta` `suggest:<day>`); it
counts nowhere (time, plan, Jira keys, worklog text, handoff) until accepted. Accept → `manual` for that period,
unless that time got a link since (links of the day are refreshed first; the suggestion is then dropped; `list` hides
such ones too). Reject → that task is never suggested for that session again (`meta` `suggest:rejected`); its links to the
session stay, also later ones from keys or commits (not `unlinked`, unlike a manual unlink: one "No" must not cost
keyed time). Per stretch the most confident task not rejected is kept. The AI is asked only about work it was not
asked about yet (the asked periods are kept in `suggest:<day>`) that no open suggestion covers, so work going on after
a call, stretches the size limit left out and the rest after a failed call come later; `--again` drops the open ones
and asks about all. Open suggestions whose time got any link since are dropped before each run.
`zagon task suggest [day] [--json] [--again] [--prompt]` (`--json`: the run with its items, drafts, engine, cost, note;
`--prompt` prints what the next call would send: no AI call, nothing stored), `zagon task drafts [--json]`, `zagon task
accept|reject <id…>` (numbers or `N…`), `zagon task jira-projects [--json] [--type-of <KEY>]` (`--type-of`: only the name of the issue
type a new task gets in that project, for the app's create sheet); MCP `task_suggestions`,
`task_suggestions_answer` (`confirm: true`; ids numbers or `"N3"`), `task_create_in_jira`; the evening message at
`[notify] worklog_at` lists them with Yes / No buttons (`sg:y|n:<id>:<task>:<start>`, `sg:y|n:N<n>` for a new task, made
here only, via `Bot.onCallback`; without the bot, the commands instead);
`[tasks] evening_suggestions = false` turns that message off. Known limits: typed messages and edited files come from
Claude transcripts only (Codex sessions: title, folder, commits); your Jira issues not read into `JiraCache` yet are not
offered (the run's note counts them: `zagon task import`); the worklog texts of work linked by keys stay the session
titles (only suggestions carry AI texts); the evening message takes `Notifier.worklogPlan`, so a later worklog
plan message has to be combined with it.

## CLI

`zagon task add|list [--all]|show|todo|note|done|status|link|import|suggest|drafts|accept|reject|jira-projects`, `zagon log plan [day]`, `zagon log commit [day] [--yes]`,
`zagon log skip <id…>`, `zagon log reconcile --from <day> [--to <day>] [--json|--md|--csv]`. `log plan --json` carries `commit_digest` (FNV-1a 64 of `jira_key|start|end|seconds|text`
of the planned rows with a Jira key, by start); `log commit --yes --expect <digest>` re-plans and writes only if the
rows to write give the same digest, else writes nothing and exits 3 ("plan changed"). Days are local (`TZ`).
