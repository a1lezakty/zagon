import Foundation
import Testing
@testable import ZagonCore

@Suite struct ReconcileStatusTests {
    @Test func statusesAndTolerance() {
        let tol = 15 * 60
        #expect(Reconcile.status(session: 3600, jira: 0, toleranceSec: tol) == .onlySessions)
        #expect(Reconcile.status(session: 0, jira: 3600, toleranceSec: tol) == .onlyJira)
        #expect(Reconcile.status(session: 3600, jira: 3600 + tol, toleranceSec: tol) == .match)
        #expect(Reconcile.status(session: 3600, jira: 3600 + tol + 1, toleranceSec: tol) == .mismatch)
        #expect(Reconcile.status(session: 3600 + tol + 1, jira: 3600, toleranceSec: tol) == .mismatch)
    }

    @Test func durationsAndCSVFields() {
        #expect(ReconcileText.hm(145 * 3600 + 20 * 60) == "145:20" && ReconcileText.hm(-3600) == "1:00")
        #expect(ReconcileText.diff(-3900) == "-1:05" && ReconcileText.diff(10) == "0:00")
        #expect(ReconcileText.minutes(5400) == "90" && ReconcileText.minutes(-1800) == "-30" && ReconcileText.minutes(0) == "0")
        #expect(ReconcileText.csvField("a, \"b\"") == "\"a, \"\"b\"\"\"" && ReconcileText.csvField("plain") == "plain")
        #expect(ReconcileText.cell("a|b\nc") == "a\\|b c")
    }
}

let reconcileToday = "2026-11-30"

/// 2026-10-27 … 2026-11-01 (tests run in UTC) against the Jira mock; sessions start 10-29.
@Suite(.enabled(if: hasTool("python3") && hasTool("curl"), "needs python3 and curl"), .timeLimit(.minutes(1)))
struct ReconcileTests {
    static let state = """
        {"me": "acc-me", "issues": {
          "PROJ-1": {"summary": "Dialogs", "status": "In Progress", "category": "indeterminate", "assignee": "acc-me",
                    "worklogs": [
                      {"id": "1", "author": "acc-me", "started": "2026-10-29T08:00:00.000+0000", "seconds": 11100, "comment": "Dialog work, part \\"one\\""},
                      {"id": "2", "author": "acc-other", "started": "2026-10-29T08:00:00.000+0000", "seconds": 3600},
                      {"id": "3", "author": "acc-me", "started": "2026-10-27T08:00:00.000+0000", "seconds": 1800},
                      {"id": "4", "author": "acc-me", "started": "2026-11-01T09:00:00.000+0000", "seconds": 3600}]},
          "PROJ-2": {"summary": "Reports", "status": "In Progress", "category": "indeterminate", "assignee": "acc-me",
                    "worklogs": [
                      {"id": "5", "author": "acc-me", "started": "2026-10-29T12:00:00.000+0000", "seconds": 1800, "_new": true},
                      {"id": "6", "author": "acc-me", "started": "2026-10-30T01:30:00.000+0300", "seconds": 1800, "_new": true}]},
          "PROJ-3": {"summary": "Exports", "status": "In Progress", "category": "indeterminate", "assignee": "acc-me",
                    "worklogs": [{"id": "8", "author": "acc-me", "started": "2026-10-31T15:00:00.000+0000", "seconds": 3600}]},
          "OPS-4": {"summary": "Stand meeting", "status": "To Do", "category": "new", "assignee": "acc-me",
                    "worklogs": [{"id": "7", "author": "acc-me", "started": "2026-10-30T10:00:00.000+0000", "seconds": 3600}]}}}
        """

    /// PROJ-1: 10-29 3 h worked, 3 h 05 m logged (match); 10-30 1 h, nothing logged; 10-31 23:00 – 11-01 01:00 across
    /// the month, 11-01 logged 1 h; 10-27 logged 30 m, before any session. PROJ-2: 10-29 2 h, 1 h logged in two
    /// worklogs the search does not see yet, one of them 01:30 +03:00 on 10-30 = 22:30 on 10-29 here. PROJ-3: worked
    /// 10-30, logged 10-31 (same length, other day). OPS-4: logged, no task here. 1 h of work with no task. ZAG-1: own
    /// task, 30 m.
    func fixture(_ jira: JiraClient?, setupError: String? = nil, extra: (Fixture) throws -> Void = { _ in }) throws -> DayWorklog {
        let f = try Fixture(), t = Tasks(store: f.store)
        try t.add(title: "dialogs", key: "PROJ-1"); try t.add(title: "reports", key: "PROJ-2"); try t.add(title: "exports", key: "PROJ-3")
        let own = try t.add(title: "own")
        try f.session("claude:a", branch: "PROJ-1", title: "Dialog work", working: [(D0 + 8 * H, D0 + 11 * H)])
        try f.session("claude:b", branch: "PROJ-2", title: "Report work", working: [(D0 + 12 * H, D0 + 14 * H)])
        try f.session("claude:z", branch: "main", title: "Something else", working: [(D0 + 15 * H, D0 + 16 * H)])
        try f.store.db.run("UPDATE session SET project = 'web-app', host = 'build-box' WHERE id = 'claude:z'")
        try f.session("claude:o", working: [(D0 + 17 * H, D0 + 17.5 * H)])
        try t.link(own.id, session: "claude:o", how: .manual)
        try f.session("claude:c", branch: "PROJ-1", title: "More dialogs", working: [(D0 + 33 * H, D0 + 34 * H)])
        try f.session("claude:e", branch: "PROJ-3", title: "Export work", working: [(D0 + 35 * H, D0 + 36 * H)])
        try t.setDone(own.id, day: "2026-10-29", text: "Own work by hand")
        try f.session("claude:d", branch: "PROJ-1", title: "Night dialogs", working: [(D0 + 71 * H, D0 + 73 * H)])
        try extra(f)
        return DayWorklog(store: f.store, linker: try TaskLinker(), jira: jira, jiraSetupError: setupError)
    }

    func row(_ r: Reconcile, _ day: String, _ name: String) -> Reconcile.Row? {
        r.days.first { $0.day == day }?.rows.first { ReconcileText.name($0) == name }
    }

    @Test func allStatusesTotalsAndDays() throws {
        let m = try JiraMock(state: Self.state), w = try fixture(try JiraClient(m.config))
        let r = try w.reconcile(from: "2026-10-27", to: "2026-11-01", today: reconcileToday)
        #expect(r.jira == "connected" && r.jiraError == nil && r.toleranceMin == 15 && r.coverageFrom == "2026-10-29")
        #expect(r.days.map(\.day) == ["2026-10-27", "2026-10-29", "2026-10-30", "2026-10-31", "2026-11-01"])
        #expect(r.days[0].beforeCoverage && r.days[0].jiraSec == 1800 && r.days[0].rows.isEmpty && r.totals.jiraBeforeCoverageSec == 1800)

        let a = try #require(row(r, "2026-10-29", "PROJ-1"))
        #expect(a.status == .match && a.sessionSec == 3 * 3600 && a.jiraSec == 11100)
        #expect(a.sessions.map(\.title) == ["Dialog work"] && a.sessions[0].branch == "PROJ-1" && a.sessions[0].tool == "claude"
                && a.sessions[0].sec == 3 * 3600)
        #expect(a.worklogs.map(\.id) == ["1"] && a.worklogs[0].comment == "Dialog work, part \"one\"")   // not the other author's
        #expect(a.worklogs[0].end == D0 + 8 * H + 11100)
        let b = try #require(row(r, "2026-10-29", "PROJ-2"))
        #expect(b.status == .mismatch && b.sessionSec == 2 * 3600 && b.jiraSec == 3600 && b.worklogs.map(\.id) == ["5", "6"])
        let none = try #require(row(r, "2026-10-29", "(no task)"))
        #expect(none.status == .noTask && none.sessionSec == 3600 && none.project == "web-app" && none.branch == "main")
        #expect(none.sessions.map(\.host) == ["build-box"] && ReconcileText.label(none) == "web-app · branch main")
        let own = try #require(row(r, "2026-10-29", "ZAG-1"))
        #expect(own.status == .zagonOnly && own.jiraKey == nil && own.sessionSec == 1800 && own.done == "Own work by hand")
        #expect(row(r, "2026-10-30", "PROJ-1")?.status == .onlySessions)
        let ops = try #require(row(r, "2026-10-30", "OPS-4"))
        #expect(ops.status == .onlyJira && ops.key == nil && ops.title == "Stand meeting" && ops.jiraSec == 3600)
        #expect(row(r, "2026-10-30", "PROJ-3")?.status == .onlySessions && row(r, "2026-10-31", "PROJ-3")?.status == .onlyJira)
        #expect(row(r, "2026-10-31", "PROJ-1").map { ($0.status, $0.sessionSec) } ?? (.match, 0) == (.onlySessions, 3600))
        #expect(row(r, "2026-11-01", "PROJ-1").map { ($0.status, $0.sessionSec, $0.jiraSec) } ?? (.onlyJira, 0, 0) == (.match, 3600, 3600))
        let d30 = try #require(r.days.first { $0.day == "2026-10-30" })
        #expect(d30.sessionSec == 2 * 3600 && d30.jiraSec == 3600 && d30.unloggedSec == 2 * 3600 && d30.jiraOnlySec == 3600)

        let t = r.totals
        #expect(t.sessionSec == Int(10.5 * H) && t.jiraSec == 11100 + 4 * 3600 && t.noTaskSec == 3600 && t.zagonOnlySec == 1800)
        #expect(t.unloggedSec == Int(5.5 * H) && t.jiraOnlySec == 300 + 2 * 3600)
        #expect(t.sessionSec - t.jiraSec == t.unloggedSec - t.jiraOnlySec)
        let tasks = Dictionary(r.tasks.map { (ReconcileText.name($0), $0) }, uniquingKeysWith: { a, _ in a })
        #expect(tasks["PROJ-1"].map { ($0.status, $0.sessionSec, $0.jiraSec) } ?? (.match, 0, 0) == (.mismatch, 6 * 3600, 11100 + 3600))
        // Same total, other days: not a match.
        #expect(tasks["PROJ-3"].map { ($0.status, $0.sessionSec, $0.jiraSec) } ?? (.match, 0, 0) == (.mismatch, 3600, 3600))
        #expect(tasks["OPS-4"]?.status == .onlyJira && tasks["(no task)"]?.status == .noTask && tasks["ZAG-1"]?.status == .zagonOnly)
        #expect(r.tasks.first.map(ReconcileText.name) == "PROJ-1" && r.tasks.allSatisfy { $0.sessions.isEmpty && $0.worklogs.isEmpty && $0.done == nil })
        // Only days in the range: PROJ-1 alone on 10-29 matches.
        let one = try w.reconcile(from: "2026-10-29", to: "2026-10-29", today: reconcileToday)
        #expect(one.tasks.first { $0.key == "PROJ-1" }?.status == .match)

        let md = ReconcileText.markdown(r)
        #expect(md.contains("| PROJ-1 | PROJ-1 | dialogs | 6:00 | 4:05 | +1:55 | mismatch |"))
        #expect(md.contains("> reconciled from 2026-10-29: no whole session history before it; Jira has 0:30 there"))
        #expect(md.contains("### 2026-10-30 · sessions 2:00 · Jira 1:00") && md.contains("  - worklog 08:00–11:05 3:05: Dialog work, part \"one\""))
        #expect(md.contains("  - done: Own work by hand") && md.contains("| **Total** | | | **10:30** | **7:05** | **+3:25** | |"))
        let csv = ReconcileText.csv(r).split(separator: "\n")
        #expect(csv.count == 1 + r.days.reduce(0) { $0 + $1.rows.count })
        #expect(csv.contains("2026-10-29,PROJ-1,PROJ-1,dialogs,match,180,185,-5,Dialog work,\"08:00–11:05 Dialog work, part \"\"one\"\"\""))
        let json = try ReconcileText.json(r)
        for k in ["\"jira_only_sec\":7500", "\"status\":\"only_jira\"", "\"status\":\"zagon_only\"", "\"status\":\"no_task\"",
                  "\"coverage_from\":\"2026-10-29\"", "\"jira_before_coverage_sec\":1800", "\"before_coverage\":true", "\"to_requested\""] {
            #expect(json.contains(k), "\(k)")
        }
        #expect(ReconcileText.text(r).hasPrefix("2026-10-27 – 2026-11-01: worked 10:30 · in Jira 7:05 · not logged 5:30"))
    }

    /// A task kept the old key of a moved issue: the search finds the new key, the direct read of the old one returns
    /// the same worklog; it counts once. An issue gone between the search and its full read (404) is skipped.
    @Test func movedIssueCountsOnceAndGoneIssueIsSkipped() throws {
        let moved = #""MOVED-9": {"summary": "Moved", "status": "Done", "category": "done", "assignee": "acc-me", "worklogs": [{"id": "9", "author": "acc-me", "started": "2026-10-29T18:00:00.000+0000", "seconds": 1200}]},"#
        let s = Self.state.replacingOccurrences(of: #"{"me": "acc-me", "issues": {"#,
                                                with: #"{"me": "acc-me", "aliases": {"OLD-1": "MOVED-9"}, "worklog_404": ["PROJ-1"], "issues": {"# + moved)
        let m = try JiraMock(state: s)
        let w = try fixture(try JiraClient(m.config)) { f in
            try Tasks(store: f.store).add(title: "moved", key: "OLD-1")
            try f.session("claude:m", branch: "OLD-1", title: "Moved work", working: [(D0 + 18 * H, D0 + 19 * H)])
        }
        let r = try w.reconcile(from: "2026-10-29", to: "2026-10-29", today: reconcileToday)
        #expect(r.jira == "connected", "\(r.jiraError ?? "")")
        #expect(r.days.flatMap(\.rows).flatMap(\.worklogs).filter { $0.id == "9" }.count == 1)
        #expect(row(r, "2026-10-29", "OLD-1")?.status == .onlySessions && row(r, "2026-10-29", "MOVED-9")?.jiraSec == 1200)
        // PROJ-1 has 4 worklogs (more than the mock embeds) and its full read is 404: nothing from it, no failure.
        #expect(row(r, "2026-10-29", "PROJ-1")?.jiraSec == 0)
    }

    @Test func toleranceFromTheWorklog() throws {
        let m = try JiraMock(state: Self.state)
        var w = try fixture(try JiraClient(m.config))
        w.reconcileToleranceMin = 0
        #expect(try row(w.reconcile(from: "2026-10-29", to: "2026-10-29", today: reconcileToday), "2026-10-29", "PROJ-1")?.status == .mismatch)
    }

    @Test func jiraDownKeepsTheSessions() throws {
        let dir = makeTempDir()
        try "token\n".write(toFile: dir + "/token", atomically: true, encoding: .utf8)
        let down = try JiraClient(JiraConfig(baseURL: "http://127.0.0.1:1", email: "me@example.com", tokenFile: dir + "/token"))
        let r = try fixture(down).reconcile(from: "2026-10-29", to: "2026-11-01", today: reconcileToday)
        #expect(r.jira == "failed" && r.jiraError?.contains("curl") == true)
        #expect(r.totals.sessionSec == Int(10.5 * H) && r.totals.jiraSec == 0 && r.days.count == 4)
        #expect(r.tasks.allSatisfy { [.onlySessions, .zagonOnly, .noTask].contains($0.status) })
        #expect(ReconcileText.text(r).contains("note: Jira failed, sessions only: jira: curl exit 7"))
    }
}

@Suite struct ReconcileNoJiraTests {
    @Test func withoutJiraAllIsSessions() throws {
        let f = try Fixture(), t = Tasks(store: f.store)
        try t.add(title: "dialogs", key: "PROJ-1")
        let w = DayWorklog(store: f.store, linker: try TaskLinker(), jira: nil)
        #expect(try w.reconcile(from: "2026-10-29", to: "2026-10-29", today: reconcileToday).coverageFrom == nil)
        try f.session("claude:a", branch: "PROJ-1", title: "Dialog work", working: [(D0 + 8 * H, D0 + 11 * H)])
        let r = try w.reconcile(from: "2026-10-28", to: "2026-10-30", today: reconcileToday)
        #expect(r.jira == "not_connected" && r.days.map(\.day) == ["2026-10-29"])
        #expect(r.tasks.map(\.status) == [.onlySessions] && r.totals.unloggedSec == 3 * 3600)
        #expect(ReconcileText.markdown(r).contains("> Jira not connected: sessions only"))
        #expect(!ReconcileText.text(r).contains("in Jira"))

        let bad = DayWorklog(store: f.store, linker: try TaskLinker(), jira: nil, jiraSetupError: "cannot read token")
        let rb = try bad.reconcile(from: "2026-10-29", to: "2026-10-29", today: reconcileToday)
        #expect(rb.jira == "failed" && rb.jiraError == "cannot read token" && rb.totals.sessionSec == 3 * 3600)

        #expect(throws: TaskError.self) { try w.reconcile(from: "2026-10-30", to: "2026-10-29", today: reconcileToday) }
        #expect(throws: TaskError.self) { try w.reconcile(from: "2026-10-29", to: "29.10.2026", today: reconcileToday) }
        #expect(throws: TaskError.self) { try w.reconcile(from: "2025-01-01", to: "2026-10-29", today: reconcileToday) }
        #expect(throws: TaskError.self) { try w.reconcile(from: "2026-02-31", to: "2026-10-29", today: reconcileToday) }
        // Not zero-padded: the same days as padded ones.
        let loose = try w.reconcile(from: "2026-10-9", to: "2026-10-30", today: "2026-11-3")
        #expect(loose.from == "2026-10-09" && loose.to == "2026-10-30" && loose.days.map(\.day) == ["2026-10-29"])
    }

    /// A range into the future is counted to today and says so; a range that starts after today is refused.
    @Test func futureIsCutAtToday() throws {
        let f = try Fixture()
        try f.session("claude:a", working: [(D0 + 8 * H, D0 + 9 * H)])
        let w = DayWorklog(store: f.store, linker: try TaskLinker(), jira: nil)
        let r = try w.reconcile(from: "2026-10-29", to: "2026-11-27", today: "2026-10-29")
        #expect(r.to == "2026-10-29" && r.toRequested == "2026-11-27" && r.totals.noTaskSec == 3600)
        #expect(ReconcileText.text(r).contains("note: 2026-11-27 has not come yet: counted to 2026-10-29"))
        let e = #expect(throws: TaskError.self) { try w.reconcile(from: "2026-10-30", to: "2026-11-27", today: "2026-10-29") }
        #expect(e?.description.contains("after today") == true)
    }
}
