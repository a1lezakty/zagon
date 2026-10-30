import Foundation
import Testing
@testable import ZagonCore

/// The task list is built from work; Jira (`JiraCache`) is a reference for keys and statuses.
@Suite struct TaskListTests {
    static func issue(_ k: String, _ status: String, _ cat: String, _ summary: String = "summary") -> JiraIssue {
        JiraIssue(key: k, summary: summary, status: status, statusCategory: cat)
    }

    @Test func jiraStatusesByNameThenCategory() {
        let cases: [(String, String, TaskStatus)] = [
            ("Ready to release", "new", .review), ("Ready to test", "new", .review), ("Code Review", "indeterminate", .review),
            ("QA", "indeterminate", .review), ("На проверке", "indeterminate", .review), ("Готово к релизу", "new", .review),
            ("В работе", "indeterminate", .inProgress), ("Tech Design", "indeterminate", .inProgress), ("Backlog", "new", .planned),
            ("Готово", "done", .done), ("Tested and closed", "done", .done), ("", "", .planned),
        ]
        for (name, cat, want) in cases { #expect(TaskStatus(jira: Self.issue("P-1", name, cat)) == want, "\(name)") }
        let text = """
            [jira]
            url = "https://example.atlassian.net"
            email = "me@example.com"
            token_file = "/nowhere"
            review_statuses = ["Staging", "UAT"]   # ours
            """
        let review = JiraConfig.load(configText: text)!.reviewStatuses
        #expect(review == ["Staging", "UAT"])
        #expect(TaskStatus(jira: Self.issue("P-1", "On staging", "indeterminate"), review: review) == .review)
        #expect(TaskStatus(jira: Self.issue("P-1", "Ready to release", "new"), review: review) == .planned)
        #expect(JiraConfig.load(configText: text.replacingOccurrences(of: "review_statuses = [\"Staging\", \"UAT\"]", with: ""))!
            .reviewStatuses == JiraConfig.defaultReview)
        #expect(JiraConfig.stringList(#"[]"#) == [] && JiraConfig.stringList(#""a""#) == nil)
    }

    func cache(_ f: Fixture, _ issues: [JiraIssue], mine: [String], logged: [String] = []) throws {
        var c = JiraCache()
        c.at = D0
        for i in issues { c.issues[i.key] = i }
        c.mine = Set(mine); c.logged = Set(logged)
        try c.save(f.store, tried: D0)
    }

    /// Main list: work in the last 7 days, TODO / notes, Jira worklogs, own open tasks; the rest only with `all`.
    @Test func mainListIsWhatWasWorkedOn() throws {
        let f = try Fixture(), t = Tasks(store: f.store), now = D0 + 20 * H
        let imported = try t.add(title: "backlog issue", key: "PROJ-1")
        let worked = try t.add(title: "worked", key: "PROJ-2")
        let own = try t.add(title: "own idea")
        let oldDone = try t.add(title: "old own", status: .done, at: D0 - 30 * 86400)
        let noted = try t.add(title: "with a note", key: "PROJ-3")
        try t.addNote(noted.id, "remember")
        let old = try t.add(title: "worked long ago", key: "PROJ-4")
        let logged = try t.add(title: "logged in Jira", key: "PROJ-5")
        try f.session("claude:a", branch: "PROJ-2-x", working: [(D0 + 9 * H, D0 + 11 * H)], actions: [D0 + 9 * H])
        try f.session("claude:b", branch: "PROJ-4", working: [(D0 - 10 * 86400, D0 - 10 * 86400 + H)])
        // A key typed long ago in a session that is still going: that link is not work of the last 7 days.
        try f.session("claude:c", working: [(D0 - 30 * 86400, D0 - 30 * 86400 + H), (D0 + 12 * H, D0 + 13 * H)])
        try f.message("claude:c", D0 - 30 * 86400, keys: ["PROJ-4"])
        try cache(f, [Self.issue("PROJ-1", "Ready to release", "new", "backlog issue"), Self.issue("OPS-9", "Backlog", "new", "not a task"),
                      Self.issue("OPS-8", "Done", "done", "finished")], mine: ["PROJ-1", "OPS-9", "OPS-8"], logged: ["PROJ-5"])
        try TaskLinker().linkSessions(f.store)

        let main = try t.overview(now: now)
        #expect(Set(main.map(\.task.id)) == [worked.id, own.id, noted.id, logged.id])
        #expect(main.first?.task.id == worked.id && main.first!.weekSec == 2 * H)   // most time first
        let all = try t.overview(all: true, now: now)
        #expect(Set(all.filter { $0.worked == false }.map(\.task.key)) == ["PROJ-1", "PROJ-4", "ZAG-2", "OPS-9"])
        #expect(!all.contains { $0.task.key == "OPS-8" })   // done in Jira and no task here: not listed at all
        let ops = all.first { $0.task.key == "OPS-9" }!
        #expect(ops.task.id == 0 && ops.jiraStatus == "Backlog" && ops.task.title == "not a task")
        #expect(all.first { $0.task.id == imported.id }?.jiraStatus == "Ready to release")
        #expect(try t.overview(status: .done, all: true, now: now).map(\.task.id) == [oldDone.id])
        _ = old

        let text = TaskText.list(all, all: false)
        #expect(text.contains("PROJ-2") && !text.contains("PROJ-1 ") && text.hasSuffix("+ 3 more open in Jira with no work here in the last 7 days: task list --all"))
        let full = TaskText.list(all, all: true)
        #expect(full.contains("\nIn Jira, no work here in the last 7 days:\n") && full.contains("OPS-9 ") && full.contains("(not a task here yet)"))
        #expect(TaskText.list([], all: false) == "No tasks worked on in the last 7 days.")

        // An issue only in Jira is shown as is and becomes a task once changed.
        #expect(try t.find("OPS-9") == nil && t.jiraOnly("ops-9")?.title == "not a task")
        let adopted = try #require(try t.findOrAdopt("OPS-9"))
        #expect(adopted.id > 0 && adopted.key == "OPS-9" && adopted.jiraKey == "OPS-9" && adopted.status == .planned)
        #expect(try t.findOrAdopt("NOPE-1") == nil)
    }

    /// Keys of work that are your Jira issues become tasks; other keys stay unknown.
    @Test func workKeysOfYourIssuesBecomeTasks() throws {
        let f = try Fixture(), t = Tasks(store: f.store)
        try cache(f, [Self.issue("PROJ-7", "Ready to test", "new", "Dialog strategies"), Self.issue("PROJ-8", "To Do", "new", "typed one")],
                  mine: ["PROJ-7", "PROJ-8"])
        try f.session("claude:a", branch: "PROJ-7-dialogs", working: [(D0 + 9 * H, D0 + 10 * H)])
        try f.session("claude:b", working: [(D0 + 11 * H, D0 + 12 * H)])
        try f.message("claude:b", D0 + 11 * H, keys: ["PROJ-8", "OTHER-1"])
        try TaskLinker().linkSessions(f.store)
        let p7 = try #require(try t.find("PROJ-7")), p8 = try #require(try t.find("PROJ-8"))
        #expect(p7.title == "Dialog strategies" && p7.status == .review && p7.jiraKey == "PROJ-7")
        #expect(try t.links(p7.id).map(\.how) == ["branch"] && t.links(p8.id).map(\.how) == ["message"])
        #expect(try t.find("OTHER-1") == nil)
        #expect(try TaskLinker().unknownKeys(f.store, from: D0, to: D0 + 86400).keys.sorted() == ["OTHER-1"])
        // Linking again adds nothing new.
        try TaskLinker().linkSessions(f.store)
        #expect(try t.list().count == 2)
    }
}

@Suite(.enabled(if: hasTool("python3") && hasTool("curl"), "needs python3 and curl"), .timeLimit(.minutes(1)))
struct JiraCacheTests {
    static let state = """
        {"me": "acc-me", "issues": {
          "PROJ-1": {"summary": "Dialogs", "status": "Ready to release", "category": "new", "assignee": "acc-me",
                     "worklogs": [{"id": "1", "author": "acc-me", "started": "2026-10-29T08:00:00.000+0200", "seconds": 3600}]},
          "PROJ-2": {"summary": "Done one", "status": "Done", "category": "done", "assignee": "acc-me"},
          "OPS-3": {"summary": "Not mine", "status": "In Progress", "category": "indeterminate", "assignee": "acc-other"},
          "OPS-4": {"summary": "Stand", "status": "To Do", "category": "new", "assignee": "acc-me"}}}
        """

    @Test func refreshReadsYoursAndTasksAndFollowsStatusChanges() throws {
        let m = try JiraMock(state: Self.state), j = try JiraClient(m.config)
        let f = try Fixture(), t = Tasks(store: f.store)
        let p1 = try t.add(title: "dialogs", key: "PROJ-1")            // imported earlier as planned
        let o3 = try t.add(title: "colleague's", key: "OPS-3")
        let own = try t.add(title: "own")
        let c = try JiraCache.refresh(f.store, j, now: D0)
        #expect(c.mine == ["PROJ-1", "OPS-4"] && Set(c.issues.keys) == ["PROJ-1", "OPS-4", "OPS-3"] && c.logged == ["PROJ-1"])
        #expect(JiraCache.load(f.store) == c)
        // First read: Jira's status is taken.
        #expect(try t.get(p1.id)?.status == .review && t.get(o3.id)?.status == .inProgress && t.get(own.id)?.status == .planned)
        // Set by hand: stays while Jira's status does not change...
        try t.setStatus(p1.id, .done)
        try JiraCache.refresh(f.store, j, now: D0 + 1)
        #expect(try t.get(p1.id)?.status == .done)
        // ...and follows Jira when it does.
        var old = JiraCache.load(f.store)
        old.issues["PROJ-1"]!.status = "In Progress"
        try old.save(f.store, tried: D0 + 1)
        try JiraCache.refresh(f.store, j, now: D0 + 2)
        #expect(try t.get(p1.id)?.status == .review)
    }

    @Test func readAgainOnlyWhenOldAndNotJustFailed() throws {
        let m = try JiraMock(state: Self.state), j = try JiraClient(m.config)
        let f = try Fixture()
        #expect(JiraCache.current(f.store, nil, now: D0) == JiraCache())
        let first = JiraCache.current(f.store, j, now: D0)
        #expect(first.at == D0 && first.mine.count == 2)
        #expect(JiraCache.current(f.store, j, now: D0 + 600).at == D0)                  // fresh: Jira not asked
        var bad = m.config
        bad.baseURL = "http://127.0.0.1:9"                                                // nothing listens there
        var logs: [String] = []
        let kept = JiraCache.current(f.store, try JiraClient(bad), now: D0 + 2 * H) { logs.append($0) }
        #expect(kept.at == D0 && kept.mine == first.mine && logs.count == 1)
        #expect(JiraCache.current(f.store, j, now: D0 + 2 * H + 60).at == D0)             // failed a minute ago: not again yet
        #expect(JiraCache.current(f.store, j, now: D0 + 2 * H + 700).at == D0 + 2 * H + 700)
    }
}
