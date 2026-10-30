import Foundation
import Testing
@testable import ZagonCore

/// Store with hand-made sessions: working intervals, user actions and user time, as Ingest would leave them.
struct Fixture {
    let store: Store
    init() throws { store = try Store(path: ":memory:") }

    /// `cwd`: the session's folder; `workedIn`: the folder of its intervals (default: unknown = the session's).
    func session(_ id: String, branch: String? = nil, title: String? = nil, cwd: String? = nil, working: [(Double, Double)] = [],
                 actions: [Double] = [], workedIn: String? = nil) throws {
        try store.mergeSession(SessionMeta(id: id, tool: .claude, cwd: cwd, gitBranch: branch, title: title, titleRank: TitleRank.customTitle))
        for (a, b) in working { try interval(id, a, b, cwd: workedIn) }
        for t in actions { try store.db.run("INSERT INTO user_action(file_id, session_id, ts, kind) VALUES(1, ?, ?, 'msg')", [.text(id), .real(t)]) }
        let all = working.flatMap { [$0.0, $0.1] } + actions
        if let lo = all.min(), let hi = all.max() {
            try store.db.run("UPDATE session SET started_at = min(coalesce(started_at, ?1), ?1), last_at = max(coalesce(last_at, ?2), ?2) WHERE id = ?3",
                             [.real(lo), .real(hi), .text(id)])
        }
    }

    /// A working interval (of the session or one of its sub-agents) worked in `cwd`.
    func interval(_ session: String, _ a: Double, _ b: Double, cwd: String? = nil) throws {
        try store.db.run("INSERT INTO activity(file_id, session_id, start, \"end\", kind, cwd) VALUES(1, ?, ?, ?, 'working', ?)",
                         [.text(session), .real(a), .real(b), .of(cwd)])
        try store.db.run("UPDATE session SET started_at = min(coalesce(started_at, ?1), ?1), last_at = max(coalesce(last_at, ?2), ?2) WHERE id = ?3",
                         [.real(a), .real(b), .text(session)])
    }

    func user(_ ivs: [(Double, Double)]) throws {
        for (a, b) in ivs { try store.db.run("INSERT INTO user_activity(start, \"end\") VALUES(?, ?)", [.real(a), .real(b)]) }
    }

    /// A typed message as Ingest leaves it: a user action and the task keys found in it (never the text).
    func message(_ session: String, _ ts: Double, keys: [String]) throws {
        try store.db.run("INSERT INTO user_action(file_id, session_id, ts, kind) VALUES(1, ?, ?, 'msg')", [.text(session), .real(ts)])
        for k in keys { try store.db.run("INSERT INTO task_key(file_id, session_id, key, at) VALUES(1, ?, ?, ?)", [.text(session), .text(k), .real(ts)]) }
    }
}

let H = 3600.0
/// 2026-10-29 00:00 UTC (tests run with TZ=UTC).
let D0 = 1_793_232_000.0

@Suite struct RegistryTests {
    @Test func keysTodosNotesDone() throws {
        let f = try Fixture(), t = Tasks(store: f.store)
        let a = try t.add(title: "own one"), b = try t.add(title: "own two")
        #expect(a.key == "ZAG-1" && b.key == "ZAG-2" && a.jiraKey == nil)
        let c = try t.add(title: "external", key: "proj-5")
        #expect(c.key == "PROJ-5" && c.jiraKey == "PROJ-5")
        #expect(throws: TaskError.self) { try t.add(title: "dup", key: "PROJ-5") }
        #expect(throws: TaskError.self) { try t.add(title: "same issue", jiraKey: "PROJ-5") }
        let d = try t.add(title: "mapped", key: "OPS-1", jiraKey: "OPS-9")
        #expect(try t.find("ops-9")?.id == d.id && t.find("OPS-1")?.id == d.id && t.find("\(c.id)")?.key == "PROJ-5")
        #expect(try t.find("NOPE-1") == nil)

        try t.addTodo(a.id, "first"); try t.addTodo(a.id, "second")
        try t.checkTodo(a.id, number: 2)
        #expect(try t.todos(a.id).map(\.done) == [false, true])
        #expect(throws: TaskError.self) { try t.checkTodo(a.id, number: 3) }
        try t.addNote(a.id, "a note")
        #expect(try t.notes(a.id).map(\.text) == ["a note"])
        try t.setDone(a.id, day: "2026-10-29", text: "auto text", source: "auto")
        try t.setDone(a.id, day: "2026-10-29", text: "by hand")
        try t.setDone(a.id, day: "2026-10-30", text: "next day")
        #expect(try t.done(a.id).map(\.text) == ["next day", "by hand", "auto text"])
        try t.setStatus(a.id, .inProgress)
        #expect(try t.get(a.id)?.status == .inProgress)
        #expect(try t.list(status: .inProgress).map(\.key) == ["ZAG-1"])
        // A row with the schema default status reads as planned.
        try f.store.db.run("INSERT INTO task(key, title, created, updated) VALUES('OLD-1', 'old', 0, 0)")
        #expect(try t.find("OLD-1")?.status == .planned)
    }
}

@Suite struct LinkTests {
    @Test func keysInText() throws {
        let l = try TaskLinker()
        #expect(l.keys(in: "PROJ-1234-short-slug") == ["PROJ-1234"])
        #expect(l.keys(in: "fix/utf-8-handling") == [])
        #expect(l.keys(in: "OPS-718 and PROJ-2533, again OPS-718") == ["OPS-718", "PROJ-2533"])
        #expect(try TaskLinker(patterns: [#"#\d+"#]).keys(in: "see #42") == ["#42"])
        #expect(l.keys(in: "fooPROJ-12 and (PROJ-13)") == ["PROJ-13"])
        #expect(try TaskLinker(patterns: [#"(?i)[a-z][a-z0-9]+-\d+"#]).keys(in: "feature/proj-123-x") == ["PROJ-123"])
    }

    /// Each link covers only its own time: a recorded branch the intervals in the session's folder, a typed key the
    /// work that follows it until a long pause or a message with other keys, a title the whole session; at one moment
    /// the strongest wins (manual > typed key/commit > branch/title), and an unlinked task gets nothing.
    @Test func linksCoverTheirOwnTime() throws {
        let f = try Fixture(), t = Tasks(store: f.store)
        let a = try t.add(title: "a", key: "PROJ-1"), b = try t.add(title: "b", key: "OPS-2"), z = try t.add(title: "z")
        let h = { (x: Double) in D0 + x * H }
        try f.session("claude:s1", branch: "PROJ-1-work", cwd: "/w/p", working: [(h(8), h(9))])
        try f.interval("claude:s1", h(9), h(9.5), cwd: "/w/other")             // a sub-agent elsewhere: not the branch's folder
        try f.session("claude:s2", title: "OPS-2 stand video", working: [(h(8), h(9))])
        try f.session("claude:s3", working: [(h(10), h(11)), (h(12), h(13))])
        try f.message("claude:s3", h(10), keys: ["PROJ-1"])                     // reaches 11:00; the hour's pause ends it
        try f.session("claude:s4", working: [(h(10), h(11))])
        try f.message("claude:s4", h(10), keys: ["PROJ-1"])
        try f.message("claude:s4", h(10.25), keys: ["PROJ-1"])                  // same key: the same period goes on
        try f.message("claude:s4", h(10.5), keys: ["OPS-2"])                    // other key: PROJ-1 stops here
        try f.session("claude:s5", working: [(h(10), h(11))])
        try f.message("claude:s5", h(10), keys: ["PROJ-12"])                    // no such task
        try f.session("claude:s6", title: "OPS-2", working: [(h(14), h(16))])
        try f.message("claude:s6", h(15), keys: ["PROJ-1"])
        try f.session("claude:s7", working: [(h(16), h(16.5)), (h(18), h(19))])
        try f.message("claude:s7", h(16), keys: ["PROJ-1"])
        try f.message("claude:s7", h(18), keys: ["PROJ-1"])                     // the same key after a long pause: a new period
        // A branch and a typed key of one task starting together stay two links: OPS-2 typed later wins over the key's
        // reach, the branch still holds where nothing stronger is.
        try f.session("claude:s8", branch: "PROJ-1-x", cwd: "/w/p", working: [(h(20), h(22))], workedIn: "/w/p")
        try f.message("claude:s8", h(20), keys: ["PROJ-1"])
        try f.message("claude:s8", h(21), keys: ["OPS-2"])
        // A whole-session commit link as the v3 migration left it: dropped.
        try f.store.db.run("INSERT INTO task_session(task_id, session_id, how) VALUES(?, 'claude:s5', 'commit')", [.int(Int64(z.id))])
        try TaskLinker().linkSessions(f.store)
        var m = try t.linkMap()
        let at = { (s: String, x: Double) in m.tasks("claude:" + s, at: h(x)).map(\.task) }
        #expect(at("s1", 8.5) == [a.id] && at("s1", 9.2) == [])
        #expect(at("s2", 8.5) == [b.id] && at("s2", 20) == [b.id])            // a title is for the whole session
        #expect(at("s3", 10.5) == [a.id] && at("s3", 12.5) == [])
        #expect(at("s4", 10.4) == [a.id] && at("s4", 10.6) == [b.id])
        #expect(at("s5", 10.5) == [])
        #expect(at("s6", 14.5) == [b.id] && at("s6", 15.5) == [a.id])          // typed key beats the title there
        #expect(at("s7", 16.2) == [a.id] && at("s7", 17) == [] && at("s7", 18.5) == [a.id])
        #expect(m.tasks("claude:s7", at: h(18) - 0.0001).isEmpty && m.tasks("claude:s7", at: h(18)).map(\.task) == [a.id])  // exact start
        #expect(at("s8", 20.5) == [a.id] && at("s8", 21.5) == [b.id])
        #expect(try t.links(a.id).first { $0.sessionId == "claude:s4" }?.periods == 1)

        // Rebuilt, not piled up; manual beats auto links; unlink keeps auto from adding it back.
        let rows = try f.store.db.one("SELECT count(*) FROM task_session") { $0.int(0) }
        try TaskLinker().linkSessions(f.store)
        #expect(try f.store.db.one("SELECT count(*) FROM task_session") { $0.int(0) } == rows)
        try t.link(z.id, session: "claude:s1", how: .manual)
        try t.link(a.id, session: "claude:s3", how: .unlinked)
        try TaskLinker().linkSessions(f.store)
        m = try t.linkMap()
        #expect(at("s1", 8.5) == [z.id] && at("s1", 9.2) == [z.id])
        #expect(at("s3", 10.5) == [])
        let s3 = try t.links(a.id).first { $0.sessionId == "claude:s3" }
        #expect(s3?.how == "unlinked" && s3?.periods == 0)                       // no auto rows left beside it
    }

    /// Commits take the work of their repository (all its worktrees) since the previous commit, at most 2 h back and
    /// 30 min after the last; a worktree's branch takes its intervals; colleagues' commits, other days and folders
    /// that are not repositories give nothing.
    @Test func commitsAndWorktreesByFolder() throws {
        let dir = tempDir(), repo = dir + "/repo", wt = dir + "/wt"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        func git(_ args: String..., at date: Double? = nil, authored: Double? = nil, email: String = "t@example.com", in d: String? = nil) {
            if let date { setenv("GIT_COMMITTER_DATE", "@\(Int(date)) +0000", 1); setenv("GIT_AUTHOR_DATE", "@\(Int(authored ?? date)) +0000", 1) }
            _ = Exec.run(["git", "-C", d ?? repo, "-c", "user.name=t", "-c", "user.email=\(email)", "-c", "init.defaultBranch=main"] + args, quiet: true)
        }
        let h = { (x: Double) in D0 + x * H }
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        git("init", "-q")
        git("config", "user.email", "t@example.com")
        git("commit", "-q", "--allow-empty", "-m", "start", at: h(1))
        git("worktree", "add", "-q", "-b", "OPS-3-feature", wt)
        git("commit", "-q", "--allow-empty", "-m", "PROJ-7: first part", at: h(10))
        git("commit", "-q", "--allow-empty", "-m", "PROJ-9: a colleague", at: h(10.2), email: "other@example.com")
        git("checkout", "-q", "-b", "PROJ-9-later", at: h(10.45), in: wt)       // after its sub-agent's work there
        git("commit", "-q", "--allow-empty", "-m", "PROJ-8: second part", at: h(10.5), in: wt)
        git("commit", "-q", "--allow-empty", "-m", "PROJ-8: next day", at: h(34))
        let other = dir + "/other"                                               // a repository nobody moved into
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        git("init", "-q", in: other)
        git("config", "user.email", "t@example.com", in: other)
        git("commit", "-q", "--allow-empty", "-m", "OPS-5: other repository", at: h(12), in: other)
        git("commit", "-q", "--allow-empty", "-m", "OPS-6: rebased next day", at: h(30), authored: h(11.8), in: other)
        unsetenv("GIT_COMMITTER_DATE"); unsetenv("GIT_AUTHOR_DATE")

        let f = try Fixture(), t = Tasks(store: f.store)
        let p7 = try t.add(title: "a", key: "PROJ-7"), p8 = try t.add(title: "b", key: "PROJ-8")
        let p9 = try t.add(title: "c", key: "PROJ-9"), o3 = try t.add(title: "d", key: "OPS-3"), o5 = try t.add(title: "e", key: "OPS-5")
        let o6 = try t.add(title: "f", key: "OPS-6")
        try f.session("claude:s1", cwd: repo, working: [(h(6), h(10.8))], workedIn: repo)
        try f.interval("claude:s1", h(10.1), h(10.4), cwd: wt)                  // its sub-agent in the worktree
        try f.session("claude:s2", cwd: "/nonexistent", working: [(h(9), h(11))], workedIn: "/nonexistent")
        try f.session("claude:s3", cwd: dir, working: [(h(9), h(9.5)), (h(11.5), h(12))], workedIn: dir)   // above the repositories
        try f.session("claude:s4", cwd: dir + "/re", working: [(h(9), h(9.5))], workedIn: dir + "/re")  // a name prefix, not above
        // The same folder through a symlink (git gives real paths; macOS temp folders are /var → /private/var).
        let alias = dir + "-alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: dir)
        defer { try? FileManager.default.removeItem(atPath: alias) }
        try f.session("claude:s6", cwd: alias, working: [(h(9), h(9.5))], workedIn: alias)
        // On branch PROJ-8 from where a PROJ-8 commit window starts: the branch outlives the window, also re-planned.
        try f.session("claude:s5", branch: "PROJ-8-x", cwd: repo, working: [(h(10.1), h(12))], workedIn: repo)
        let linker = try TaskLinker()
        try linker.linkSessions(f.store)
        try linker.linkDay(f.store, from: D0, to: D0 + 24 * H)
        var m = try t.linkMap()
        let at = { (s: String, x: Double) in m.tasks("claude:" + s, at: h(x)).map(\.task) }
        #expect(at("s1", 7) == [])                                               // more than 2 h before the first commit
        #expect(at("s1", 9) == [p7.id] && at("s1", 10.3) == [p8.id] && at("s1", 10.7) == [p8.id])
        #expect(at("s2", 10) == [] && at("s3", 9.2) == [p7.id] && at("s4", 9.2) == [] && at("s6", 9.2) == [p7.id])
        #expect(at("s3", 11.7) == [o6.id] && at("s3", 11.9) == [o5.id])          // by author time
        #expect(try t.links(p9.id).isEmpty)                                       // the worktree's branch now is not that time's
        // The worktree's branch of that time links its intervals, but the commit beats it there.
        #expect(try t.links(o3.id).map(\.sessionId) == ["claude:s1"])
        #expect(at("s1", 10.2) == [p8.id])
        #expect(at("s5", 11.5) == [p8.id])
        let rows = try f.store.db.one("SELECT count(*) FROM task_session") { $0.int(0) }
        try linker.linkSessions(f.store)
        try linker.linkDay(f.store, from: D0, to: D0 + 24 * H)
        #expect(try f.store.db.one("SELECT count(*) FROM task_session") { $0.int(0) } == rows)
        m = try t.linkMap()
        #expect(at("s5", 11.5) == [p8.id] && at("s1", 9) == [p7.id])
    }
}

@Suite struct TimeSplitTests {
    @Test func parallelSessionsShareTheHour() throws {
        let f = try Fixture(), t = Tasks(store: f.store)
        let a = try t.add(title: "a", key: "PROJ-1"), b = try t.add(title: "b", key: "PROJ-2")
        let s = D0 + 8 * H
        try f.session("claude:a", branch: "PROJ-1", working: [(s, s + H)], actions: [s])
        try f.session("claude:b", branch: "PROJ-2", working: [(s + 0.5 * H, s + H)], actions: [s + 0.5 * H])
        try f.session("claude:x", working: [(s + 2 * H, s + 2.5 * H)], actions: [s + 2 * H])   // no task
        try f.user([(s, s + H), (s + 2 * H, s + 2.5 * H)])
        try TaskLinker().linkSessions(f.store)
        let r = try TaskTime.compute(f.store, from: D0, to: D0 + 24 * H, base: .user)
        // 08:00–08:30 only a; 08:30–09:00 both: a 30 + 15, b 15.
        #expect(abs(r.lines[a.id]!.userSec - 0.75 * H) < 1e-6)
        #expect(abs(r.lines[b.id]!.userSec - 0.25 * H) < 1e-6)
        #expect(abs(r.lines[nil]!.userSec - 0.5 * H) < 1e-6)
        #expect(r.lines[a.id]!.sessionSec == H && r.lines[b.id]!.sessionSec == 0.5 * H)
        #expect(r.lines[b.id]!.firstActive == s + 0.5 * H)
    }

    /// A session with no task running alongside a linked one takes nothing from it: one slot, one task.
    @Test func unlinkedParallelSessionsDoNotDilute() throws {
        let f = try Fixture(), t = Tasks(store: f.store)
        let a = try t.add(title: "a", key: "PROJ-1")
        let s = D0 + 8 * H
        try f.session("claude:a", branch: "PROJ-1", working: [(s, s + H)])
        try f.session("claude:x", working: [(s, s + 2 * H)])
        try TaskLinker().linkSessions(f.store)
        let r = try TaskTime.compute(f.store, from: D0, to: D0 + 24 * H)
        #expect(abs(r.lines[a.id]!.userSec - H) < 1e-6 && abs(r.lines[nil]!.userSec - H) < 1e-6)
    }

    @Test func gapWithoutActivityFollowsTheStretch() throws {
        let f = try Fixture(), t = Tasks(store: f.store)
        let a = try t.add(title: "a", key: "PROJ-1")
        let s = D0 + 8 * H
        // User time 08:00–09:00, the session worked only 08:00–08:20: the rest is a's too (only task in the stretch).
        try f.session("claude:a", branch: "PROJ-1", working: [(s, s + 1200)])
        try f.user([(s, s + H)])
        try TaskLinker().linkSessions(f.store)
        let r = try TaskTime.compute(f.store, from: D0, to: D0 + 24 * H, base: .user)
        #expect(abs(r.lines[a.id]!.userSec - H) < 1e-6 && r.lines[nil] == nil)
    }

    @Test func sessionsBaseCountsAgentTime() throws {
        let f = try Fixture(), t = Tasks(store: f.store)
        let a = try t.add(title: "a", key: "PROJ-1")
        let s = D0 + 8 * H
        // You typed for 10 minutes, the agent worked 08:00–11:00.
        try f.session("claude:a", branch: "PROJ-1", working: [(s, s + 3 * H)], actions: [s])
        try f.user([(s, s + 600)])
        try TaskLinker().linkSessions(f.store)
        #expect(try TaskTime.compute(f.store, from: D0, to: D0 + 24 * H, base: .user).lines[a.id]!.userSec == 600)
        #expect(try TaskTime.compute(f.store, from: D0, to: D0 + 24 * H, base: .sessions).lines[a.id]!.userSec == 3 * H)
    }

    @Test func randomSplitsAddUpToUserTime() throws {
        var rng = SplitMix(seed: 7)
        for _ in 0..<150 {
            let f = try Fixture(), t = Tasks(store: f.store)
            let ids = try (1...3).map { try t.add(title: "t", key: "K-\($0)").id }
            for s in 0..<Int.random(in: 1...6, using: &rng) {
                let w = (0..<Int.random(in: 1...4, using: &rng)).map { _ -> (Double, Double) in
                    let a = D0 + Double.random(in: 0...(22 * H), using: &rng); return (a, a + Double.random(in: 60...(2 * H), using: &rng))
                }
                let branch = Bool.random(using: &rng) ? "K-\(Int.random(in: 1...3, using: &rng))" : nil
                try f.session("claude:\(s)", branch: branch, working: w, actions: w.map(\.0))
            }
            let users = Intervals.merge((0..<Int.random(in: 1...5, using: &rng)).map { _ in
                let a = D0 + Double.random(in: 0...(22 * H), using: &rng); return Interval(a, a + Double.random(in: 60...(3 * H), using: &rng))
            })
            try f.user(users.map { ($0.start, $0.end) })
            try TaskLinker().linkSessions(f.store)
            let r = try TaskTime.compute(f.store, from: D0, to: D0 + 24 * H, base: .user)
            let total = Intervals.covered(users, from: D0, to: D0 + 24 * H)
            #expect(abs(r.lines.values.reduce(0) { $0 + $1.userSec } - total) < 1e-3)
            for s in r.slices { #expect(abs(s.shares.values.reduce(0, +) - s.interval.length) < 1e-3 && s.shares.values.allSatisfy { $0 >= 0 }) }
            _ = ids
        }
    }
}

/// Deterministic generator so a failing random case can be replayed.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
