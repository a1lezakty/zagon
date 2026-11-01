/// Schema migrations; `PRAGMA user_version` = number of applied entries. Append only, never edit a shipped entry.
enum Schema {
    static let migrations: [String] = [v1, v2, v3, v4, v5, v6, v7]

    /// v7: where a task key came from (`how`): NULL = typed in the message, 'brief' = the title of a brief the
    /// message points to.
    static let v7 = """
    ALTER TABLE task_key ADD COLUMN how TEXT;
    """

    /// v6: the session that typed a session's last typed message (`driver`, NULL = the human): a worker driven over
    /// `tmux send-keys` that waits for input waits for that session, not for you. Filled by the next recount of user
    /// actions (`Ingest.dayRules` 4); a Mac pulls its servers' sessions again to get theirs.
    static let v6 = """
    ALTER TABLE session ADD COLUMN driver TEXT;
    DELETE FROM meta WHERE key LIKE 'remote_seq:%';
    """

    /// v5: cache writes kept for an hour (`cache_write_1h`, part of `cache_write`: priced 2x input instead of 1.25x);
    /// usage by the working directory of each request; points where an agent typed into a terminal (`relay`). Every
    /// tracked file is recounted once (`recount`) to fill them: from the original, else from its archive copy, else
    /// its rows stay as they are (`cwd` '', no 1-hour split).
    static let v5 = """
    CREATE TABLE usage_hour_v5(
      file_id INTEGER NOT NULL, session_id TEXT NOT NULL, agent TEXT NOT NULL, hour INTEGER NOT NULL, model TEXT NOT NULL,
      cwd TEXT NOT NULL DEFAULT '',
      input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0, cache_read INTEGER NOT NULL DEFAULT 0,
      cache_write INTEGER NOT NULL DEFAULT 0, cache_write_1h INTEGER NOT NULL DEFAULT 0,
      requests INTEGER NOT NULL DEFAULT 0, tool_calls INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(file_id, session_id, agent, hour, model, cwd)) WITHOUT ROWID;
    INSERT INTO usage_hour_v5(file_id, session_id, agent, hour, model, input, output, cache_read, cache_write, requests,
      tool_calls)
      SELECT file_id, session_id, agent, hour, model, input, output, cache_read, cache_write, requests, tool_calls
      FROM usage_hour;
    DROP TABLE usage_hour;
    ALTER TABLE usage_hour_v5 RENAME TO usage_hour;
    CREATE INDEX usage_hour_hour ON usage_hour(hour);

    ALTER TABLE msg ADD COLUMN cache_write_1h INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE msg ADD COLUMN cwd TEXT;
    ALTER TABLE day_agg ADD COLUMN cache_write_1h INTEGER NOT NULL DEFAULT 0;

    -- An agent typed into a terminal at ts (`tmux send-keys` to target, '' = unknown target): a message in another
    -- session right after it is not the human's.
    CREATE TABLE relay(file_id INTEGER, session_id TEXT NOT NULL, ts REAL NOT NULL, target TEXT NOT NULL);
    CREATE INDEX relay_ts ON relay(ts);
    CREATE INDEX relay_file ON relay(file_id);

    -- The project of a directory as the machine (host) that recorded it saw it the first time (`Projects.resolve`);
    -- home = 1 for the home directory or /. seq: change counter for export.
    CREATE TABLE dir_project(host TEXT NOT NULL, cwd TEXT NOT NULL, project TEXT NOT NULL, home INTEGER NOT NULL DEFAULT 0,
      seq INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(host, cwd)) WITHOUT ROWID;

    ALTER TABLE source_file ADD COLUMN recount INTEGER NOT NULL DEFAULT 0;
    UPDATE source_file SET recount = 1 WHERE tool <> 'export';
    """

    /// v4: working directory per activity interval; a task link can cover a period of a session; task keys from
    /// typed messages (key only, never the text).
    static let v4 = """
    ALTER TABLE activity ADD COLUMN cwd TEXT;

    -- start/end = the linked period; [0, 1e18) = the whole session (the defaults).
    CREATE TABLE task_session_v4(
      task_id INTEGER NOT NULL REFERENCES task(id) ON DELETE CASCADE, session_id TEXT NOT NULL, how TEXT NOT NULL,
      start REAL NOT NULL DEFAULT 0, "end" REAL NOT NULL DEFAULT 1e18, PRIMARY KEY(task_id, session_id, start));
    INSERT INTO task_session_v4(task_id, session_id, how) SELECT task_id, session_id, how FROM task_session;
    DROP TABLE task_session;
    ALTER TABLE task_session_v4 RENAME TO task_session;
    CREATE INDEX task_session_session ON task_session(session_id, start);

    -- A task key (by `[tasks] key_pattern`) in a message typed at `at`; file_id: retracted with its file.
    CREATE TABLE task_key(
      file_id INTEGER, session_id TEXT NOT NULL, key TEXT NOT NULL, at REAL NOT NULL,
      PRIMARY KEY(session_id, key, at)) WITHOUT ROWID;
    CREATE INDEX task_key_key ON task_key(key);
    CREATE INDEX task_key_file ON task_key(file_id);
    """

    /// v3: what the status is about, e.g. the tool waiting for approval in `waiting_permission`.
    static let v3 = """
    ALTER TABLE session ADD COLUMN status_detail TEXT;
    """

    /// v2: `session.archived` (NULL = unknown); inode lookup for files moved between roots of one tool.
    static let v2 = """
    ALTER TABLE session ADD COLUMN archived INTEGER;
    CREATE INDEX source_file_inode ON source_file(tool, inode);
    """

    static let v1 = """
    CREATE TABLE meta(key TEXT PRIMARY KEY, value) WITHOUT ROWID;

    -- One row per tailed log file. offset = bytes consumed (always at a line start); tail = last bytes before
    -- offset, to detect a file replaced in place. session_id/agent are fixed by the first record of the file.
    CREATE TABLE source_file(
      id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, tool TEXT NOT NULL,
      inode INTEGER NOT NULL DEFAULT 0, size INTEGER NOT NULL DEFAULT 0, offset INTEGER NOT NULL DEFAULT 0,
      mtime REAL, tail BLOB, parser_state TEXT, activity_state TEXT,
      session_id TEXT, agent TEXT NOT NULL DEFAULT '', bad_lines INTEGER NOT NULL DEFAULT 0, resets INTEGER NOT NULL DEFAULT 0);

    CREATE TABLE session(
      id TEXT PRIMARY KEY, tool TEXT NOT NULL, host TEXT, project TEXT, cwd TEXT, git_branch TEXT,
      title TEXT, title_rank INTEGER NOT NULL DEFAULT 0, model TEXT, started_at REAL, last_at REAL,
      status TEXT, status_at REAL, user_msgs INTEGER NOT NULL DEFAULT 0, archive_path TEXT, seq INTEGER NOT NULL DEFAULT 0);
    CREATE INDEX session_last ON session(last_at);

    -- Contributions are keyed by file_id so a truncated/replaced file can be retracted and recounted.
    CREATE TABLE usage_hour(
      file_id INTEGER NOT NULL, session_id TEXT NOT NULL, agent TEXT NOT NULL, hour INTEGER NOT NULL, model TEXT NOT NULL,
      input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0, cache_read INTEGER NOT NULL DEFAULT 0,
      cache_write INTEGER NOT NULL DEFAULT 0, requests INTEGER NOT NULL DEFAULT 0, tool_calls INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(file_id, session_id, agent, hour, model)) WITHOUT ROWID;
    CREATE INDEX usage_hour_hour ON usage_hour(hour);

    CREATE TABLE tool_use(
      file_id INTEGER NOT NULL, session_id TEXT NOT NULL, hour INTEGER NOT NULL, name TEXT NOT NULL, n INTEGER NOT NULL,
      PRIMARY KEY(file_id, session_id, hour, name)) WITHOUT ROWID;
    CREATE INDEX tool_use_hour ON tool_use(hour);

    -- Dedup ledger for requests that carry an id (Claude message.id): 64-bit hash -> what was counted where.
    -- Pruned by hour after `dedup_days`; only numbers, no text.
    CREATE TABLE msg(
      id INTEGER PRIMARY KEY, file_id INTEGER NOT NULL, hour INTEGER NOT NULL, model TEXT NOT NULL,
      input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL,
      calls BLOB);
    CREATE INDEX msg_file ON msg(file_id);
    CREATE INDEX msg_hour ON msg(hour);

    -- Session intervals: kind = 'working' | 'waiting'. file_id NULL = written by hooks.
    CREATE TABLE activity(
      file_id INTEGER, session_id TEXT NOT NULL, start REAL NOT NULL, "end" REAL NOT NULL, kind TEXT NOT NULL);
    CREATE INDEX activity_file ON activity(file_id, session_id, start);
    CREATE INDEX activity_time ON activity(start);
    CREATE INDEX activity_session ON activity(session_id, start);

    -- Points where the human acted: kind = 'msg' (typed a message) | 'read' (end of the answer they replied to).
    CREATE TABLE user_action(file_id INTEGER, session_id TEXT NOT NULL, ts REAL NOT NULL, kind TEXT NOT NULL);
    CREATE INDEX user_action_file ON user_action(file_id);
    CREATE INDEX user_action_ts ON user_action(ts);

    -- Derived: union over all sessions of user actions chained by idle_gap.
    CREATE TABLE user_activity(start REAL NOT NULL, "end" REAL NOT NULL);
    CREATE INDEX user_activity_start ON user_activity(start);

    -- Derived per local day. Rows with model <> '' carry tokens; rows with model = '' carry session_sec of a
    -- (tool, project); the row with tool = project = model = '' carries the day totals session_sec and user_sec.
    CREATE TABLE day_agg(
      day TEXT NOT NULL, host TEXT NOT NULL, tool TEXT NOT NULL, project TEXT NOT NULL, model TEXT NOT NULL,
      input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0, cache_read INTEGER NOT NULL DEFAULT 0,
      cache_write INTEGER NOT NULL DEFAULT 0, requests INTEGER NOT NULL DEFAULT 0, tool_calls INTEGER NOT NULL DEFAULT 0,
      session_sec REAL NOT NULL DEFAULT 0, user_sec REAL NOT NULL DEFAULT 0, seq INTEGER NOT NULL,
      PRIMARY KEY(day, host, tool, project, model)) WITHOUT ROWID;
    CREATE INDEX day_agg_seq ON day_agg(seq);

    CREATE TABLE limit_snapshot(
      tool TEXT NOT NULL, window TEXT NOT NULL, used_pct REAL NOT NULL, resets_at REAL, window_minutes INTEGER,
      ts REAL NOT NULL, PRIMARY KEY(tool, window, ts)) WITHOUT ROWID;

    CREATE TABLE task(
      id INTEGER PRIMARY KEY, key TEXT UNIQUE, title TEXT NOT NULL, description TEXT, status TEXT NOT NULL DEFAULT 'open',
      jira_key TEXT, created REAL NOT NULL, updated REAL NOT NULL);
    CREATE TABLE task_todo(id INTEGER PRIMARY KEY, task_id INTEGER NOT NULL REFERENCES task(id) ON DELETE CASCADE,
      text TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0, created REAL NOT NULL);
    CREATE TABLE task_note(id INTEGER PRIMARY KEY, task_id INTEGER NOT NULL REFERENCES task(id) ON DELETE CASCADE,
      text TEXT NOT NULL, created REAL NOT NULL);
    CREATE TABLE task_done(task_id INTEGER NOT NULL REFERENCES task(id) ON DELETE CASCADE, day TEXT NOT NULL,
      text TEXT NOT NULL, source TEXT NOT NULL, PRIMARY KEY(task_id, day, source));
    CREATE TABLE task_session(task_id INTEGER NOT NULL REFERENCES task(id) ON DELETE CASCADE, session_id TEXT NOT NULL,
      how TEXT NOT NULL, PRIMARY KEY(task_id, session_id));

    CREATE TABLE worklog_plan(
      id INTEGER PRIMARY KEY, day TEXT NOT NULL, task_id INTEGER REFERENCES task(id), start REAL NOT NULL, "end" REAL NOT NULL,
      seconds INTEGER NOT NULL, text TEXT, state TEXT NOT NULL DEFAULT 'planned', jira_worklog_id TEXT);
    CREATE INDEX worklog_plan_day ON worklog_plan(day);

    CREATE TABLE summary(day TEXT NOT NULL, engine TEXT NOT NULL, text TEXT NOT NULL, created REAL NOT NULL,
      PRIMARY KEY(day, engine));
    CREATE TABLE handoff(id TEXT PRIMARY KEY, subject TEXT NOT NULL, created REAL NOT NULL, path TEXT NOT NULL);

    -- Search over session titles and typed messages; contentless: the index holds tokens, not the text.
    CREATE VIRTUAL TABLE fts USING fts5(body, content='', contentless_delete=1);
    CREATE TABLE fts_doc(rowid INTEGER PRIMARY KEY, file_id INTEGER, session_id TEXT NOT NULL, ts REAL, kind TEXT NOT NULL);
    CREATE INDEX fts_doc_file ON fts_doc(file_id);
    CREATE INDEX fts_doc_session ON fts_doc(session_id, kind);
    """
}
