import Foundation
import Testing
@testable import ZagonCore

private let day = "2026-10-29"
private func h(_ x: Double) -> Double { D0 + x * H }

/// Work no task fits gets a new task suggested; accepted, it becomes a task here or (on an explicit command) in Jira.
@Suite struct NewTaskTests {
    @Test func newTasksInTheAnswer() {
        let segs: Set<String> = ["S1", "S2", "S3", "S4"]
        let p = { (t: String) in TaskSuggester.parseNew(t, segments: segs) }
        #expect(p("no json").isEmpty && p("[]").isEmpty && p(#"[{"segment": "S1", "new": ""}, {"segment": "S1", "new": 5}]"#).isEmpty)
        let r = p("""
            [{"segment": "S1", "new": "Dialog strategies: retries", "description": "Was: lost replies.\\n\\nDone:  retries   with backoff", "done": "Retries", "confidence": 0.8},
             {"segment": "S3", "new": "dialog STRATEGIES:  retries", "done": "more"},
             {"segment": "S2", "key": "PROJ-1", "confidence": 0.9},
             {"segment": "S4", "new": "\(String(repeating: "long ", count: 30))", "description": "\(String(repeating: "d", count: 900))"},
             {"segment": "S9", "new": "not offered"}, {"segment": "S1", "new": "second answer for S1"}, 42]
            """)
        #expect(r.map(\.title) == ["Dialog strategies: retries", String(repeating: "long ", count: 13) + "long…"])
        #expect(r[0].segments == ["S1", "S3"] && r[0].confidence == 0.8 && r[0].done == "Retries")   // S3: the same title
        #expect(r[0].description == "Was: lost replies.\n\nDone: retries with backoff")
        #expect(r[1].description.count == 600 && r[1].segments == ["S4"])
        // Titles differing only in case and spaces are one task.
        let one = p(#"[{"segment": "S1", "new": "Fix  login"}, {"segment": "S2", "new": "fix login"}]"#)
        #expect(one.count == 1 && one[0].segments == ["S1", "S2"])
        // The key answer of the same text is read apart (with its worklog text).
        let k = TaskSuggester.parse(#"[{"segment": "S2", "key": "PROJ-1", "confidence": 0.9, "done": "Parser fixed"}]"#,
                                    segments: segs, keys: ["PROJ-1"], min: 0.7)
        #expect(k.map(\.done) == ["Parser fixed"])
    }

    /// No task at all: the AI is still asked and suggests new ones; a new task counts nowhere until accepted, then it
    /// is a task here with the stretches linked and its text as the day's worklog text.
    @Test func suggestAcceptRejectNew() throws {
        var x = try SuggestFixture()
        try x.f.session("claude:s1", title: "retry logic", working: [(h(9), h(10))])
        try x.f.session("claude:s2", title: "retry tests", working: [(h(11), h(11.5))])
        try x.f.session("claude:s3", title: "slides", working: [(h(13), h(13.5))])
        x.calls.answer = """
            [{"segment": "S1", "new": "Dialog retries", "description": "Was: replies lost.\\nDone: retries.", "done": "Retries with backoff", "confidence": 0.8},
             {"segment": "S2", "new": "dialog retries", "done": "tests"},
             {"segment": "S3", "new": "Demo slides", "done": "Slides"}]
            """
        let r = try x.s.suggest(day, now: h(20))
        #expect(x.calls.n == 1 && x.calls.prompt.contains("(нет — только новые задачи)") && x.calls.prompt.contains("пишет сам разработчик"))
        #expect(r.items.isEmpty && r.drafts.map(\.title) == ["Dialog retries", "Demo slides"])
        let n1 = r.drafts[0]
        #expect(n1.id == "N1" && n1.stretches.map(\.sessionId) == ["claude:s1", "claude:s2"] && abs(n1.workedSec - 1.5 * H) < 1e-6)
        #expect(n1.stretches[0].sessionTitle == "retry logic" && n1.day == day)
        #expect(SuggestText.run(r, day: day).contains("#N1    new        1h 30m"))
        // Not counted, not asked again, not a task yet.
        #expect(try x.tasks.list().isEmpty && TaskTime.compute(x.f.store, from: D0, to: D0 + 86400).lines.keys.allSatisfy { $0 == nil })
        let again = try x.s.suggest(day, now: h(21))
        #expect(try !again.made && x.calls.n == 1 && again.drafts.map(\.id) == ["N1", "N2"] && x.s.drafts().count == 2)

        #expect(try x.s.acceptNew("n1", title: "  ", description: nil).hasPrefix("N1 accepted: ZAG-1 Dialog retries · 1h 30m"))
        let t = try #require(try x.tasks.find("ZAG-1"))
        #expect(t.description == "Was: replies lost.\nDone: retries." && t.jiraKey == nil && t.status == .inProgress)
        #expect(try x.tasks.done(t.id).map(\.text) == ["Retries with backoff"] && x.tasks.done(t.id)[0].source == "auto")
        let m = try x.tasks.linkMap()
        #expect(m.tasks("claude:s1", at: h(9.5)).map(\.task) == [t.id] && m.tasks("claude:s2", at: h(11.2)).map(\.task) == [t.id])
        let plan = try DayWorklog(store: x.f.store, linker: try TaskLinker(), jira: nil).plan(day).plan
        #expect(plan.rows.filter { $0.taskId == t.id }.allSatisfy { $0.text == "Retries with backoff" } && !plan.rows.isEmpty)
        #expect(try x.s.acceptNew("N1") == "N1: no such suggested task")
        #expect(try x.s.rejectNew("N2") == "N2 rejected" && x.s.drafts().isEmpty && x.s.rejectNew("N2") == "N2: no such suggested task")
        // Rejected work is not asked again; `again` asks anew and ids go on.
        #expect(try !x.s.suggest(day, now: h(22)).made)
        x.calls.answer = #"[{"segment": "S1", "new": "Demo slides"}]"#
        let r2 = try x.s.suggest(day, again: true, now: h(23))
        #expect(r2.made && r2.drafts.map(\.id) == ["N3"])
    }

    /// A key only when sure; otherwise the new task the AI gave; a stretch linked meanwhile is not taken.
    @Test func keyWhenSureElseNew() throws {
        var x = try SuggestFixture()
        let a = try x.tasks.add(title: "Encoder research", key: "PROJ-1")
        try x.tasks.setStatus(a.id, .inProgress)
        try x.f.session("claude:s1", title: "encoder gains", working: [(h(9), h(10))])
        try x.f.session("claude:s2", title: "something else", working: [(h(11), h(12))])
        x.calls.answer = """
            [{"segment": "S1", "key": "PROJ-1", "confidence": 0.9, "reason": "encoder", "done": "Gains tuned"},
             {"segment": "S1", "new": "Encoder gains"},
             {"segment": "S2", "key": "PROJ-1", "confidence": 0.4, "reason": "weak"},
             {"segment": "S2", "new": "Billing export", "done": "Export"}]
            """
        let r = try x.s.suggest(day, now: h(20))
        #expect(r.items.map(\.key) == ["PROJ-1"] && r.items[0].done == "Gains tuned" && r.drafts.map(\.title) == ["Billing export"])
        _ = try x.s.accept([r.items[0].id])
        #expect(try x.tasks.done(a.id).map(\.text) == ["Gains tuned"])
        // s2 gets a key by hand meanwhile: the new task is not made.
        try x.tasks.link(a.id, session: "claude:s2", how: .manual)
        #expect(try x.s.acceptNew("N1") == "N1 not accepted: that time is linked to PROJ-1 now; suggestion dropped")
        #expect(try x.tasks.list().count == 1)
    }

    /// Samples of the user's style go into the ask, clipped to their budget; the whole ask stays within its limit.
    @Test func styleSamplesFitTheBudget() {
        var t = JiraTexts()
        t.issues = (0..<5).map { ("Issue title \($0)", String(repeating: "Описание задачи. ", count: 60)) }
        t.worklogs = (0..<10).map { "Worklog \($0): " + String(repeating: "сделал ", count: 40) }
        t.comments = (0..<3).map { "Comment \($0) " + String(repeating: "текст ", count: 80) }
        let s = TaskSuggester.style(t, words: .ru)
        #expect(s.count <= TaskSuggester.maxStyle && s.hasPrefix("Задачи, которые он завёл") && s.contains("- Issue title 4 — Описание"))
        #expect(s.contains("Его ворклоги:\n- Worklog 0"))
        #expect(TaskSuggester.style(JiraTexts(), words: .english).isEmpty)
        let seg = TaskSuggester.Segment(id: "S1", session: "s", start: h(9), end: h(10), worked: H)
        let (text, asked) = TaskSuggester.prompt([seg], [:], [], style: s + String(repeating: "x", count: 5000))
        #expect(text.contains("Образцы стиля разработчика") && text.count <= TaskSuggester.maxPrompt && asked == ["S1"])
    }
}

@Suite(.enabled(if: hasTool("python3") && hasTool("curl"), "needs python3 and curl"), .timeLimit(.minutes(1)))
struct NewTaskJiraTests {
    static func state(_ extra: String = "") -> String {
        """
        {"me": "acc-me", \(extra) "projects": [{"key": "OPS", "name": "Operations"}, {"key": "PROJ", "name": "Product"}],
         "issues": {
          "PROJ-1": {"summary": "Dialogs", "status": "In Progress", "category": "indeterminate", "assignee": "acc-me", "creator": "acc-me",
                     "description": "Was: X.\\nDone: Y.", "comments": [{"author": "acc-me", "body": "Mine"}, {"author": "acc-other", "body": "Theirs"}],
                     "worklogs": [{"id": "1", "author": "acc-me", "started": "2026-10-28T08:00:00.000+0200", "seconds": 3600, "comment": "Parser fixed"},
                                  {"id": "2", "author": "acc-other", "started": "2026-10-28T09:00:00.000+0200", "seconds": 600, "comment": "not mine"}]},
          "PROJ-2": {"summary": "Someone's", "status": "To Do", "category": "new", "assignee": "acc-other", "creator": "acc-other", "description": "theirs"}}}
        """
    }

    func fixture(_ m: JiraMock) throws -> SuggestFixture {
        var x = try SuggestFixture()
        x.s.jira = try JiraClient(m.config)
        try x.f.session("claude:s1", title: "retry logic", working: [(h(9), h(10))])
        x.calls.answer = #"[{"segment": "S1", "new": "Dialog retries", "description": "Was: lost.\nDone: retries.", "done": "Retries"}]"#
        return x
    }

    func issues(_ m: JiraMock) throws -> [String: [String: Any]] { try m.state()["issues"] as! [String: [String: Any]] }

    @Test func styleFromYourJiraTexts() throws {
        let m = try JiraMock(state: Self.state()), j = try JiraClient(m.config)
        let t = try j.myTexts(since: D0 - 14 * 86400)
        #expect(t.issues.map(\.summary) == ["Dialogs"] && t.worklogs == ["Parser fixed"] && t.comments == ["Mine"])
        let x = try fixture(m)
        _ = try x.s.suggest(day, now: h(20))
        #expect(x.calls.prompt.contains("- Dialogs — Was: X.\nDone: Y.") && x.calls.prompt.contains("- Parser fixed")
                && !x.calls.prompt.contains("Theirs") && !x.calls.prompt.contains("not mine"))
        #expect(try x.s.meta("suggest:style")?["n"] == .array([.number("1"), .number("1"), .number("1")]))
    }

    @Test func createInJiraOnlyWhenAsked() throws {
        let m = try JiraMock(state: Self.state()), x = try fixture(m)
        _ = try x.s.suggest(day, now: h(20))
        let (d, ps) = try x.s.jiraProjects()
        #expect(ps.map(\.key) == ["OPS", "PROJ"] && d == "PROJ")                  // most of your issues are there
        let plan = try x.s.jiraPlan("N1", title: "Retries for dialogs")
        #expect(plan.project == "PROJ" && plan.title == "Retries for dialogs" && plan.description == "Was: lost.\nDone: retries.")
        #expect(try issues(m).count == 2)                                        // planning writes nothing
        #expect(try x.s.jiraPlan("N1", project: "nope").project == nil)
        #expect(throws: TaskError.self) { try x.s.createInJira("N1", project: "NOPE") }

        let line = try x.s.createInJira("N1", project: "ops", title: "Retries for dialogs", description: "Edited")
        #expect(line == "N1 accepted: OPS-101 Retries for dialogs · 1h 00m · created in Jira", "\(line)")
        let made = try #require(try issues(m)["OPS-101"])
        #expect(made["summary"] as? String == "Retries for dialogs" && made["description"] as? String == "Edited"
                && made["assignee"] as? String == "acc-me" && made["type"] as? String == "3")
        let t = try #require(try x.tasks.find("OPS-101"))
        #expect(try t.jiraKey == "OPS-101" && t.description == "Edited" && x.tasks.links(t.id).map(\.how) == ["manual"])
        #expect(try x.s.meta("jira:last-project")?.string == "OPS" && x.s.jiraProjects().default == "OPS")
        #expect(try x.s.drafts().isEmpty)
    }

    /// A create whose reply was lost: the next try finds the issue instead of making a second one; a refused one
    /// changes nothing.
    @Test func lostReplyMakesNoSecondIssue() throws {
        let m = try JiraMock(state: Self.state(#""lose_post_replies": 1, "#)), x = try fixture(m)
        _ = try x.s.suggest(day, now: h(20))
        #expect(throws: TaskError.self) { try x.s.createInJira("N1", project: "PROJ") }
        #expect(try issues(m).keys.sorted() == ["PROJ-1", "PROJ-103", "PROJ-2"] && x.tasks.find("PROJ-103") == nil && x.s.drafts().count == 1)
        #expect(try x.s.createInJira("N1", project: "PROJ").hasPrefix("N1 accepted: PROJ-103 Dialog retries"))
        #expect(try issues(m).count == 3 && x.s.meta("jira:create:N1") == nil)

        let r = try JiraMock(state: Self.state(#""post_status": [400], "#)), y = try fixture(r)
        _ = try y.s.suggest(day, now: h(20))
        #expect(throws: JiraError.self) { try y.s.createInJira("N1", project: "PROJ") }
        #expect(try issues(r).count == 2 && y.s.meta("jira:create:N1") == nil && y.s.drafts().count == 1)
    }

    /// MCP: without confirm only what would be made; with it the issue is created. Answers take N… ids.
    @Test func mcpConfirmsBeforeCreating() throws {
        let m = try JiraMock(state: Self.state()), x = try fixture(m)
        try x.f.session("claude:s2", title: "slides", working: [(h(13), h(14))])
        x.calls.answer = #"[{"segment": "S1", "new": "Dialog retries"}, {"segment": "S2", "new": "Demo slides"}]"#
        let store = x.f.store, s = x.s
        let tools = TaskTools(store: store, worklog: { DayWorklog(store: store, linker: try TaskLinker(), jira: nil) },
                              suggester: { s }, now: { h(20) })
        let server = ZagonMCP.server(store: store, exportDir: tempDir(), tasks: tools)
        func call(_ tool: String, _ args: String) throws -> (text: String, isError: Bool) {
            let out = try #require(server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(args)}}"#))
            let res = try #require(JValue.parse(out)?["result"])
            return (res["content"]?.array?.first?["text"]?.string ?? "", res["isError"] == .bool(true))
        }
        let l = try call("task_suggestions", #"{"date":"2026-10-29"}"#)
        #expect(l.text.contains("#N1") && l.text.contains("Demo slides"), "\(l.text)")
        let preview = try call("task_create_in_jira", #"{"id":"N1","project":"PROJ"}"#)
        #expect(!preview.isError && preview.text.contains("Would create in Jira: a Task in PROJ") && preview.text.contains("Nothing was created"))
        #expect(try issues(m).count == 2)
        let made = try call("task_create_in_jira", #"{"id":"N1","project":"PROJ","confirm":true}"#)
        #expect(try !made.isError && made.text.hasPrefix("N1 accepted: PROJ-103") && issues(m).count == 3, "\(made.text)")
        #expect(try call("task_suggestions_answer", #"{"accept":["n9", 1.5],"confirm":true}"#).isError)
        let ok = try call("task_suggestions_answer", #"{"reject":["N2"],"confirm":true}"#)
        #expect(!ok.isError && ok.text == "N2 rejected")
    }
}
