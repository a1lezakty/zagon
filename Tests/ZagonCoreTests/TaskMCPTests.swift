import Foundation
import Testing
@testable import ZagonCore

/// task_* and worklog_* through the MCP server with the real TaskTools (MCPFixture: synthetic sessions on 2026-10-29,
/// session A on branch PROJ-1-x worked 10:00–10:05 UTC).
struct TaskMCP {
    let f: MCPFixture
    let server: MCPServer
    let tools: TaskTools

    init(jira: JiraClient? = nil) throws {
        f = try MCPFixture()
        let store = f.store
        tools = TaskTools(store: store, worklog: { DayWorklog(store: store, linker: try TaskLinker(), jira: jira) },
                          exportDir: f.dir + "/exports", now: { Time.parseISO("2026-10-29T12:00:00Z")! })
        server = ZagonMCP.server(store: f.store, exportDir: f.dir + "/exports", tasks: tools)
    }

    func call(_ tool: String, _ args: String) throws -> (text: String, isError: Bool) {
        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(args)}}"#
        let out = try #require(server.handle(line))
        let r = try #require(JValue.parse(out))
        let res = try #require(r["result"], "\(r.compact)")
        return (res["content"]?.array?.first?["text"]?.string ?? "", res["isError"] == .bool(true))
    }
}

private let day = "2026-10-29"

@Suite struct TaskMCPTests {
    @Test func createGetUpdateList() throws {
        let m = try TaskMCP()
        let c = try m.call("task_create", #"{"title":"Parser work","key":"proj-1","description":"split the parser"}"#)
        #expect(!c.isError && c.text.hasPrefix("Created PROJ-1: Parser work (Jira PROJ-1)") && c.text.contains("linked 1 sessions"), "\(c.text)")
        #expect(try m.call("task_create", #"{"title":"own one"}"#).text.hasPrefix("Created ZAG-1"))
        let dup = try m.call("task_create", #"{"title":"again","key":"PROJ-1"}"#)
        #expect(dup.isError && dup.text.contains("already exists"))
        // Blank optional fields are "not given": an own key, no Jira issue.
        #expect(try m.call("task_create", #"{"title":"blank","key":"","jira_key":" ","description":""}"#).text == "Created ZAG-2: blank")
        // A bad TODO number with other changes: nothing is saved.
        let bad = try m.call("task_update", #"{"ref":"ZAG-2","note":"kept?","todo_done":3}"#)
        #expect(bad.isError && bad.text.contains("no TODO #3"))
        let blank = try #require(try Tasks(store: m.f.store).find("ZAG-2"))
        #expect(try Tasks(store: m.f.store).notes(blank.id).isEmpty && blank.jiraKey == nil && blank.description == nil)

        let u = try m.call("task_update", #"{"ref":"PROJ-1","status":"in_progress","note":"n1","todo":"write tests","done":"split done"}"#)
        #expect(!u.isError && u.text == "PROJ-1 updated; status in_progress, note added, TODO added, what was done today set", "\(u.text)")
        #expect(try m.call("task_update", #"{"ref":"PROJ-1","todo_done":1}"#).text == "PROJ-1 updated; TODO #1 done")
        #expect(try m.call("task_update", #"{"ref":"PROJ-1","todo_done":5}"#).isError)
        #expect(try m.call("task_update", #"{"ref":"ZAG-1"}"#).text == "ZAG-1: nothing to change")
        #expect(try m.call("task_update", #"{"ref":"ZAG-1","jira_key":"PROJ-1"}"#).isError)   // the issue belongs to PROJ-1
        #expect(try m.call("task_get", #"{"ref":"NOPE-1"}"#).isError)

        let g = try m.call("task_get", #"{"ref":"proj-1"}"#).text
        for want in ["PROJ-1  in_progress  Parser work", "split the parser", "1. [x] write tests", "2026-10-29  split done", "n1",
                     "claude:aaaaaaaa-1111-2222-3333-444444444444  branch", "Jira not connected"] {
            #expect(g.contains(want), "\(want) in \(g)")
        }
        let l = try m.call("task_list", #"{"status":"in_progress"}"#).text
        #expect(l.hasPrefix("PROJ-1     in_progress worked 5m in 7d       1 session    Parser work") && !l.contains("ZAG-1"), "\(l)")
        // A task with no work in the last 7 days comes only with all: true.
        _ = try m.call("task_create", #"{"title":"Later","key":"OPS-5"}"#)
        #expect(try !m.call("task_list", "{}").text.contains("OPS-5"))
        #expect(try m.call("task_list", #"{"all":true}"#).text.contains("In Jira, no work here in the last 7 days:\nOPS-5"))
    }

    @Test func planWithoutJiraAndCommitRefused() throws {
        let m = try TaskMCP()
        _ = try m.call("task_create", #"{"title":"Parser work","key":"PROJ-1"}"#)
        let p = try m.call("worklog_plan", #"{"date":"\#(day)"}"#)
        #expect(!p.isError && p.text.contains("PROJ-1") && p.text.contains("10:00–10:05") && p.text.contains("Nothing was written"), "\(p.text)")
        let c = try m.call("worklog_commit", #"{"date":"\#(day)","confirm":true}"#)
        #expect(c.isError && c.text.contains("Jira is not connected") && c.text.contains("nothing was written"))
    }

    /// worklog_text / worklog_skip on the real plan; status says what is left to log.
    @Test func planEdits() throws {
        let m = try TaskMCP()
        _ = try m.call("task_create", #"{"title":"Parser work","key":"PROJ-1"}"#)
        _ = try m.call("worklog_plan", #"{"date":"\#(day)"}"#)
        let id = try #require(Worklog(store: m.f.store).rows(day: day).first { $0.state == "planned" }?.id)
        let st = try m.call("status", "{}").text
        #expect(st.contains("\nto log today: 2026-10-29: worked 7m · sessions 7m · Jira not connected · to log to Jira 5m") && st.contains("(1 row; worklog_plan shows them)"), "\(st)")
        let t = try m.call("worklog_text", #"{"id":\#(id),"text":"Split the parser","confirm":true}"#)
        #expect(!t.isError && t.text.contains("#\(id)") && t.text.contains("Split the parser") && t.text.contains("[manual]"), "\(t.text)")
        #expect(try m.call("worklog_plan", #"{"date":"\#(day)"}"#).text.contains("Split the parser"))
        #expect(try m.call("worklog_text", #"{"id":\#(id + 100),"text":"x","confirm":true}"#).text.contains("No plan row"))
        #expect(try m.call("worklog_text", #"{"id":\#(id),"text":"","confirm":true}"#).text.contains("[manual]") == false)
        let s = try m.call("worklog_skip", #"{"ids":[\#(id), \#(id + 100)],"confirm":true}"#).text
        #expect(s.contains("skipped #\(id) 2026-10-29 PROJ-1 ") && s.contains("#\(id + 100): no planned row"), "\(s)")
        #expect(try Worklog(store: m.f.store).rows(day: day).first { $0.id == id }?.state == "skipped")
    }

    @Test func reconcileWithoutJira() throws {
        let m = try TaskMCP()
        _ = try m.call("task_create", #"{"title":"Parser work","key":"PROJ-1"}"#)
        let r = try m.call("worklog_reconcile", #"{"from":"\#(day)","to":"2026-11-05","format":"md"}"#)
        #expect(!r.isError && r.text.hasPrefix("# Worklogs against sessions: 2026-10-29 – 2026-10-29") && r.text.contains("| PROJ-1 | PROJ-1 | Parser work |")
                && r.text.contains("Jira not connected"), "\(r.text)")
        // text by default; an answer over the limit goes to a file, with the totals per task.
        let t = try m.call("worklog_reconcile", #"{"from":"\#(day)"}"#).text
        #expect(t.hasPrefix("2026-10-29 – 2026-10-29: worked ") && t.contains("\ndays:\n"), "\(t)")
        m.tools.maxInline = 100
        let big = try m.call("worklog_reconcile", #"{"from":"\#(day)"}"#).text
        let path = m.f.dir + "/exports/reconcile-2026-10-29-2026-10-29.txt"
        #expect(big.hasPrefix("Wrote \(path) (\(t.utf8.count) bytes, text)") && big.contains("PROJ-1") && !big.contains("days:"), "\(big)")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == t)
        m.tools.maxInline = 24_000
        let j = try m.call("worklog_reconcile", #"{"from":"\#(day)","format":"json"}"#).text
        #expect(JValue.parse(j)?["tasks"]?.array?.first?["status"]?.string == "only_sessions", "\(j)")
        #expect(try m.call("worklog_reconcile", #"{"from":"\#(day)","format":"xml"}"#).isError)
        #expect(try m.call("worklog_reconcile", "{}").isError)
    }
}

@Suite(.enabled(if: hasTool("python3") && hasTool("curl"), "needs python3 and curl"), .timeLimit(.minutes(1)))
struct TaskMCPJiraTests {
    static let state = #"{"me": "acc-me", "issues": {"PROJ-1": {"summary": "Parser", "status": "In Progress", "category": "indeterminate", "assignee": "acc-me"}}}"#

    @Test func commitWritesExactlyWhatWasShown() throws {
        let mock = try JiraMock(state: Self.state)
        let m = try TaskMCP(jira: try JiraClient(mock.config))
        _ = try m.call("task_create", #"{"title":"Parser work","key":"PROJ-1"}"#)

        // Not shown yet by this server: refused.
        let early = try m.call("worklog_commit", #"{"date":"\#(day)","confirm":true}"#)
        #expect(early.isError && early.text.contains("Call worklog_plan for \(day) first"), "\(early.text)")
        #expect((try mock.state()["issues"] as! [String: [String: Any]])["PROJ-1"]!["worklogs"] == nil)

        // A row id that is not in the plan: refused, nothing written.
        let plan = try m.call("worklog_plan", #"{"date":"\#(day)"}"#).text
        let id = try #require(Worklog(store: m.f.store).rows(day: day).first?.id)
        #expect(plan.contains("#\(id) "))
        #expect(try m.call("worklog_commit", #"{"date":"\#(day)","confirm":true,"ids":[\#(id + 100)]}"#).isError)

        let ok = try m.call("worklog_commit", #"{"date":"\#(day)","confirm":true,"ids":[\#(id)]}"#)
        #expect(!ok.isError && ok.text.contains("logged #\(id) PROJ-1") && ok.text.hasSuffix("1 worklogs written to Jira"), "\(ok.text)")
        let ws = try #require((try mock.state()["issues"] as! [String: [String: Any]])["PROJ-1"]!["worklogs"] as? [[String: Any]])
        #expect(ws.count == 1 && ws[0]["seconds"] as? Int == 300 && ws[0]["started"] as? String == "2026-10-29T10:00:00.000+0000")

        // Planned again: the row is logged, Jira shows it, nothing is left to write.
        let again = try m.call("worklog_plan", #"{"date":"\#(day)"}"#).text
        #expect(again.contains("logged") && again.contains("in Jira 5m"), "\(again)")
        #expect(try m.call("worklog_commit", #"{"date":"\#(day)","confirm":true}"#).text == "Nothing to write to Jira for \(day).")
        #expect(try m.call("worklog_commit", #"{"date":"\#(day)","confirm":false}"#).isError)
    }

    /// A text set through worklog_text after the plan was shown counts as shown: commit writes it.
    @Test func commitWritesTheEditedText() throws {
        let mock = try JiraMock(state: Self.state)
        let m = try TaskMCP(jira: try JiraClient(mock.config))
        _ = try m.call("task_create", #"{"title":"Parser work","key":"PROJ-1"}"#)
        _ = try m.call("worklog_plan", #"{"date":"\#(day)"}"#)
        let id = try #require(Worklog(store: m.f.store).rows(day: day).first?.id)
        #expect(try !m.call("worklog_text", #"{"id":\#(id),"text":"Split the parser","confirm":true}"#).isError)
        let ok = try m.call("worklog_commit", #"{"date":"\#(day)","confirm":true}"#)
        #expect(!ok.isError && ok.text.hasSuffix("1 worklogs written to Jira"), "\(ok.text)")
        let ws = try #require((try mock.state()["issues"] as! [String: [String: Any]])["PROJ-1"]!["worklogs"] as? [[String: Any]])
        #expect(ws.count == 1 && ws[0]["comment"] as? String == "Split the parser")
    }

    /// Anything that changes a shown row before the commit (its Jira issue, new work re-planned by another process,
    /// a reused row id) makes the commit refuse and return the new plan; nothing reaches Jira.
    @Test func changedRowsAreNotWritten() throws {
        let mock = try JiraMock(state: #"{"me": "acc-me", "issues": {"PROJ-1": {"summary": "P", "status": "To Do", "category": "new"}, "PROJ-9": {"summary": "Q", "status": "To Do", "category": "new"}}}"#)
        let m = try TaskMCP(jira: try JiraClient(mock.config))
        _ = try m.call("task_create", #"{"title":"Parser work","key":"PROJ-1"}"#)
        _ = try m.call("worklog_plan", #"{"date":"\#(day)"}"#)
        let id = try #require(Worklog(store: m.f.store).rows(day: day).first?.id)

        // The task's Jira issue changed after the plan was shown.
        _ = try m.call("task_update", #"{"ref":"PROJ-1","jira_key":"PROJ-9"}"#)
        for args in [#"{"date":"\#(day)","confirm":true}"#, #"{"date":"\#(day)","confirm":true,"ids":[\#(id)]}"#] {
            let c = try m.call("worklog_commit", args)
            #expect(c.isError && c.text.contains("nothing was written") && c.text.contains("PROJ-1"), "\(c.text)")
            _ = try m.call("task_update", #"{"ref":"PROJ-1","jira_key":"PROJ-1"}"#)
            _ = try m.call("worklog_plan", #"{"date":"\#(day)"}"#)
            _ = try m.call("task_update", #"{"ref":"PROJ-1","jira_key":"PROJ-9"}"#)
        }
        _ = try m.call("task_update", #"{"ref":"PROJ-1","jira_key":"PROJ-1"}"#)
        _ = try m.call("worklog_plan", #"{"date":"\#(day)"}"#)

        // More work, re-planned by another process (CLI): the row the model showed is no longer the plan.
        try m.f.store.db.run("UPDATE activity SET \"end\" = \"end\" + 1800 WHERE session_id LIKE 'claude:aaaa%'")
        _ = try DayWorklog(store: m.f.store, linker: try TaskLinker(), jira: nil).plan(day)
        let c = try m.call("worklog_commit", #"{"date":"\#(day)","confirm":true,"ids":[\#(id)]}"#)
        #expect(c.isError && c.text.contains("not exactly as shown"), "\(c.text)")
        let issues = try mock.state()["issues"] as! [String: [String: Any]]
        #expect(issues["PROJ-1"]!["worklogs"] == nil && issues["PROJ-9"]!["worklogs"] == nil)
    }

    func worklogCount(_ mock: JiraMock, _ key: String = "PROJ-1") throws -> Int {
        ((try mock.state()["issues"] as! [String: [String: Any]])[key]!["worklogs"] as? [[String: Any]])?.count ?? 0
    }

    /// Jira took the POST but its answer was lost, and its search does not show the worklog yet: the row stays
    /// `writing`; a commit with the old rows finds the worklog on the issue itself, and the next plan marks it logged.
    /// Nothing is written twice.
    @Test func lostReplyIsNotWrittenTwice() throws {
        let mock = try JiraMock(state: #"{"me": "acc-me", "lose_post_replies": 1, "search_lag": true, "issues": {"PROJ-1": {"summary": "Parser", "status": "In Progress", "category": "indeterminate", "assignee": "acc-me"}}}"#)
        let m = try TaskMCP(jira: try JiraClient(mock.config))
        _ = try m.call("task_create", #"{"title":"Parser work","key":"PROJ-1"}"#)
        let w = DayWorklog(store: m.f.store, linker: try TaskLinker(), jira: try JiraClient(mock.config))
        let rows = try w.plan(day).plan.rows
        let r1 = try w.write(rows, day: day)
        #expect(r1.logged == 0 && r1.failed == 1 && r1.lines.last?.contains("not sure") == true, "\(r1.lines)")
        let states = try Worklog(store: m.f.store).rows(day: day).map(\.state), n1 = try worklogCount(mock)
        #expect(states == ["writing"] && n1 == 1)

        // The same rows again (a retry): the row is settled from the issue's own list, no second POST.
        let again = try w.write(rows, day: day)
        #expect(again.logged == 1 && again.lines.contains { $0.contains("already in Jira") || $0.contains("is in Jira") }, "\(again.lines)")
        #expect(try worklogCount(mock) == 1)
        let row = try #require(try Worklog(store: m.f.store).rows(day: day).first)
        #expect(row.state == "logged" && row.jiraWorklogId != nil)

        // Planned again while the search still lags: nothing new to write.
        let p = try w.plan(day).plan
        #expect(p.rows.map(\.state) == ["logged"], "\(p.rows)")
        let r3 = try w.write(p.rows, day: day), n3 = try worklogCount(mock)
        #expect(r3.logged == 0 && n3 == 1)
    }

    /// The plan settles a row left `writing` by a lost reply (marked logged), so commit has nothing to write.
    @Test func planSettlesALostReply() throws {
        let mock = try JiraMock(state: #"{"me": "acc-me", "lose_post_replies": 1, "search_lag": true, "issues": {"PROJ-1": {"summary": "Parser", "status": "In Progress", "category": "indeterminate", "assignee": "acc-me"}}}"#)
        let m = try TaskMCP(jira: try JiraClient(mock.config))
        _ = try m.call("task_create", #"{"title":"Parser work","key":"PROJ-1"}"#)
        let w = DayWorklog(store: m.f.store, linker: try TaskLinker(), jira: try JiraClient(mock.config))
        _ = try w.write(try w.plan(day).plan.rows, day: day)
        let p = try w.plan(day).plan
        #expect(p.rows.map(\.state) == ["logged"] && p.notes.contains { $0.contains("is in Jira: marked logged") }, "\(p.notes)")
        let n = try worklogCount(mock)
        #expect(p.rows.filter { $0.state == "planned" }.isEmpty && n == 1)
    }

    /// A 5xx may have been done: the row stays `writing` until its claim is old, then (not in Jira) it is planned
    /// again and written once. A 4xx was refused: planned again at once.
    @Test func unknownAndRefusedPosts() throws {
        let mock = try JiraMock(state: #"{"me": "acc-me", "post_status": [500, 400], "issues": {"PROJ-1": {"summary": "Parser", "status": "In Progress", "category": "indeterminate", "assignee": "acc-me"}}}"#)
        let m = try TaskMCP(jira: try JiraClient(mock.config))
        _ = try m.call("task_create", #"{"title":"Parser work","key":"PROJ-1"}"#)
        let w = DayWorklog(store: m.f.store, linker: try TaskLinker(), jira: try JiraClient(mock.config))
        let t0 = Time.now()
        let r1 = try w.write(try w.plan(day).plan.rows, day: day, now: t0)
        let n0 = try worklogCount(mock)
        #expect(r1.failed == 1 && r1.lines.last?.contains("not sure") == true && n0 == 0)
        #expect(try w.settle(day, now: t0 + 60).isEmpty)                                    // may still be in flight
        #expect(try w.settle(day, now: t0 + 400).first?.contains("did not reach Jira: planned again") == true)
        let r2 = try w.write(try Worklog(store: m.f.store).rows(day: day), day: day)        // the 400
        #expect(r2.failed == 1 && r2.lines.last?.contains("HTTP 400") == true)
        #expect(try Worklog(store: m.f.store).rows(day: day).map(\.state) == ["planned"])
        let r3 = try w.write(try Worklog(store: m.f.store).rows(day: day), day: day)
        let n3 = try worklogCount(mock)
        #expect(r3.logged == 1 && n3 == 1)
    }

    /// A row of an issue Jira does not have (404) fails alone: the others are written and reported; a `writing` row
    /// on such an issue is settled (planned again once its claim is old) instead of breaking the plan.
    @Test func aMissingIssueFailsOnlyItsRow() throws {
        let mock = try JiraMock(state: #"{"me": "acc-me", "issues": {"PROJ-1": {"summary": "Parser", "status": "In Progress", "category": "indeterminate", "assignee": "acc-me"}}}"#)
        let m = try TaskMCP(jira: try JiraClient(mock.config))
        _ = try m.call("task_create", #"{"title":"Parser work","key":"PROJ-1"}"#)
        _ = try m.call("task_create", #"{"title":"Gone","key":"NOPE-1"}"#)
        let nope = try #require(try Tasks(store: m.f.store).find("NOPE-1"))
        let w = DayWorklog(store: m.f.store, linker: try TaskLinker(), jira: try JiraClient(mock.config))
        _ = try w.plan(day)
        let at = Time.parseISO("2026-10-29T11:00:00Z")!
        try m.f.store.db.run("INSERT INTO worklog_plan(day, task_id, start, \"end\", seconds, text, state) VALUES(?, ?, ?, ?, 300, 'x', 'planned')",
                             [.text(day), .int(Int64(nope.id)), .real(at), .real(at + 300)])
        let r = try w.write(try Worklog(store: m.f.store).rows(day: day), day: day)
        #expect(r.logged == 1 && r.failed == 1, "\(r.lines)")
        #expect(r.lines.contains { $0.hasPrefix("logged #") && $0.contains("PROJ-1") } && r.lines.contains { $0.contains("NOPE-1") && $0.contains("404") })

        try m.f.store.db.run("UPDATE worklog_plan SET state = 'writing' WHERE task_id = ?", [.int(Int64(nope.id))])
        #expect(try w.settle(day).first?.contains("NOPE-1") == true)                       // no claim record: old
        #expect(try Worklog(store: m.f.store).rows(day: day).first { $0.taskId == nope.id }?.state == "planned")
    }

    /// The claim records the moment it is made, not the start of the write: a slow commit's late rows are not seen
    /// as abandoned by another process. An answer that does not decode after a 2xx leaves the row writing; the next
    /// write finds the worklog and posts nothing.
    @Test func claimTimeAndBadAnswers() throws {
        let mock = try JiraMock(state: #"{"me": "acc-me", "post_status": [500], "bad_post_bodies": 1, "issues": {"PROJ-1": {"summary": "Parser", "status": "In Progress", "category": "indeterminate", "assignee": "acc-me"}}}"#)
        let m = try TaskMCP(jira: try JiraClient(mock.config))
        _ = try m.call("task_create", #"{"title":"Parser work","key":"PROJ-1"}"#)
        let w = DayWorklog(store: m.f.store, linker: try TaskLinker(), jira: try JiraClient(mock.config))
        let rows = try w.plan(day).plan.rows
        _ = try w.write(rows, day: day, now: Time.now() - 400)                            // the 500: left writing
        #expect(try w.settle(day).isEmpty)                                                  // claimed just now: in flight
        try m.f.store.db.run("UPDATE meta SET value = value - 400 WHERE key LIKE 'worklog:claim:%'")
        #expect(try w.settle(day).first?.contains("planned again") == true)

        let r = try w.write(try Worklog(store: m.f.store).rows(day: day), day: day)        // stored, answer not JSON
        let n1 = try worklogCount(mock)
        #expect(r.failed == 1 && r.lines.last?.contains("not sure") == true && n1 == 1, "\(r.lines)")
        let again = try w.write(rows, day: day)
        let n2 = try worklogCount(mock)
        #expect(again.lines.contains { $0.contains("in Jira") } && n2 == 1, "\(again.lines)")
    }

    @Test func aClaimedRowIsNotWrittenTwice() throws {
        let mock = try JiraMock(state: Self.state)
        let m = try TaskMCP(jira: try JiraClient(mock.config))
        _ = try m.call("task_create", #"{"title":"Parser work","key":"PROJ-1"}"#)
        let w = DayWorklog(store: m.f.store, linker: try TaskLinker(), jira: try JiraClient(mock.config))
        let rows = try w.plan(day).plan.rows
        // Another writer claimed it just now (state and claim time, as DayWorklog.write does).
        try m.f.store.db.run("UPDATE worklog_plan SET state = 'writing' WHERE id = ?", [.int(Int64(rows[0].id))])
        try m.f.store.db.run("INSERT INTO meta(key, value) VALUES(?, ?)", [.text("worklog:claim:\(rows[0].id)"), .real(Time.now())])
        let r = try w.write(rows, day: day)
        #expect(r.logged == 0 && r.failed == 1 && r.lines[0].contains("already being written"))
        #expect((try mock.state()["issues"] as! [String: [String: Any]])["PROJ-1"]!["worklogs"] == nil)
    }
}

@Suite struct TaskMCPSuggestTests {
    /// task_suggestions lists (makes) the day's suggestions; the answer needs confirm: true and changes the links.
    @Test func suggestionsThroughMCP() throws {
        let x = try SuggestFixture()
        let a = try x.tasks.add(title: "Encoder research", key: "PROJ-1")
        try x.tasks.setStatus(a.id, .inProgress)
        try x.f.session("claude:s1", title: "encoder gains", working: [(D0 + 9 * H, D0 + 10 * H)])
        x.calls.answer = #"[{"segment": "S1", "key": "PROJ-1", "confidence": 0.9, "reason": "encoder"}]"#
        let store = x.f.store, s = x.s
        let tools = TaskTools(store: store, worklog: { DayWorklog(store: store, linker: try TaskLinker(), jira: nil) },
                              suggester: { s }, now: { D0 + 20 * H })
        let server = ZagonMCP.server(store: store, exportDir: tempDir(), tasks: tools)
        func call(_ tool: String, _ args: String) throws -> (text: String, isError: Bool) {
            let out = try #require(server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(args)}}"#))
            let res = try #require(JValue.parse(out)?["result"])
            return (res["content"]?.array?.first?["text"]?.string ?? "", res["isError"] == .bool(true))
        }
        let l = try call("task_suggestions", #"{"date":"2026-10-29"}"#)
        let id = try #require(try s.list("2026-10-29").first?.id)
        #expect(!l.isError && l.text.contains("#\(id) ") && l.text.contains("PROJ-1") && l.text.contains("task_suggestions_answer"), "\(l.text)")
        #expect(try call("task_suggestions_answer", #"{"accept":[\#(id)]}"#).isError)
        #expect(try call("task_suggestions_answer", #"{"confirm":true}"#).isError)
        let ok = try call("task_suggestions_answer", #"{"accept":[\#(id)],"confirm":true}"#)
        #expect(!ok.isError && ok.text == "#\(id) accepted: PROJ-1 09:00–10:00", "\(ok.text)")
        #expect(try x.tasks.links(a.id).map(\.how) == ["manual"])
    }
}
