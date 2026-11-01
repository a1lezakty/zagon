import Foundation
import Testing
@testable import ZagonCore

/// Where a task key of a session may come from: what you typed and the brief it points to; never what the harness adds
/// (memory, CLAUDE.md in `<system-reminder>`), never a pasted worklog list; only keys of known projects.
@Suite struct TaskKeySourceTests {
    func keys(_ env: ClaudeEnv, _ session: String) -> [String] {
        var out: [String] = []
        try! env.store.db.query("SELECT key, coalesce(how, 'message') FROM task_key WHERE session_id = ? ORDER BY key",
                                [.text("claude:" + session)]) { out.append("\($0.text(0)!) \($0.text(1)!)") }
        return out.filter { $0.hasPrefix("PROJ-") || $0.hasPrefix("OPS-") }  // not the random parts of temp paths (`A17E-1`)
    }

    @Test func remindersAndWorklogListsGiveNoKeys() {
        let env = ClaudeEnv()
        env.write("-w-alpha/A.jsonl", lines: [
            typed(T0, "PROJ-1: fix it\n<system-reminder>memory: PROJ-9 notes</system-reminder>\nthen OPS-3", session: "A"),
            typed(T0 + 2 * hour, "go on <system-reminder>CLAUDE.md says PROJ-8 and never closes", session: "A")])
        env.write("-w-alpha/B.jsonl", lines: [typed(T0, """
            logged today:
            1. PROJ-718, 09:00–10:15 (1 h 15 m) — stand
            2. PROJ-670 9:00-10:15 build
            3. PROJ-671, 11:00 — 12:30
            and now PROJ-5 please
            """, session: "B")])
        env.scan()
        #expect(keys(env, "A") == ["OPS-3 message", "PROJ-1 message"])
        #expect(keys(env, "B") == ["PROJ-5 message"])
        #expect(Ingest.typedText("a<system-reminder>x</system-reminder>b<system-reminder>y") == "ab")
    }

    @Test func aBriefGivesItsTitleAndNameKeysNotItsBody() throws {
        let home = tempDir()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let env = ClaudeEnv { $0.home = home }
        let dir = env.root + "/briefs"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "\n  \n# PROJ-7: which codecs\nSteps as in BRIEF-2, see EN-150 and PROJ-8.\n".write(toFile: dir + "/BRIEF.md", atomically: true, encoding: .utf8)
        try "plan\nPROJ-9 is only cited here\n".write(toFile: dir + "/PROJ-4-notes.txt", atomically: true, encoding: .utf8)
        try "# PROJ-6\n".write(toFile: dir + "/code.swift", atomically: true, encoding: .utf8)          // not a brief type
        try "# PROJ-5\n".write(toFile: home + "/plan.md", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: dir + "/PROJ-3.md", withIntermediateDirectories: true)  // a folder
        try ("# PROJ-2\n" + String(repeating: "x", count: Ingest.briefMax)).write(toFile: dir + "/big.md", atomically: true, encoding: .utf8)
        env.write("-w-alpha/A.jsonl", lines: [typed(T0, "read \(dir)/BRIEF.md and do it", session: "A")])
        env.write("-w-alpha/B.jsonl", lines: [typed(T0, "PROJ-7 again: `\(dir)/BRIEF.md`, also \(dir)/PROJ-4-notes.txt.", session: "B")])
        env.write("-w-alpha/C.jsonl", lines: [typed(T0, "see ~/plan.md, \(dir)/code.swift, \(dir)/PROJ-3.md, \(dir)/big.md, /nowhere/PROJ-1.md",
                                                    session: "C")])
        env.write("-w-alpha/D.jsonl", lines: [typed(T0, "ok <system-reminder>read \(dir)/BRIEF.md</system-reminder>", session: "D")])
        env.scan()
        #expect(keys(env, "A") == ["PROJ-7 brief"])
        // Typed and in the brief at once: typed; a key in a typed path is typed.
        #expect(keys(env, "B") == ["PROJ-4 message", "PROJ-7 message"])
        #expect(keys(env, "C") == ["PROJ-1 message", "PROJ-3 message", "PROJ-5 brief"])
        #expect(keys(env, "D") == [])

        // The brief's key links like a typed one, as `brief`.
        env.write("-w-alpha/A.jsonl", lines: [typed(T0, "read \(dir)/BRIEF.md and do it", session: "A"),
                                              assistantLine(T0 + 10 * minute, id: "a1", output: 1, session: "A")])
        env.scan()
        let t = Tasks(store: env.store), p7 = try t.add(title: "codecs", key: "PROJ-7")
        try TaskLinker().linkSessions(env.store)
        #expect(try t.links(p7.id).map { "\($0.sessionId) \($0.how)" }.sorted() == ["claude:A brief", "claude:B message"])
        #expect(try t.linkMap().tasks("claude:A", at: T0 + 5 * minute).map(\.task) == [p7.id])
    }

    @Test func onlyKeysOfKnownProjectsCount() throws {
        let f = try Fixture(), t = Tasks(store: f.store)
        _ = try t.add(title: "own")                                                    // ZAG-1: own project
        try f.session("claude:a", branch: "BRIEF-2-x", working: [(D0 + 9 * H, D0 + 10 * H)])
        try f.message("claude:a", D0 + 9 * H, keys: ["EN-150", "PROJ-99", "OPS-5", "ZAG-7"])
        func unknown(_ l: TaskLinker = try! TaskLinker()) throws -> [String] {
            try l.unknownKeys(f.store, from: D0, to: D0 + 86400).keys.sorted()
        }
        // No Jira: every match, as before.
        #expect(try unknown() == ["BRIEF-2", "EN-150", "OPS-5", "PROJ-99", "ZAG-7"])
        var c = JiraCache()
        c.at = D0; c.projects = ["PROJ"]
        c.issues["PROJ-99"] = JiraIssue(key: "PROJ-99", summary: "yours", status: "To Do", statusCategory: "new")
        c.mine = ["PROJ-99"]
        try c.save(f.store, tried: D0)
        #expect(JiraCache.load(f.store).projects == ["PROJ"])
        #expect(try unknown() == ["PROJ-99", "ZAG-7"])                               // Jira's and the registry's projects
        var l = try TaskLinker()
        l.projects = ["ops"]
        #expect(try unknown(l) == ["OPS-5", "PROJ-99", "ZAG-7"])
        // Linking: a Jira issue of a known project becomes a task; the rest give nothing.
        try l.linkSessions(f.store)
        #expect(try t.find("PROJ-99") != nil && t.find("EN-150") == nil)
        #expect(try unknown(l) == ["OPS-5", "ZAG-7"])
        #expect(TaskLinker.allowed("FOO", ["PROJ"]) && TaskLinker.allowed("FOO-1", nil) && !TaskLinker.allowed("FOO-1", ["PROJ"]))
    }

    @Test func aV6DatabaseKeepsItsTypedKeys() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        do {
            let db = try SQLite(path: dir + "/z.db")
            for sql in Schema.migrations.prefix(6) { try db.exec(sql) }
            try db.exec("PRAGMA user_version=6")
            try db.run("INSERT INTO task_key(file_id, session_id, key, at) VALUES(1, 'claude:a', 'PROJ-1', 100)")
        }
        let s = try Store(path: dir + "/z.db")
        #expect(s.userVersion == Schema.migrations.count && Schema.migrations.count == 7)
        #expect(try s.db.one("SELECT session_id || ' ' || key || ' ' || at || ' ' || coalesce(how, 'NULL') FROM task_key") { $0.text(0) }
                == "claude:a PROJ-1 100.0 NULL")
    }
}

@Suite(.enabled(if: hasTool("python3") && hasTool("curl"), "needs python3 and curl"), .timeLimit(.minutes(1)))
struct JiraProjectsTests {
    static func state(fails: Bool) -> String {
        """
        {"me": "acc-me", "browse_fails": \(fails), "projects": [{"key": "PROJ", "name": "P"}, {"key": "OPS", "name": "O"}],
         "issues": {"PROJ-1": {"summary": "s", "status": "To Do", "category": "new", "assignee": "acc-me"}}}
        """
    }

    @Test func refreshReadsTheProjectsAndKeepsThemWhenThatFails() throws {
        let f = try Fixture()
        let ok = try JiraMock(state: Self.state(fails: false))
        let c = try JiraCache.refresh(f.store, try JiraClient(ok.config), now: D0)
        #expect(c.projects == ["PROJ", "OPS"] && JiraCache.load(f.store).projects == ["PROJ", "OPS"])
        let bad = try JiraMock(state: Self.state(fails: true))
        let d = try JiraCache.refresh(f.store, try JiraClient(bad.config), now: D0 + H)
        #expect(d.at == D0 + H && d.mine == ["PROJ-1"] && d.projects == ["PROJ", "OPS"])
    }
}
