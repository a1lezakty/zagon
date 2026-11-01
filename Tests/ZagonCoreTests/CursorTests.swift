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
}
