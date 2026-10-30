import Foundation
import Testing
@testable import ZagonCore

@Suite struct SchemaV4Tests {
    // MARK: cwd per interval

    @Test func aNewDirectoryInsideATurnSplitsTheInterval() {
        var b = TurnBuilder(), out = TurnBuilder.Output()
        b.user("s", T0, cwd: "/a", idleGap: 1200, into: &out)
        b.agent("s", T0 + 60, cwd: "/a", sessionGap: 1800, into: &out)
        b.agent("s", T0 + 120, cwd: "/b", sessionGap: 1800, into: &out)
        b.agent("s", T0 + 180, cwd: "/b", sessionGap: 1800, into: &out)
        #expect(out.closed.count == 1)
        #expect(out.closed.first?.interval == Interval(T0, T0 + 60) && out.closed.first?.cwd == "/a")
        #expect(b.open["s"] == Interval(T0 + 60, T0 + 180) && b.cwd(of: "s") == "/b")  // contiguous: no time lost
        // Events without a directory keep the current one.
        b.agent("s", T0 + 240, sessionGap: 1800, into: &out)
        #expect(out.closed.count == 1 && b.cwd(of: "s") == "/b")
    }

    @Test func oldTurnStateWithoutDirectoriesStillDecodes() throws {
        let old = #"{"open":{"s":{"start":1,"end":2}}}"#
        let b = try JSONDecoder().decode(TurnBuilder.self, from: Data(old.utf8))
        #expect(b.open["s"] == Interval(1, 2) && b.cwd(of: "s") == nil)
    }

    @Test func subAgentIntervalsCarryTheirOwnDirectory() {
        let env = ClaudeEnv()
        env.write(mainFile, lines: [typed(T0), assistantLine(T0 + minute, id: "m1", output: 1)])
        env.write("-w-alpha/S/subagents/agent-x.jsonl",
                  lines: [userLine(T0 + 2 * minute, content: js("go"), cwd: "/w/alpha-wt"),
                          assistantLine(T0 + 5 * minute, id: "m2", output: 1, cwd: "/w/alpha-wt")])
        env.scan()
        let rows = try! env.store.db.one("""
            SELECT group_concat(cwd, ',') FROM (SELECT DISTINCT cwd FROM activity WHERE kind = 'working' ORDER BY cwd)
            """) { $0.text(0) } ?? nil
        #expect(rows == "/w/alpha,/w/alpha-wt")
    }

    @Test func codexEventsCarryTheTurnDirectory() {
        var p = CodexParser(relativePath: "2026/10/30/rollout-2026-10-30T10-00-00-00000000-0000-4000-8000-000000000001.jsonl", state: nil)
        var out = ParseOutput()
        for l in [#"{"timestamp":"2026-10-30T10:00:00.000Z","type":"session_meta","payload":{"id":"s1","cwd":"/w1"}}"#,
                  #"{"timestamp":"2026-10-30T10:00:01.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}"#,
                  #"{"timestamp":"2026-10-30T10:00:02.000Z","type":"turn_context","payload":{"cwd":"/w2","model":"gpt-5"}}"#,
                  #"{"timestamp":"2026-10-30T10:00:03.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}"#] {
            var s = l
            s.withUTF8 { p.parse(line: UnsafeRawBufferPointer($0), into: &out) }
        }
        #expect(out.events.map(\.cwd) == ["/w1", "/w2"])
    }

    // MARK: task keys

    func keys(_ env: ClaudeEnv) -> [String] {
        var out: [String] = []
        try! env.store.db.query("SELECT key FROM task_key ORDER BY at, key") { out.append($0.text(0) ?? "") }
        return out
    }

    @Test func taskKeysComeFromTypedMessagesEvenWithoutIndexing() {
        let env = ClaudeEnv { $0.indexPrompts = false }
        env.write(mainFile, lines: [typed(T0, "fix PROJ-12 and OPS-7, not fooPROJ-9; PROJ-12 again"),
                                    assistantLine(T0 + minute, id: "m1", output: 1),
                                    toolResult(T0 + 2 * minute),  // not typed: never a key source
                                    typed(T0 + 3 * minute, "then PROJ-3")])
        env.scan()
        #expect(keys(env) == ["OPS-7", "PROJ-12", "PROJ-3"])
        #expect(env.int("SELECT count(*) FROM fts_doc") == 0)  // nothing indexed, no text kept
        // A truncated file takes its keys back.
        env.write(mainFile, lines: [typed(T0, "only PROJ-1")])
        env.scan()
        #expect(keys(env) == ["PROJ-1"])
    }

    @Test func keyPatternIsConfigurableAndCanBeOff() {
        let custom = ClaudeEnv { $0.keyPattern = #"(?i)[a-z]+-\d+"# }
        custom.write(mainFile, lines: [typed(T0, "see proj-5")])
        custom.scan()
        #expect(keys(custom) == ["PROJ-5"])
        let off = ClaudeEnv { $0.keyPattern = nil }
        off.write(mainFile, lines: [typed(T0, "see PROJ-5")])
        off.scan()
        #expect(keys(off).isEmpty)
    }

    // MARK: task_session periods

    @Test func taskLinksCoverAPeriodOrTheWholeSession() throws {
        let s = try Store(path: ":memory:")
        try s.db.run("INSERT INTO task(id, title, created, updated) VALUES(1, 't', 0, 0)")
        try s.db.run("INSERT INTO task_session(task_id, session_id, how) VALUES(1, 'claude:a', 'manual')")
        #expect(try s.db.one("SELECT start, \"end\" FROM task_session") { [$0.real(0), $0.real(1)] } == [0, 1e18])
        try s.db.run("INSERT INTO task_session(task_id, session_id, how, start, \"end\") VALUES(1, 'claude:b', 'message', 100, 200)")
        try s.db.run("INSERT INTO task_session(task_id, session_id, how, start, \"end\") VALUES(1, 'claude:b', 'message', 500, 600)")
        #expect(try s.db.one("SELECT count(*) FROM task_session WHERE session_id = 'claude:b'") { $0.int(0) } == 2)
        // Which links cover a moment: one query, no special case for whole-session links.
        #expect(try s.db.one("SELECT count(*) FROM task_session WHERE start <= 550 AND \"end\" > 550") { $0.int(0) } == 2)
    }

    @Test func migrationFromV3KeepsLinksAsWholeSession() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        do {  // a v3 database with a link and an interval
            let db = try SQLite(path: dir + "/z.db")
            for sql in Schema.migrations.prefix(3) { try db.exec(sql) }
            try db.exec("PRAGMA user_version=3")
            try db.run("INSERT INTO task(id, title, created, updated) VALUES(1, 't', 0, 0)")
            try db.run("INSERT INTO task_session(task_id, session_id, how) VALUES(1, 'claude:a', 'branch')")
            try db.run("INSERT INTO activity(file_id, session_id, start, \"end\", kind) VALUES(1, 'claude:a', 1, 2, 'working')")
        }
        let s = try Store(path: dir + "/z.db")
        #expect(s.userVersion == 4)
        #expect(try s.db.one("SELECT task_id, session_id, how, start, \"end\" FROM task_session") {
            "\($0.int(0)) \($0.text(1)!) \($0.text(2)!) \($0.real(3)) \($0.real(4))"
        } == "1 claude:a branch 0.0 1e+18")
        #expect(try s.db.one("SELECT cwd FROM activity") { $0.text(0) } == .some(nil))
    }

    // MARK: time zone

    @Test func timezoneTopLevelWinsOverTheOldNotifyKey() {
        #expect(Settings.timezone(in: "timezone = \"Asia/Tokyo\"\n[notify]\ntimezone = \"Europe/Moscow\"\n") == "Asia/Tokyo")
        #expect(Settings.timezone(in: "[notify]\ntimezone = \"Europe/Moscow\"\n") == "Europe/Moscow")
        #expect(Settings.timezone(in: "timezone = \"\"\n[ntfy]\ntopic = \"x\"\n") == nil)
        #expect(NotifyConfig.parse("timezone = \"Asia/Tokyo\"\n", home: "/h").timezone == "Asia/Tokyo")
    }

    @Test func anotherZoneRebuildsEveryDay() throws {
        let env = ClaudeEnv()
        env.write(mainFile, lines: [typed(T0), assistantLine(T0 + minute, id: "m1", input: 10, output: 1)])
        env.scan()
        let seq0 = env.int("SELECT max(seq) FROM day_agg")
        try env.ingest.checkTimezone("TZ=Somewhere/Else")
        #expect(env.int("SELECT count(*) FROM day_agg") == 0)
        try env.ingest.finish()
        #expect(env.int("SELECT max(seq) FROM day_agg") > seq0)
        #expect(env.int("SELECT sum(input) FROM day_agg WHERE model <> ''") == 10)
        try env.ingest.checkTimezone("TZ=Somewhere/Else")  // same zone: nothing to do
        #expect(env.int("SELECT count(*) FROM day_agg") > 0)
    }
}
