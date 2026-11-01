import Foundation
import Testing
@testable import ZagonCore

/// Cursor's agent: hook lines (`spool/<day>.cursor.ndjson`) and `agent-transcripts`. Shapes from Cursor's docs and
/// from transcripts of Cursor 3.x (keys and tags only; every text here is made up).
@Suite struct CursorTests {
    let t1 = 1778004420.0, t2 = 1778004720.0, t3 = 1778005980.0  // 2026-05-05 18:07, 18:12, 18:33 UTC

    @Test func stamps() {
        let s = CursorTranscriptParser.stamp
        #expect(s("Tuesday, May 5, 2026, 6:07 PM (UTC)") == t1)
        #expect(s("Tuesday, Jun 2, 2026, 9:05 AM (UTC+9)") == 1780358700)   // 00:05 UTC
        #expect(s("Monday, Jun 1, 2026, 12:05 PM (UTC-3)") == 1780326300)  // 15:05 UTC
        #expect(s("Tuesday, Jun 2, 2026, 12:05 AM (UTC)") == 1780358700)
        #expect(s("Tuesday, May 5, 2026, 18:07 (GMT)") == t1)
        #expect(s("Tuesday, May 5, 2026, 11:37 PM (UTC+5:30)") == t1)
        for bad in ["", "Tuesday, May 5, 2026", "Tuesday, Foo 5, 2026, 6:07 PM (UTC)", "Tuesday, May 5, 2026, 13:07 PM (UTC)",
                    "Tuesday, May 5, 2026, 6:07 PM (Europe/Berlin)", "Tuesday, May 5, 2026, 6:07 PM (UTC*2)",
                    // no overflow on any number
                    "Tuesday, May 5, 99999999999999999, 6:07 PM (UTC)", "Tuesday, May 5, -9223372036854775808, 6:07 PM (UTC)",
                    "Tuesday, May 5, 2026, 6:07 PM (UTC+9999999999999999)", "Tuesday, May 5, 2026, 6:07 PM (UTC+5:99)",
                    "Tuesday, May 99999999999999999999, 2026, 6:07 PM (UTC)"] {
            #expect(s(bad) == nil, "\(bad)")
        }
    }

    @Test func layout() {
        #expect(CursorSource.isTranscript("my-app/agent-transcripts/c-1/c-1.jsonl"))
        #expect(!CursorSource.isTranscript("my-app/agent-transcripts/c-1/subagents/s-1.jsonl"))
        #expect(!CursorSource.isTranscript("my-app/agent-transcripts/c-1.txt"))
        #expect(!CursorSource.isTranscript("my-app/uploads/c-1/c-1.jsonl"))
        #expect(CursorSource.isHookFile("2026-05-05.cursor.ndjson"))
        #expect(!CursorSource.isHookFile("2026-05-05.ndjson") && !CursorSource.isHookFile("x/2026-05-05.cursor.ndjson"))
    }

    @Test func slugToFolder() throws {
        let tmp = makeTempDir(), proj = tmp + "/My App.v2/web-ui"
        try FileManager.default.createDirectory(atPath: proj, withIntermediateDirectories: true)
        let real = Sys.realPath(proj) ?? proj
        let slug = String(real.dropFirst().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        #expect(CursorTranscriptParser.folder(ofSlug: slug, home: "/nonexistent") == (real, "web-ui"))
        #expect(CursorTranscriptParser.folder(ofSlug: slug + "-gone-app", home: "/nonexistent") == (nil, "gone-app"))
        #expect(CursorTranscriptParser.folder(ofSlug: "nowhere-at-all", home: "/nonexistent") == (nil, "nowhere-at-all"))
        // A folder macOS guards is not looked into (it would ask the user for access).
        let desk = tmp + "/Desktop/app"
        try FileManager.default.createDirectory(atPath: desk, withIntermediateDirectories: true)
        let deskReal = Sys.realPath(desk) ?? desk
        #expect(CursorTranscriptParser.folder(ofSlug: String(deskReal.dropFirst().map { $0.isLetter || $0.isNumber ? $0 : "-" }),
                                              home: Sys.realPath(tmp) ?? tmp) == (nil, "app"))
        // On macOS not through a link either (it may lead into a guarded folder); elsewhere links are followed.
        _ = symlink(deskReal, tmp + "/link")
        let linkPath = (Sys.realPath(tmp) ?? tmp) + "/link"
        let linkSlug = String(linkPath.dropFirst().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        #if canImport(Darwin)
        #expect(CursorTranscriptParser.folder(ofSlug: linkSlug, home: Sys.realPath(tmp) ?? tmp) == (nil, "link"))
        #else
        #expect(CursorTranscriptParser.folder(ofSlug: linkSlug, home: Sys.realPath(tmp) ?? tmp) == (linkPath, "link"))
        #endif
    }

    /// A transcript as Cursor 3.x writes it: no times except `<timestamp>` before some typed messages.
    func transcript(_ home: String, slug: String = "gone-proj", id: String = "c-1", mtime: Double) throws -> String {
        let dir = home + "/.cursor/projects/\(slug)/agent-transcripts/\(id)"
        try FileManager.default.createDirectory(atPath: dir + "/subagents", withIntermediateDirectories: true)
        func user(_ text: String) -> String { #"{"role":"user","message":{"content":[{"type":"text","text":\#(js(text))}]}}"# }
        let lines = [
            user("<timestamp>Tuesday, May 5, 2026, 6:07 PM (UTC)</timestamp>\n<user_query>\n\nFix PROJ-7 login\nmore words\n</user_query>"),
            #"{"role":"assistant","message":{"content":[{"type":"text","text":"answer"}]}}"#,
            #"{"role":"assistant","message":{"content":[{"type":"tool_use","name":"Shell","input":{"command":"ls"}}]}}"#,
            user("<user_query>no time here PROJ-8</user_query>"),
            user("<attached_files>\n<code_selection path=\"a.swift\">x</code_selection>\n</attached_files>\n<timestamp>Tuesday, May 5, 2026, 6:12 PM (UTC)</timestamp>\n<user_query>next</user_query>"),
            user("<agent_skills>context Cursor adds</agent_skills>"),
            "not json",
            #"{"role":"assistant","message":{"content":"plain"}}"#,
            user("<timestamp>Tuesday, May 5, 2026, 6:33 PM (UTC)</timestamp><user_query>last</user_query>"),
        ]
        let path = dir + "/\(id).jsonl"
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: false, encoding: .utf8)
        try #"{"role":"user","message":{"content":[{"type":"text","text":"<timestamp>Tuesday, May 5, 2026, 6:20 PM (UTC)</timestamp><user_query>sub</user_query>"}]}}"#
            .appending("\n").write(toFile: dir + "/subagents/s-1.jsonl", atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: path)
        return path
    }

    func working(_ s: Store, _ id: String) throws -> [[Double]] {
        var out: [[Double]] = []
        try s.db.query("SELECT start, \"end\" FROM activity WHERE session_id = ? AND kind = 'working' AND \"end\" > start ORDER BY start",
                       [.text(id)]) { out.append([$0.real(0), $0.real(1)]) }
        return out
    }

    @Test func transcriptsGiveApproximateTurns() throws {
        let home = makeTempDir(), paths = ZagonPaths(home: home, dir: home + "/z")
        _ = try transcript(home, mtime: t3 + 300)
        let store = try Store(path: ":memory:")
        let stats = try Ingest(store: store, sources: CursorSource.specs(paths: paths)).scan()
        #expect(stats.badLines == 1)
        // Turns: each stamped message until a second before the next one (at most 10 minutes), the last until the
        // file's last write.
        let w = try working(store, "cursor:c-1")
        #expect(w == [[t1, t2 - 1], [t2, t2 + 600], [t3, t3 + 300]])
        let s = try #require(try store.db.one("SELECT tool, title, project, cwd, user_msgs FROM session WHERE id = 'cursor:c-1'") {
            [$0.text(0), $0.text(1), $0.text(2), $0.text(3), "\($0.int(4))"]
        })
        #expect(s == ["cursor", "Fix PROJ-7 login", "gone-proj", nil, "3"])
        var keys: [String] = []
        try store.db.query("SELECT key FROM task_key WHERE session_id = 'cursor:c-1' ORDER BY at") { keys.append($0.text(0) ?? "") }
        #expect(keys == ["PROJ-7"])  // the message without a time is not placed, so its key is not either
        #expect(try store.db.one("SELECT count(*) FROM session WHERE id LIKE '%s-1%'") { $0.int(0) } == 0)
        #expect(try store.db.one("SELECT sum(session_sec) FROM day_agg WHERE tool = 'cursor'") { $0.real(0) } == 1199)
    }

    @Test func transcriptsStopWhereHooksBegin() throws {
        let home = makeTempDir(), paths = ZagonPaths(home: home, dir: home + "/z")
        let path = try transcript(home, mtime: t3 + 300)
        Sys.mkdirs(paths.dir)
        Sys.append(paths.cursorHooks, Array("\(t3 - 30)\n".utf8))
        let store = try Store(path: ":memory:")
        let ingest = Ingest(store: store, sources: CursorSource.specs(paths: paths))
        try ingest.scan()
        // 18:33 is counted by the hooks: the turn before it has no end, only the earlier one is placed.
        let w = try working(store, "cursor:c-1")
        #expect(w == [[t1, t2 - 1]])
        // Later lines keep the rule (state resumes from the stored offset).
        Sys.append(path, Array(#"{"role":"user","message":{"content":[{"type":"text","text":"<timestamp>Tuesday, May 5, 2026, 7:30 PM (UTC)</timestamp><user_query>x</user_query>"}]}}"#.utf8) + [0x0A])
        try ingest.scan()
        let w2 = try working(store, "cursor:c-1")
        #expect(w2 == [[t1, t2 - 1]])
    }

    func feed(_ paths: ZagonPaths, _ event: String, _ ts: Double, _ extra: String = "") {
        let p = #"{"conversation_id":"c-9","generation_id":"g","model":"gpt-5","hook_event_name":"x","cursor_version":"3.1.0","workspace_roots":["/w/app"],"user_email":null,"transcript_path":null\#(extra)}"#
        HookSpool.append(HookSpool.cursorLine(event: event, payload: Array(p.utf8), ts: ts, keyPattern: IngestOptions.defaultKeyPattern)!,
                         paths: paths, ts: ts, name: ".cursor")
    }

    /// While the answer is written (lines without a time), the last turn grows with the file.
    @Test func lastTurnGrowsWithTheFile() throws {
        let home = makeTempDir(), paths = ZagonPaths(home: home, dir: home + "/z")
        let dir = home + "/.cursor/projects/p/agent-transcripts/c-2"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/c-2.jsonl"
        try (#"{"role":"user","message":{"content":[{"type":"text","text":"<timestamp>Tuesday, May 5, 2026, 6:07 PM (UTC)</timestamp><user_query>go</user_query>"}]}}"# + "\n")
            .write(toFile: path, atomically: false, encoding: .utf8)
        func touch(_ t: Double) throws { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: t)], ofItemAtPath: path) }
        try touch(t1 + 5)
        let store = try Store(path: ":memory:"), ingest = Ingest(store: store, sources: CursorSource.specs(paths: paths))
        try ingest.scan()
        #expect(try working(store, "cursor:c-2") == [[t1, t1 + 5]])
        Sys.append(path, Array(#"{"role":"assistant","message":{"content":[{"type":"text","text":"x"}]}}"#.utf8) + [0x0A])
        try touch(t1 + 200)
        try ingest.scan()
        #expect(try working(store, "cursor:c-2") == [[t1, t1 + 200]])
        Sys.append(path, Array(#"{"role":"assistant","message":{"content":[{"type":"text","text":"y"}]}}"#.utf8) + [0x0A])
        try touch(t1 + 5000)  // reopened much later: the turn keeps its length
        try ingest.scan()
        #expect(try working(store, "cursor:c-2") == [[t1, t1 + 200]])
    }

    @Test func hooksGiveExactTurnsAndStatus() throws {
        let home = makeTempDir(), paths = ZagonPaths(home: home, dir: home + "/z")
        let t = 1778004000.0
        feed(paths, "SessionStart", t - 50, #","session_id":"other-id","composer_mode":"agent""#)
        feed(paths, "UserPromptSubmit", t, #","prompt":"please fix PROJ-4 and proj-5 today","attachments":[]"#)
        feed(paths, "PostToolUse", t + 60, #","tool_name":"Shell","tool_input":{"command":"ls"},"tool_output":"{}","cwd":"/w/app/sub""#)
        feed(paths, "SubagentStop", t + 90, #","duration_ms":20000"#)
        feed(paths, "Stop", t + 120, #","status":"completed","loop_count":0"#)
        feed(paths, "UserPromptSubmit", t + 4000)
        feed(paths, "Stop", t + 4030)
        let store = try Store(path: ":memory:")
        let sources = CursorSource.specs(paths: paths, root: home + "/none")
        try Ingest(store: store, sources: sources).scan()
        try SpoolIngest.run(store: store, spoolDir: paths.spool, now: t + 4100)
        #expect(try working(store, "cursor:c-9") == [[t, t + 120], [t + 4000, t + 4030]])
        let s = try #require(try store.db.one("SELECT tool, model, cwd, project, status, user_msgs FROM session WHERE id = 'cursor:c-9'") {
            [$0.text(0), $0.text(1), $0.text(2), $0.text(3), $0.text(4), "\($0.int(5))"]
        })
        #expect(s == ["cursor", "gpt-5", "/w/app", "app", "waiting_input", "2"])
        // No `sessionEnd` (Cursor mostly quits before it runs): the wait after `stop` ends with the idle time, not at the
        // next prompt an hour later.
        var waits: [[Double]] = []
        try store.db.query("SELECT start, \"end\" FROM activity WHERE session_id = 'cursor:c-9' AND kind = 'waiting' ORDER BY start") {
            waits.append([$0.real(0), $0.real(1)])
        }
        #expect(waits == [[t - 50, t], [t + 120, t + 120 + Query.idleAfter]])
        #expect(try store.db.one("SELECT count(*) FROM session") { $0.int(0) } == 1)
        // The prompt's task keys link the session to its task; its words are not kept.
        #expect(try store.db.one("SELECT group_concat(key) FROM task_key WHERE session_id = 'cursor:c-9'") { $0.text(0) } == "PROJ-4")
        let spool = spoolLines(paths.dir).joined()
        #expect(spool.contains(#""keys":"PROJ-4""#) && !spool.contains("please") && !spool.contains("today"))
        // The daemon reads Cursor's spool files as a source too.
        let d = Daemon(ingest: Ingest(store: store, sources: sources), options: { var o = Daemon.Options(); o.spoolDir = paths.spool; return o }(),
                       log: { _ in })
        feed(paths, "UserPromptSubmit", t + 8000)
        feed(paths, "Stop", t + 8010)
        try d.apply([paths.spool + "/" + Sys.utcDay(t + 8000) + ".cursor.ndjson"])
        #expect(try working(store, "cursor:c-9").last == [t + 8000, t + 8010])
    }

    /// `zagon hook <tool> <event>` with `payload` on stdin, as Cursor runs it.
    func hook(_ paths: ZagonPaths, _ event: String, _ payload: String, tool: String = "claude") {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        let b = Array(payload.utf8)
        _ = b.withUnsafeBytes { write(fds[1], $0.baseAddress, b.count) }
        close(fds[1])
        HookSpool.handleHook(args: [tool, event], stdinFD: fds[0], paths: paths)
        close(fds[0])
    }

    /// Cursor 3's envelope (keys from a live Cursor 3.27; values made up), with the fields that must never be kept.
    func envelope(_ event: String, gen: String, _ extra: String = "") -> String {
        #"{"hook_event_name":"\#(event)","cursor_version":"3.27.22","workspace_roots":["/w/app"],"user_email":"dev@example.com","conversation_id":"c-5","generation_id":"\#(gen)","model":"claude-opus-4-8","model_id":"m-1","model_params":{"effort":"SECRET-PARAM"}\#(extra)}"#
    }

    func tokens(_ i: Int, _ o: Int, _ r: Int, _ w: Int) -> String {
        #","input_tokens":\#(i),"output_tokens":\#(o),"cache_read_tokens":\#(r),"cache_write_tokens":\#(w)"#
    }

    /// Every text value of every table, to look for what must not be stored.
    func dump(_ s: Store) throws -> String {
        var tables: [String] = [], out = ""
        try s.db.query("SELECT name FROM sqlite_master WHERE type = 'table'") { if let n = $0.text(0) { tables.append(n) } }
        for t in tables {
            var n: Int32 = 0
            try s.db.query("PRAGMA table_info(\"\(t)\")") { _ in n += 1 }
            try s.db.query("SELECT * FROM \"\(t)\"") { r in for i in 0..<n { out += (r.text(i) ?? "") + "\n" } }
        }
        return out
    }

    /// Tokens of `stop` (from `~/.claude/settings.json`: `zagon hook claude Stop`) and `afterAgentResponse` (only from
    /// Cursor's own hooks.json): one generation counts its largest report, never the sum; no price; no text, e-mail or
    /// tool input / output anywhere.
    @Test func hookTokensWithoutPriceOrText() throws {
        let home = makeTempDir(), paths = ZagonPaths(home: home, dir: home + "/z")
        let secrets = #","prompt":"SECRET-PROMPT for PROJ-3","text":"SECRET-TEXT","tool_input":{"command":"SECRET-INPUT"},"tool_output":"SECRET-OUTPUT""#
        hook(paths, "SessionStart", envelope("sessionStart", gen: "g-0", #","session_id":"s-77","transcript_path":null,"composer_mode":"agent","is_background_agent":false"#))
        hook(paths, "UserPromptSubmit", envelope("beforeSubmitPrompt", gen: "g-1", secrets))
        hook(paths, "PostToolUse", envelope("postToolUse", gen: "g-1", #","tool_name":"Shell","duration_ms":12"# + secrets))
        hook(paths, "afterAgentResponse", envelope("afterAgentResponse", gen: "g-1", tokens(1000, 300, 5000, 700) + secrets), tool: "cursor")
        // The parser's state carries a generation over to the next pass.
        let store = try Store(path: ":memory:"), ingest = Ingest(store: store, sources: CursorSource.specs(paths: paths, root: home + "/none"))
        try ingest.scan()
        hook(paths, "Stop", envelope("stop", gen: "g-1", #","status":"completed","loop_count":0"# + tokens(1200, 300, 5000, 700)))
        hook(paths, "Stop", envelope("stop", gen: "g-2", tokens(100, 50, 0, 0)))
        hook(paths, "afterAgentResponse", envelope("afterAgentResponse", gen: "g-2", tokens(100, 50, 0, 0)), tool: "cursor")
        hook(paths, "Stop", envelope("stop", gen: "g-3", #","input_tokens":"x""#))  // no number: no tokens
        // Without a generation id reports add up.
        hook(paths, "Stop", envelope("stop", gen: "", tokens(10, 0, 0, 0)))
        hook(paths, "Stop", envelope("stop", gen: "", tokens(10, 0, 0, 0)))
        let lines = spoolLines(paths.dir)
        #expect(lines.count == 10)
        let first = try #require(lines.first.flatMap { JValue.parse($0) })
        #expect(first["session_id"]?.string == "c-5" && first["composer_mode"] == nil && first["generation_id"]?.string == "g-0")
        let spool = lines.joined()
        #expect(!spool.contains("SECRET") && !spool.contains("example.com") && !spool.contains("for PROJ"))
        #expect(spool.contains(#""keys":"PROJ-3""#) && spool.contains(#""cache_write_tokens":700"#))

        try ingest.scan()
        try SpoolIngest.run(store: store, spoolDir: paths.spool)
        let u = try #require(try store.db.one("""
            SELECT sum(input), sum(output), sum(cache_read), sum(cache_write), group_concat(DISTINCT model), group_concat(DISTINCT session_id)
            FROM usage_hour
            """) { [$0.int(0), $0.int(1), $0.int(2), $0.int(3)].map(String.init) + [$0.text(4) ?? "", $0.text(5) ?? ""] })
        #expect(u == ["1320", "350", "5000", "700", "cursor/claude-opus-4-8", "cursor:c-5"])
        // Cursor's own prices are unknown: none, also for a model the price table knows.
        #expect(Pricing.rates("claude-opus-4-8") != nil && Pricing.rates("cursor/claude-opus-4-8") == nil)
        let line = try #require(try Reports(store: store).sessions(from: 0, to: 4e9).first { $0.id == "cursor:c-5" })
        #expect(line.cost == 0 && line.unpriced == 1320 + 350 + 5000 + 700)
        #expect(try store.db.one("SELECT status FROM session WHERE id = 'cursor:c-5'") { $0.text(0) } == "waiting_input")
        let db = try dump(store)
        #expect(!db.contains("SECRET") && !db.contains("example.com") && db.contains("PROJ-3"))
    }

    /// Cursor 3's own database, made up: `composerHeaders` beside tables Zagon never opens.
    func cursorDatabase(_ user: String, _ rows: [(id: String, ws: String, created: Double, updated: Double, sub: Int, value: String)]) throws {
        for (ws, json) in [("ws-local", #"{"folder":"file:///Users/dev/My%20App"}"#),
                           ("ws-remote", #"{"folder":"vscode-remote://ssh-remote%2Bbuild-box/srv/app"}"#),
                           ("ws-multi", #"{"workspace":"file:///Users/dev/all.code-workspace"}"#)] {
            try FileManager.default.createDirectory(atPath: user + "/workspaceStorage/" + ws, withIntermediateDirectories: true)
            try json.write(toFile: user + "/workspaceStorage/\(ws)/workspace.json", atomically: false, encoding: .utf8)
        }
        try FileManager.default.createDirectory(atPath: user + "/globalStorage", withIntermediateDirectories: true)
        let db = try SQLite(path: user + "/globalStorage/state.vscdb")
        try db.exec("""
            CREATE TABLE IF NOT EXISTS ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
            INSERT INTO ItemTable VALUES('cursorAuth/accessToken', 'SECRET-TOKEN');
            CREATE TABLE IF NOT EXISTS cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
            INSERT INTO cursorDiskKV VALUES('bubbleId:h-1:b-1', '{"text":"SECRET-BUBBLE"}');
            DROP TABLE IF EXISTS composerHeaders;
            CREATE TABLE composerHeaders(composerId TEXT PRIMARY KEY, workspaceId TEXT, createdAt INTEGER, lastUpdatedAt INTEGER,
              isArchived INTEGER, isSubagent INTEGER, recency REAL, checkpointAt INTEGER, subagentTypeName TEXT, value TEXT);
            """)
        for r in rows {
            _ = try db.run("INSERT INTO composerHeaders VALUES(?, ?, ?, ?, 0, ?, 0, 0, NULL, ?)",
                           [.text(r.id), .text(r.ws), .int(Int64(r.created * 1000)), .int(Int64(r.updated * 1000)), .int(Int64(r.sub)),
                            .text(r.value)])
        }
    }

    /// Cursor 3 history: rough turns from `composerHeaders` (read-only), local conversations only, before the hooks.
    @Test func historyFromConversationHeaders() throws {
        let home = makeTempDir(), paths = ZagonPaths(home: home, dir: home + "/z"), user = home + "/CursorUser"
        let since = t3 + 5000, d = 86400.0
        _ = try transcript(home, mtime: t3 + 300)  // c-1: Cursor 2.x left its transcript, counted from it
        Sys.mkdirs(paths.dir)
        Sys.append(paths.cursorHooks, Array("\(since)\n".utf8))
        func named(_ n: String) -> String { #"{"name":"\#(n)","subtitle":"SECRET-SUBTITLE","filesChangedCount":2}"# }
        var rows: [(id: String, ws: String, created: Double, updated: Double, sub: Int, value: String)] = [
                    ("h-1", "ws-local", t1 - d, t1 - d + 300, 0, named("Fix login")),
                    ("h-2", "ws-local", t1 - 2 * d, t1 - 2 * d + 3600, 0, named("Long one")),   // over 30 min: no length
                    ("h-3", "ws-remote", t1 - d, t1 - d + 60, 0, named("Remote")),              // the server counts it
                    ("h-4", "ws-gone", t1 - d, t1 - d + 60, 0, named("Unknown")),
                    ("h-5", "ws-local", t1 - d, t1 - d + 60, 1, named("Sub-agent")),
                    ("h-6", "ws-multi", t3, t3 + 1200, 0, "not json"),                           // capped at 10 min
                    ("h-7", "ws-local", since + 100, since + 400, 0, named("After hooks")),      // the hooks count it
                    ("c-1", "ws-local", t1, t3 + 300, 0, named("Has a transcript"))]
        try cursorDatabase(user, rows)
        let store = try Store(path: ":memory:"), ingest = Ingest(store: store, sources: CursorSource.specs(paths: paths))
        try ingest.scan()
        let cursorFiles = Sys.listDir(user + "/globalStorage").sorted(), cursorDB = Sys.readFile(user + "/globalStorage/state.vscdb")
        #expect(CursorHeaders.sync(store: store, paths: paths, user: user, now: 1000))
        try ingest.update(paths: [CursorHeaders.file(paths)])
        // Cursor's database is only read: no new file beside it, not a byte changed.
        #expect(Sys.listDir(user + "/globalStorage").sorted() == cursorFiles && Sys.readFile(user + "/globalStorage/state.vscdb") == cursorDB)

        let file = try #require(Sys.readFile(CursorHeaders.file(paths)).map { String(decoding: $0, as: UTF8.self) })
        #expect(file.split(separator: "\n").compactMap { JValue.parse(String($0))?["id"]?.string } == ["h-2", "h-1", "h-6", "h-7"])
        #expect(try !file.contains("SECRET") && !dump(store).contains("SECRET"))
        func row(_ id: String) throws -> [String?]? {
            try store.db.one("SELECT title, cwd, project, user_msgs FROM session WHERE id = ?", [.text("cursor:" + id)]) {
                [$0.text(0), $0.text(1), $0.text(2), "\($0.int(3))"]
            }
        }
        #expect(try row("h-1") == ["Fix login", "/Users/dev/My App", "My App", "1"])
        #expect(try working(store, "cursor:h-1") == [[t1 - d, t1 - d + 300]])
        #expect(try row("h-2") == ["Long one", "/Users/dev/My App", "My App", "1"] && working(store, "cursor:h-2").isEmpty)
        #expect(try row("h-6") == [nil, nil, nil, "1"] && working(store, "cursor:h-6") == [[t3, t3 + 600]])
        #expect(try row("h-7") == ["After hooks", "/Users/dev/My App", "My App", "0"] && working(store, "cursor:h-7").isEmpty)
        for gone in ["h-3", "h-4", "h-5"] { #expect(try row(gone) == nil, "\(gone)") }
        #expect(try row("c-1")?.first == "Fix PROJ-7 login")
        #expect(try working(store, "cursor:c-1") == [[t1, t2 - 1], [t2, t2 + 600], [t3, t3 + 300]])

        // Read at most every 5 minutes; an unchanged list leaves the file alone; a changed one is counted anew, not added.
        rows[0].updated = t1 - d + 500
        try cursorDatabase(user, rows)
        #expect(!CursorHeaders.sync(store: store, paths: paths, user: user, now: 1100))
        #expect(CursorHeaders.sync(store: store, paths: paths, user: user, now: 1400))
        try ingest.update(paths: [CursorHeaders.file(paths)])
        #expect(try working(store, "cursor:h-1") == [[t1 - d, t1 - d + 500]])
        #expect(try row("h-1")?.last == "1")
        #expect(!CursorHeaders.sync(store: store, paths: paths, user: user, now: 1800))
        // A new conversation at the end is appended (the same file: Ingest reads just it).
        func inode() -> UInt64? { (try? FileManager.default.attributesOfItem(atPath: CursorHeaders.file(paths)))?[.systemFileNumber] as? UInt64 }
        let ino = inode()
        rows.append(("h-8", "ws-local", since + 300, since + 400, 0, named("Newest")))
        try cursorDatabase(user, rows)
        #expect(CursorHeaders.sync(store: store, paths: paths, user: user, now: 2200))
        #expect(inode() == ino)
        try ingest.update(paths: [CursorHeaders.file(paths)])
        #expect(try row("h-8")?.first == "Newest" && working(store, "cursor:h-1") == [[t1 - d, t1 - d + 500]])
        // A conversation Cursor dropped from its list, or whose workspace is gone, keeps its time; a table in another
        // format changes nothing.
        rows.removeAll { $0.id == "h-1" }
        try cursorDatabase(user, rows)
        Sys.remove(user + "/workspaceStorage/ws-multi/workspace.json")
        CursorHeaders.sync(store: store, paths: paths, user: user, now: 2600)
        try ingest.update(paths: [CursorHeaders.file(paths)])
        #expect(try working(store, "cursor:h-6") == [[t3, t3 + 600]] && working(store, "cursor:h-1") == [[t1 - d, t1 - d + 500]])
        #expect(try row("h-1")?.last == "1")
        let kept = Sys.readFile(CursorHeaders.file(paths))
        _ = try SQLite(path: user + "/globalStorage/state.vscdb").run("DROP TABLE composerHeaders")
        #expect(!CursorHeaders.sync(store: store, paths: paths, user: user, now: 3000))
        #expect(Sys.readFile(CursorHeaders.file(paths)) == kept)
        // No Cursor here: nothing written.
        #expect(!CursorHeaders.sync(store: store, paths: ZagonPaths(home: home, dir: home + "/z2"), user: home + "/none", now: 1800))
        #expect(!Sys.exists(home + "/z2/cursor"))
    }

    /// Hooks that begin after a conversation was synced: its turn before them stays, and the file stops following it.
    @Test func headersBeforeAndAfterTheHooks() throws {
        let home = makeTempDir(), paths = ZagonPaths(home: home, dir: home + "/z"), user = home + "/CursorUser"
        try cursorDatabase(user, [("h-9", "ws-local", t1, t1 + 300, 0, #"{"name":"Ongoing"}"#)])
        let store = try Store(path: ":memory:"), ingest = Ingest(store: store, sources: CursorSource.specs(paths: paths))
        #expect(CursorHeaders.sync(store: store, paths: paths, user: user, now: 1000))
        try ingest.update(paths: [CursorHeaders.file(paths)])
        #expect(try working(store, "cursor:h-9") == [[t1, t1 + 300]])
        Sys.mkdirs(paths.dir)
        Sys.append(paths.cursorHooks, Array("\(t1 + 1000)\n".utf8))
        try cursorDatabase(user, [("h-9", "ws-local", t1, t1 + 5000, 0, #"{"name":"Ongoing"}"#)])
        #expect(CursorHeaders.sync(store: store, paths: paths, user: user, now: 1400))
        try ingest.update(paths: [CursorHeaders.file(paths)])
        let file = Sys.readFile(CursorHeaders.file(paths)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(JValue.parse(String(file.split(separator: "\n").first ?? ""))?["updated"]?.double == t1 + 999)
        #expect(try working(store, "cursor:h-9") == [[t1, t1 + 600]])
        // Later turns change nothing in the file.
        try cursorDatabase(user, [("h-9", "ws-local", t1, t1 + 9000, 0, #"{"name":"Ongoing"}"#)])
        #expect(!CursorHeaders.sync(store: store, paths: paths, user: user, now: 1800))
    }
}
