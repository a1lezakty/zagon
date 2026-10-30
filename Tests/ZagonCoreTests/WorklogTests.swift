import Foundation
import Testing
@testable import ZagonCore

@Suite struct PlannerTests {
    let day = Interval(D0, D0 + 24 * H)
    typealias S = WorklogPlanner.Share

    @Test func parallelHourIsLaidOutOneAfterAnother() {
        let s = D0 + 8 * H
        let out = WorklogPlanner.plan(day: day, stretches: [(Interval(s, s + H), [S(task: 1, seconds: 1800, first: s), S(task: 2, seconds: 1800, first: s + 60)])])
        #expect(out.entries == [.init(task: 1, start: s, end: s + 1800), .init(task: 2, start: s + 1800, end: s + H)])
        #expect(out.unplaced.isEmpty)
    }

    /// In a long stretch each task starts where its work started, not at the stretch start.
    @Test func tasksStartAtTheirFirstActivity() {
        let s = D0 + 9 * H
        let out = WorklogPlanner.plan(day: day, stretches: [(Interval(s, s + 8 * H), [
            S(task: 1, seconds: H, first: s + 5 * H + 120), S(task: 2, seconds: 1800, first: s + H),
        ])])
        #expect(out.entries == [.init(task: 2, start: s + H, end: s + 1.5 * H), .init(task: 1, start: s + 5 * H, end: s + 6 * H)])
    }

    @Test func roundsToFiveMinutes() {
        let s = D0 + 8 * H
        let out = WorklogPlanner.plan(day: day, stretches: [(Interval(s, s + H), [
            S(task: 1, seconds: 7 * 60, first: s), S(task: 2, seconds: 8 * 60, first: s + 1), S(task: 3, seconds: 2 * 60, first: s + 2),
        ])])
        #expect(out.entries.map(\.seconds) == [300, 600])   // 7 → 5, 8 → 10, 2 → nothing
    }

    @Test func alreadyLoggedIsSubtractedAndBusyIsAvoided() {
        let s = D0 + 8 * H
        // Task 1 worked 2 h, 1 h of it is in Jira 08:00–09:00 on its issue: plan the other hour, not over the worklog.
        let out = WorklogPlanner.plan(day: day, stretches: [(Interval(s, s + 2 * H), [S(task: 1, seconds: 2 * H, first: s)])],
                                      already: [1: H], busy: [Interval(s, s + H)])
        #expect(out.entries == [.init(task: 1, start: s + H, end: s + 2 * H)])
    }

    @Test func overflowGoesNextToItsStretch() {
        let s = D0 + 8 * H
        // A meeting logged 08:00–08:40 on another issue covers most of the 08:00–09:00 stretch.
        let out = WorklogPlanner.plan(day: day, stretches: [(Interval(s, s + H), [S(task: 1, seconds: H, first: s)])],
                                      busy: [Interval(s, s + 2400)])
        #expect(out.entries == [.init(task: 1, start: s + 2400, end: s + 2400 + H)])
    }

    @Test func smallPiecesMoveToTheBiggestStretch() {
        let a = D0 + 8 * H, b = D0 + 14 * H
        // 10 min of the task at 08:00 and 50 min at 14:00: one 60-min worklog from 14:00, nothing at 08:00.
        let out = WorklogPlanner.plan(day: day, stretches: [(Interval(a, a + 600), [S(task: 1, seconds: 600, first: a)]),
                                                            (Interval(b, b + 3000), [S(task: 1, seconds: 3000, first: b)])])
        #expect(out.entries == [.init(task: 1, start: b, end: b + H)])
    }

    @Test func unalignedEdgesAreWidenedToTheGrid() {
        let s = D0 + 8 * H + 130   // 08:02:10
        let out = WorklogPlanner.plan(day: day, stretches: [(Interval(s, s + 3300), [S(task: 1, seconds: 3300, first: s)])])
        #expect(out.entries == [.init(task: 1, start: D0 + 8 * H, end: D0 + 8 * H + 3300)])
    }

    /// The main invariant on random days: no overlap with each other or with busy time, inside the day, on the
    /// grid, and every 5-minute unit is either placed or reported as unplaced only when the day is full.
    @Test func neverOverlapsOnRandomDays() {
        var rng = SplitMix(seed: 2026)
        for run in 0..<600 {
            let stretchN = Int.random(in: 0...8, using: &rng)
            let users = Intervals.merge((0..<stretchN).map { _ in
                let a = D0 + Double.random(in: -H...(24 * H), using: &rng); return Interval(a, a + Double.random(in: 1...(5 * H), using: &rng))
            }).map { Interval(max(D0, $0.start), min(D0 + 24 * H, $0.end)) }.filter { $0.end > $0.start }
            let stretches = users.map { u -> (interval: Interval, shares: [S]) in
                var left = u.length
                let tasks = (1...4).shuffled(using: &rng).prefix(Int.random(in: 1...4, using: &rng))
                var shares: [S] = []
                for (k, t) in tasks.enumerated() {
                    let sec = k == tasks.count - 1 ? left : Double.random(in: 0...left, using: &rng)
                    left -= sec
                    shares.append(S(task: t, seconds: sec, first: u.start + Double.random(in: 0...u.length, using: &rng)))
                }
                return (u, shares)
            }
            let busy = (0..<Int.random(in: 0...6, using: &rng)).map { _ -> Interval in
                let a = D0 + Double.random(in: -2 * H...(24 * H), using: &rng); return Interval(a, a + Double.random(in: 60...(6 * H), using: &rng))
            }
            var already: [Int: Double] = [:]
            for t in 1...4 where Bool.random(using: &rng) { already[t] = Double.random(in: 0...(3 * H), using: &rng) }

            let out = WorklogPlanner.plan(day: day, stretches: stretches, already: already, busy: busy)
            let es = out.entries.sorted { $0.start < $1.start }
            for (i, e) in es.enumerated() {
                #expect(e.end > e.start && e.start >= D0 && e.end <= D0 + 24 * H, "run \(run)")
                #expect(e.start.truncatingRemainder(dividingBy: 300) == 0 && e.end.truncatingRemainder(dividingBy: 300) == 0, "run \(run)")
                if i > 0 { #expect(es[i - 1].end <= e.start, "run \(run): entries overlap") }
                for b in busy { #expect(!(b.start < e.end && b.end > e.start), "run \(run): overlaps busy") }
            }
            var need: [Int: Double] = [:]
            for s in stretches { for x in s.shares where x.seconds > 0 { need[x.task, default: 0] += x.seconds } }
            for (t, n) in need {
                let units = Int((max(0, n - (already[t] ?? 0)) / 300).rounded())
                let placed = es.filter { $0.task == t }.reduce(0) { $0 + $1.seconds }
                #expect(placed + (out.unplaced[t] ?? 0) == units * 300, "run \(run): task \(t)")
            }
            if !out.unplaced.isEmpty {
                let taken = Intervals.merge(es.map { Interval($0.start, $0.end) } + busy.map { Interval(WorklogPlanner.down($0.start), WorklogPlanner.up($0.end)) })
                #expect(abs(Intervals.covered(taken, from: D0, to: D0 + 24 * H) - 24 * H) < 1, "run \(run): unplaced with free time left")
            }
        }
    }
}

@Suite struct DayPlanTests {
    /// Plan from stored time, against a Jira day; logged rows survive a re-plan and are never planned again.
    @Test func planKeepsLoggedRowsAndAvoidsJira() throws {
        let f = try Fixture(), t = Tasks(store: f.store)
        _ = try t.add(title: "stand", key: "OPS-718"); let z = try t.add(title: "own")
        let s = D0 + 6 * H
        try f.session("claude:a", branch: "OPS-718-stand", title: "Stand captions", working: [(s, s + 3 * H)], actions: [s])
        try f.session("claude:z", working: [(s + 3 * H, s + 6.5 * H)], actions: [s + 3 * H])
        try t.link(z.id, session: "claude:z", how: .manual)
        try f.user([(s, s + 6.5 * H)])
        try t.setDone(z.id, day: "2026-10-29", text: "Own work by hand")
        try TaskLinker().linkSessions(f.store)
        let jira = JiraDay(worklogs: [JiraWorklog(id: "1", issueKey: "OPS-718", accountId: "me", started: s, seconds: Int(2 * H))],
                           issues: ["OPS-718": JiraIssue(key: "OPS-718", summary: "stand", status: "In Progress", statusCategory: "indeterminate")])
        let wl = Worklog(store: f.store)
        let p = try wl.plan(day: "2026-10-29", jira: jira)
        let rows = p.rows
        try #require(rows.map(\.taskKey) == ["OPS-718", "ZAG-1"])
        #expect(rows[0].start == s + 2 * H && rows[0].seconds == Int(H) && rows[0].text == "Stand captions")
        #expect(rows[1].start == s + 3 * H && rows[1].seconds == Int(3.5 * H) && rows[1].text == "Own work by hand")
        #expect(p.jiraSec == 2 * H && p.notes.contains("ZAG-1 is not in Jira: stays in Zagon"))
        #expect(p.notes.contains { $0.contains("status here planned") })
        // commit_digest: only the planned rows with a Jira key, each field counts.
        var changed = rows, own = rows
        changed[0].text += "!"; own[1].text = "other"
        #expect(!p.commitDigest.isEmpty && p.commitDigest == DayPlan.commitDigest(rows))
        #expect(DayPlan.commitDigest(changed) != p.commitDigest && DayPlan.commitDigest(own) == p.commitDigest)

        try wl.mark(rows[0].id, state: "logged", jiraWorklogId: "77")
        let again = try wl.plan(day: "2026-10-29",
                                jira: JiraDay(worklogs: jira.worklogs + [JiraWorklog(id: "77", issueKey: "OPS-718", accountId: "me",
                                                                                    started: rows[0].start, seconds: rows[0].seconds)],
                                              issues: jira.issues))
        #expect(again.rows.map(\.state) == ["logged", "planned"])
        #expect(again.rows.filter { $0.taskKey == "OPS-718" }.count == 1)
        #expect(again.commitDigest == DayPlan.commitDigest([]) && again.commitDigest != p.commitDigest)
    }
}

@Suite struct ReplanTests {
    func day(_ f: Fixture) throws -> (Tasks, TaskItem, Double) {
        let t = Tasks(store: f.store), a = try t.add(title: "a", key: "PROJ-1")
        let s = D0 + 9 * H
        try f.session("claude:a", branch: "PROJ-1", title: "Work", working: [(s, s + 3 * H)], actions: [s])
        try f.user([(s, s + 3 * H)])
        try TaskLinker().linkSessions(f.store)
        return (t, a, s)
    }

    /// After a commit Jira shows Zagon's own worklogs, also when moved there: counted once, at the Jira position.
    @Test func ownWorklogsCountOnceAndWhereJiraHasThem() throws {
        let f = try Fixture(), (_, _, s) = try day(f), wl = Worklog(store: f.store)
        let issue = ["PROJ-1": Optional(JiraIssue(key: "PROJ-1", summary: "a", status: "To Do", statusCategory: "new"))]
        let p = try wl.plan(day: "2026-10-29", jira: JiraDay(worklogs: [], issues: issue))
        try #require(p.rows.count == 1 && p.rows[0].seconds == Int(3 * H))
        try wl.mark(p.rows[0].id, state: "logged", jiraWorklogId: "w1")
        // Moved in Jira to 13:00–16:00.
        let moved = JiraWorklog(id: "w1", issueKey: "PROJ-1", accountId: "me", started: s + 4 * H, seconds: Int(3 * H))
        let again = try wl.plan(day: "2026-10-29", jira: JiraDay(worklogs: [moved], issues: issue))
        #expect(again.rows.map(\.state) == ["logged"])
        #expect(again.tasks.first?.jiraSec == 3 * H)
        #expect(!again.notes.contains { $0.contains("nothing logged") })
    }

    /// Logged by hand in Jira after the plan was made (no overlap): the re-plan proposes nothing more.
    @Test func manualWorklogAfterPlanIsSubtracted() throws {
        let f = try Fixture(), (_, _, s) = try day(f), wl = Worklog(store: f.store)
        #expect(try wl.plan(day: "2026-10-29").rows.count == 1)
        let manual = JiraWorklog(id: "m1", issueKey: "PROJ-1", accountId: "me", started: s + 5 * H, seconds: Int(3 * H))
        #expect(try wl.plan(day: "2026-10-29", jira: JiraDay(worklogs: [manual], issues: [:])).rows.isEmpty)
    }

    @Test func skipOnlyTouchesPlannedRows() throws {
        let f = try Fixture(), _ = try day(f), wl = Worklog(store: f.store)
        let id = try wl.plan(day: "2026-10-29").rows[0].id
        #expect(try wl.skip(id)?.state == "skipped")
        #expect(try wl.skip(id) == nil && wl.skip(9999) == nil)
        #expect(try wl.plan(day: "2026-10-29").rows.map(\.state) == ["skipped"])
    }
}

// MARK: Jira client against a local mock (python3 + curl in the container)

func hasTool(_ name: String) -> Bool { Exec.run(["sh", "-c", "command -v \(name)"])?.status == 0 }

final class JiraMock {
    let process = Process()
    let dir = tempDir()
    let url: String
    let config: JiraConfig

    init(state: String) throws {
        try state.write(toFile: dir + "/state.json", atomically: true, encoding: .utf8)
        try "old line\nsecret-token\n\n".write(toFile: dir + "/token", atomically: true, encoding: .utf8)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/jira_mock.py").path
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script, dir + "/state.json", dir + "/port", "me@example.com", "secret-token"]
        try process.run()
        var port: String?
        for _ in 0..<200 where port == nil {
            port = try? String(contentsOfFile: dir + "/port", encoding: .utf8)
            if port == nil { usleep(25_000) }
        }
        guard let port else { throw TaskError("mock did not start") }
        url = "http://127.0.0.1:\(port)"
        config = JiraConfig(baseURL: url + "/", email: "me@example.com", tokenFile: dir + "/token")
    }

    func state() throws -> [String: Any] {
        let r = Exec.run(["curl", "-s", url + "/_state"])!
        return try JSONSerialization.jsonObject(with: Data(r.out)) as! [String: Any]
    }

    deinit { kill(process.processIdentifier, SIGKILL); process.waitUntilExit(); try? FileManager.default.removeItem(atPath: dir) }
}

/// Basic auth goes over plain http only to this machine: the host must be exactly localhost, 127.0.0.1 or [::1].
@Suite struct JiraURLTests {
    @Test func plainHTTPOnlyToThisMachine() {
        for u in ["https://team.atlassian.net", "http://localhost", "http://localhost:8080/", "http://127.0.0.1:9/", "http://[::1]:9/rest",
                  "HTTP://LOCALHOST:1"] {
            #expect(JiraClient.allowed(u), "\(u)")
        }
        for u in ["http://localhost.evil.example", "http://127.0.0.1.evil.example/", "http://localhost@evil.example",
                  "http://localhost:80@evil.example", "http://evil.example/localhost", "http://evil.example?h=localhost",
                  "http://localhost:x", "http://localhost:", "http://[::1].evil.example", "ftp://localhost", "localhost"] {
            #expect(!JiraClient.allowed(u), "\(u)")
        }
    }
}

@Suite(.enabled(if: hasTool("python3") && hasTool("curl"), "needs python3 and curl"), .timeLimit(.minutes(1)))
struct JiraClientTests {
    static let state = """
        {"me": "acc-me", "issues": {
          "PROJ-1": {"summary": "Dialog \\"strategies\\"", "status": "In Progress", "category": "indeterminate", "assignee": "acc-me",
                    "worklogs": [
                      {"id": "1", "author": "acc-me", "started": "2026-10-29T08:00:00.000+0200", "seconds": 3600},
                      {"id": "2", "author": "acc-other", "started": "2026-10-29T08:00:00.000+0200", "seconds": 3600},
                      {"id": "3", "author": "acc-me", "started": "2026-10-27T08:00:00.000+0200", "seconds": 1800}]},
          "PROJ-2": {"summary": "Done one", "status": "Done", "category": "done", "assignee": "acc-me",
                    "worklogs": [{"id": "4", "author": "acc-me", "started": "2026-10-29T13:30:00.000+0200", "seconds": 1800}]},
          "OPS-3": {"summary": "Not mine", "status": "To Do", "category": "new", "assignee": "acc-other"},
          "OPS-4": {"summary": "Stand", "status": "To Do", "category": "new", "assignee": "acc-me"}}}
        """

    @Test func readsIssuesAndWorklogs() throws {
        let m = try JiraMock(state: Self.state), j = try JiraClient(m.config)
        #expect(try j.accountId() == "acc-me")
        #expect(try j.search("assignee = currentUser() AND statusCategory != Done").map(\.key) == ["OPS-4", "PROJ-1"])   // the mock pages in key order
        #expect(try j.issue("PROJ-1") == JiraIssue(key: "PROJ-1", summary: "Dialog \"strategies\"", status: "In Progress", statusCategory: "indeterminate"))
        #expect(try j.issue("NOPE-9") == nil)
        #expect(try j.worklogs(issue: "PROJ-1", startedAfter: 0).map(\.id) == ["1", "2", "3"])   // two pages
        // 2026-10-29 in UTC: 08:00+02 = 06:00Z; only my worklogs that overlap the day.
        let mine = try j.myWorklogs(from: D0, to: D0 + 24 * H)
        #expect(mine.map(\.id) == ["1", "4"])
        #expect(mine[0].started == D0 + 6 * H && mine[0].seconds == 3600 && mine[1].issueKey == "PROJ-2")
    }

    @Test func refusesPlainHTTPToARealHost() throws {
        let m = try JiraMock(state: Self.state)
        for url in ["http://jira.example.com", "http://localhost.example.com", "http://127.0.0.1.example.com/"] {
            #expect(throws: JiraError.self) { try JiraClient(JiraConfig(baseURL: url, email: "me@example.com", tokenFile: m.dir + "/token")) }
        }
    }

    @Test func wrongTokenIsAnHTTPError() throws {
        let m = try JiraMock(state: Self.state)
        try "wrong\n".write(toFile: m.dir + "/token", atomically: true, encoding: .utf8)
        let e = #expect(throws: JiraError.self) { try JiraClient(m.config).accountId() }
        if case .http(let code, _)? = e { #expect(code == 401) } else { Issue.record("not an HTTP error: \(String(describing: e))") }
    }

    @Test func writesWorklogOnlyToTheMock() throws {
        let m = try JiraMock(state: Self.state), j = try JiraClient(m.config)
        let comment = "Line one \"quoted\" \\ back\nline two — ünïcode"
        let id = try j.addWorklog(issue: "OPS-4", started: D0 + 9 * H, seconds: 1500, comment: comment)
        let issues = try m.state()["issues"] as! [String: [String: Any]]
        let w = (issues["OPS-4"]!["worklogs"] as! [[String: Any]]).first!
        #expect(w["id"] as? String == id && w["comment"] as? String == comment)
        #expect(w["started"] as? String == "2026-10-29T09:00:00.000+0000" && w["seconds"] as? Int == 1500)
        #expect(try j.myWorklogs(from: D0, to: D0 + 24 * H).map(\.id).contains(id))
    }

    /// Plan against the mock's worklogs, commit the planned rows through the client, plan again: nothing overlaps.
    @Test func planCommitReplanAgainstMock() throws {
        let m = try JiraMock(state: Self.state), j = try JiraClient(m.config)
        let f = try Fixture(), t = Tasks(store: f.store)
        try t.add(title: "dialogs", key: "PROJ-1")
        let s = D0 + 5 * H
        try f.session("claude:a", branch: "PROJ-1", title: "Dialog work", working: [(s, s + 4 * H)], actions: [s])
        try f.user([(s, s + 4 * H)])
        try TaskLinker().linkSessions(f.store)
        let wl = Worklog(store: f.store)
        func day() throws -> JiraDay {
            JiraDay(worklogs: try j.myWorklogs(from: D0, to: D0 + 24 * H), issues: ["PROJ-1": try j.issue("PROJ-1")])
        }
        let p = try wl.plan(day: "2026-10-29", jira: try day())
        // 4 h of work, 1 h already on PROJ-1 06:00–07:00Z: 3 h planned around it.
        #expect(p.rows.reduce(0) { $0 + $1.seconds } == Int(3 * H))
        for r in p.rows {
            let id = try j.addWorklog(issue: r.jiraKey!, started: r.start, seconds: r.seconds, comment: r.text)
            try wl.mark(r.id, state: "logged", jiraWorklogId: id)
        }
        let again = try wl.plan(day: "2026-10-29", jira: try day())
        #expect(again.rows.allSatisfy { $0.state == "logged" })
        let all = try j.myWorklogs(from: D0, to: D0 + 24 * H).map(\.interval).sorted { $0.start < $1.start }
        for k in 1..<all.count { #expect(all[k - 1].end <= all[k].start) }
    }
}
