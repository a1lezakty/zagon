import Foundation
import Testing
@testable import ZagonCore

/// The AI engine of the texts, answering `answers` in turn and keeping the prompts.
final class FakeEngine: @unchecked Sendable {
    var answers: [String]
    var prompts: [String] = []
    init(_ answers: [String]) { self.answers = answers }

    func builder(_ store: Store) -> WorklogTextBuilder {
        var c = NotifyConfig()
        c.lang = .en; c.summaryEngine = "claude"
        let dir = makeTempDir(), bin = dir + "/bin"
        Sys.mkdirs(bin)
        Sys.writeFile(bin + "/claude", Array("#!/bin/sh\n".utf8), mode: 0o755)
        var s = DaySummary(store: store, config: c, paths: ZagonPaths(home: dir, dir: dir + "/.zagon"), claudeRoot: dir + "/none")
        s.searchPath = bin; s.systemBins = []
        s.runner = { [self] _, input, _, _ in
            prompts.append(String(decoding: input, as: UTF8.self))
            let a = answers.isEmpty ? "" : answers.removeFirst()
            let json = JValue.object([.init("is_error", .bool(false)), .init("result", .string(a))]).compact
            return (0, Array(json.utf8), [])
        }
        return WorklogTextBuilder(engine: s)
    }
}

@Suite struct WorklogTextTests {
    let day = "2026-10-29"

    /// PROJ-1 worked 09:00–12:00 and 14:00–16:00: two rows.
    func twoRows(_ f: Fixture) throws -> DayWorklog {
        let t = Tasks(store: f.store)
        _ = try t.add(title: "Parser", key: "PROJ-1")
        try f.session("claude:a", branch: "PROJ-1-parser", title: "Parser work", working: [(D0 + 9 * H, D0 + 12 * H), (D0 + 14 * H, D0 + 16 * H)],
                      actions: [D0 + 9 * H, D0 + 14 * H])
        try TaskLinker().linkSessions(f.store)
        return DayWorklog(store: f.store, linker: try TaskLinker(), jira: nil)
    }

    func answer(_ rows: [Int: String], summary: Bool = true) -> String {
        let r = rows.map { "\"\($0.key)\": \"\($0.value)\"" }.joined(separator: ", ")
        return "```json\n{\"rows\": {\(r)}" + (summary ? #", "tasks": {"PROJ-1": {"was": "The parser failed on long input.", "found": "", "done": "- fixed\n- tested"}}"# : "") + "}\n```"
    }

    @Test func eachRowGetsItsTextAndAManualOneSurvivesARebuild() throws {
        let f = try Fixture()
        var w = try twoRows(f)
        let p0 = try w.plan(day).plan
        try #require(p0.rows.count == 2)
        let (a, b) = (p0.rows[0], p0.rows[1])
        #expect(a.seconds == Int(3 * H) && b.seconds == Int(2 * H))
        #expect(p0.rows.allSatisfy { $0.textSource == "titles" && $0.text == "Parser work" })
        #expect(p0.summaryBuiltAt == nil && p0.sessionsAfterSummary == 1 && p0.tz != nil)
        // The summary row lists the task's sessions over the day, the others over their own time.
        #expect(a.sessions == [RowSession(id: "claude:a", title: "Parser work", role: "single", how: "branch", seconds: Int(5 * H))])
        #expect(b.sessions?.map(\.seconds) == [Int(2 * H)])
        #expect(a.daySummary == true && b.daySummary == false && a.summary == nil)

        let ai = FakeEngine([answer([a.id: "Morning: found the crash on ~/work/example-project/input.txt.", b.id: "Afternoon: fixed it."]),
                             answer([a.id: "Morning again.", b.id: "Afternoon again."])])
        w.texts = ai.builder(f.store)
        let p1 = try w.plan(day, refresh: true, now: D0 + 20 * H).plan
        #expect(ai.prompts.count == 1 && ai.prompts[0].contains("Row \(a.id): 09:00–12:00") && ai.prompts[0].contains("Task PROJ-1 “Parser”"))
        #expect(p1.rows.map(\.text) == ["Morning: found the crash on input.txt.", "Afternoon: fixed it."])  // no home paths
        #expect(p1.rows.map(\.textSource) == ["summary", "summary"])
        #expect(p1.rows[0].summary == "What the task was\nThe parser failed on long input.\n\nWhat was done\n- fixed\n- tested")
        #expect(p1.rows[0].summarySource == "summary" && p1.rows[1].summary == nil)
        #expect(p1.summaryBuiltAt == D0 + 20 * H && p1.sessionsAfterSummary == 0)
        // Nothing new since: a refresh does not ask again.
        _ = try w.plan(day, refresh: true, now: D0 + 20.5 * H)
        #expect(ai.prompts.count == 1)

        // The summary goes to Jira only when asked: into the longest row's worklog, or as an issue comment.
        #expect(Worklog.comment(p1.rows[0]) == p1.rows[0].text)
        #expect(Worklog.comment(p1.rows[0], withSummary: true) == p1.rows[0].text + "\n\n" + p1.rows[0].summary!)
        #expect(Worklog.comment(p1.rows[0], withSummary: true, commentKeys: ["PROJ-1"]) == p1.rows[0].text)
        #expect(Worklog.comment(p1.rows[1], withSummary: true) == p1.rows[1].text)
        let digests = Set([DayPlan.commitDigest(p1.rows), DayPlan.commitDigest(p1.rows, withSummary: true),
                           DayPlan.commitDigest(p1.rows, commentKeys: ["PROJ-1"])])
        #expect(digests.count == 3 && DayPlan.commitDigest(p1.rows) == p1.commitDigest)

        // A text by hand; then a session works after the build: the rebuild keeps the hand-made text.
        #expect(try w.setText(row: b.id, day: day, summary: false, text: "By hand").textSource == "manual")
        try f.session("claude:other", working: [(D0 + 21 * H, D0 + 21.5 * H)], actions: [D0 + 21 * H])
        let p2 = try w.plan(day, refresh: true, now: D0 + 22 * H).plan
        #expect(ai.prompts.count == 2)
        #expect(p2.rows.map(\.text) == ["Morning again.", "By hand"] && p2.rows.map(\.textSource) == ["summary", "manual"])
        #expect(p2.unassigned == [ProjectTime(project: "—", seconds: Int(0.5 * H))])
        // Back to the built one.
        #expect(try w.setText(row: b.id, day: day, summary: false, text: "").text == "Afternoon again.")
    }

    @Test func phrasesAboutTheInputAreAskedOnceMoreThenDropped() throws {
        let f = try Fixture()
        var w = try twoRows(f)
        let p0 = try w.plan(day).plan
        let (a, b) = (p0.rows[0].id, p0.rows[1].id)
        let ai = FakeEngine([answer([a: "The digest has no results for this stretch.", b: "Fixed the parser."], summary: false),
                             answer([a: "Not visible in the session.", b: "Fixed the parser, tested."], summary: false)])
        w.texts = ai.builder(f.store)
        let p = try w.plan(day, refresh: true).plan
        #expect(ai.prompts.count == 2 && ai.prompts[1].hasSuffix(WorklogTextBuilder.noMeta(.english)))
        #expect(p.rows.map(\.text) == ["Parser work", "Fixed the parser, tested."] && p.rows.map(\.textSource) == ["titles", "summary"])
        #expect(WorklogTextBuilder.Answer.isMeta("В выжимке итогов нет") && !WorklogTextBuilder.Answer.isMeta("Fixed the parser"))
    }

    @Test func anExcludedProjectIsNoRowAndNoUnassignedTime() throws {
        let f = try Fixture()
        let w = try twoRows(f)
        try f.session("claude:z", working: [(D0 + 17 * H, D0 + 19 * H)], actions: [D0 + 17 * H])
        try f.store.db.run("UPDATE session SET project = 'example-tool' WHERE id = 'claude:z'")
        let all = try w.plan(day).plan
        #expect(all.unassignedSec == 2 * H && all.unassigned == [ProjectTime(project: "example-tool", seconds: Int(2 * H))])
        var c = WorklogConfig()
        c.exclude = [WorklogExclusion(kind: "project", name: "example-tool"), WorklogExclusion(kind: "task", name: "NOPE-1")]
        let p = try Worklog(store: f.store).plan(day: day, config: c)
        #expect(p.rows.count == 2 && p.rows.allSatisfy { $0.taskKey == "PROJ-1" })
        #expect(p.unassignedSec == 0 && p.unassigned == [] && p.userSec == 5 * H)
        #expect(p.excluded == [ExcludedTime(kind: "project", name: "example-tool", seconds: Int(2 * H)),
                               ExcludedTime(kind: "task", name: "NOPE-1", seconds: 0)])
        // An excluded task: its time is in no row and no line.
        c.exclude = [WorklogExclusion(kind: "task", name: "proj-1")]
        let t = try Worklog(store: f.store).plan(day: day, config: c)
        #expect(t.rows.isEmpty && t.tasks.isEmpty && t.excluded?.first?.seconds == Int(5 * H) && t.unassignedSec == 2 * H)
    }

    @Test func configKeysAndExclusionsKeepTheRestOfTheFile() throws {
        let dir = makeTempDir(), p = ZagonPaths(home: dir, dir: dir + "/z")
        Sys.mkdirs(p.dir)
        Sys.writeFile(p.config, Array("timezone = \"Asia/Almaty\"\n\n[worklog]\nreconcile_tolerance_min = 20\n".utf8), mode: 0o600)
        try WorklogConfig.set(p, "tz", "Asia/Nicosia")
        try WorklogConfig.set(p, "projects", "proj, ops")
        try WorklogConfig.set(p, "day_summary", "false")
        #expect(try WorklogConfig.setExcluded(p, WorklogExclusion(kind: "project", name: "example-tool"), true))
        #expect(try !WorklogConfig.setExcluded(p, WorklogExclusion(kind: "project", name: "example-tool"), true))
        try WorklogConfig.setExcluded(p, WorklogExclusion(kind: "session", name: "claude:abc"), true)
        #expect(throws: SettingsError.self) { try WorklogConfig.set(p, "tz", "Nowhere/Zone") }
        #expect(throws: SettingsError.self) { try WorklogConfig.set(p, "rebuild_at_end", "yes") }
        #expect(throws: SettingsError.self) { try WorklogConfig.set(p, "nope", "1") }
        let c = WorklogConfig.load(p)
        #expect(c.tz == "Asia/Nicosia" && c.projects == ["PROJ", "OPS"] && !c.daySummary && c.rebuildAtEnd)
        #expect(c.exclude == [WorklogExclusion(kind: "project", name: "example-tool"), WorklogExclusion(kind: "session", name: "claude:abc")])
        let text = String(decoding: Sys.readFile(p.config)!, as: UTF8.self)
        #expect(text.hasPrefix("timezone = \"Asia/Almaty\"\n\n[worklog]\n") && text.contains("reconcile_tolerance_min = 20\n")
                && text.contains("day_summary = false\n"))
        try WorklogConfig.set(p, "tz", "system")
        try WorklogConfig.setExcluded(p, WorklogExclusion(kind: "project", name: "example-tool"), false)
        #expect(WorklogConfig.load(p).tz == nil && WorklogConfig.load(p).exclude.map(\.kind) == ["session"])
    }

    /// A Mac on 0.1.4 reads a 0.1.5 plan (new fields are ignored), 0.1.5 reads a 0.1.4 plan (they are nil).
    @Test func planJSONReadsBothWays() throws {
        struct OldRow: Decodable { var id: Int; var day: String; var taskId: Int?; var taskKey, jiraKey: String?; var start, end: Double
                                   var seconds: Int; var text, state: String; var jiraWorklogId: String? }
        struct OldTask: Decodable { var taskId: Int?; var key, title: String?; var userSec, sessionSec, jiraSec: Double }
        struct OldPlan: Decodable { var day: String; var userSec, sessionSec: Double; var jiraSec: Double?; var rows: [OldRow]
                                    var tasks: [OldTask]; var unassignedSec: Double; var unknownKeys: [String]; var unplaced: [String: Int]
                                    var notes: [String]; var commitDigest: String }
        let f = try Fixture()
        var w = try twoRows(f)
        let p0 = try w.plan(day).plan
        w.texts = FakeEngine([answer([p0.rows[0].id: "One.", p0.rows[1].id: "Two."])]).builder(f.store)
        let p = try w.plan(day, refresh: true).plan
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        let data = try e.encode(p)
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let old = try d.decode(OldPlan.self, from: data)
        #expect(old.rows.map(\.text) == ["One.", "Two."] && old.commitDigest == p.commitDigest)
        let v = try #require(JValue.parse(Array(data)))
        #expect(v["rows"]?.array?[0]["day_summary"] == .bool(true) && v["rows"]?.array?[0]["text_source"]?.string == "summary")
        #expect(v["rows"]?.array?[0]["sessions"]?.array?[0]["how"]?.string == "branch" && v["summary_built_at"]?.double != nil)
        let oldJSON = #"{"day":"2026-10-29","user_sec":1,"session_sec":1,"rows":[{"id":1,"day":"2026-10-29","start":0,"end":300,"seconds":300,"text":"t","state":"planned"}],"tasks":[],"unassigned_sec":0,"unknown_keys":[],"unplaced":{},"notes":[],"commit_digest":""}"#
        let back = try d.decode(DayPlan.self, from: Data(oldJSON.utf8))
        #expect(back.tz == nil && back.excluded == nil && back.rows[0].textSource == nil && back.rows[0].sessions == nil)
    }
}

/// Days in the worklog zone, checked on the binary: this test process never changes its own zone.
@Suite struct WorklogZoneTests {
    @Test(.enabled(if: Sys.exists(zagonBin))) func theWorklogZoneCutsTheDay() throws {
        let dir = makeTempDir(), z = dir + "/z"
        Sys.mkdirs(z)
        let store = try Store(path: z + "/zagon.db")
        _ = try Tasks(store: store).add(title: "Parser", key: "PROJ-1")
        // 19:00–21:00 UTC on the 29th: 21:00–23:00 that day in Nicosia (UTC+2), 00:00–02:00 on the 30th in Almaty (UTC+5).
        try store.mergeSession(SessionMeta(id: "claude:a", tool: .claude, gitBranch: "PROJ-1", title: "Parser work", titleRank: TitleRank.customTitle))
        try store.db.run("INSERT INTO activity(file_id, session_id, start, \"end\", kind) VALUES(1, 'claude:a', ?, ?, 'working')", [.real(D0 + 19 * H), .real(D0 + 21 * H)])
        try store.db.run("UPDATE session SET started_at = ?, last_at = ? WHERE id = 'claude:a'", [.real(D0 + 19 * H), .real(D0 + 21 * H)])
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = dir; env["TZ"] = "UTC"
        func plan(_ day: String) throws -> JValue {
            let (code, out) = try runZagon(["log", "plan", day, "--json", "--no-scan", "--data-dir", z, "--claude-dir", dir + "/claude",
                                            "--codex-dir", dir + "/codex"], stdin: [], env: env)
            #expect(code == 0)
            return try #require(JValue.parse(out))
        }
        func seconds(_ v: JValue) -> Int { (v["rows"]?.array ?? []).reduce(0) { $0 + Int($1["seconds"]?.double ?? 0) } }
        Sys.writeFile(z + "/config.toml", Array("timezone = \"Asia/Almaty\"\n\n[worklog]\ntz = \"Asia/Nicosia\"\n".utf8), mode: 0o600)
        let cy = try plan("2026-10-29")
        #expect(try cy["tz"]?.string == "Asia/Nicosia" && seconds(cy) == 7200 && seconds(try plan("2026-10-30")) == 0)
        Sys.writeFile(z + "/config.toml", Array("timezone = \"Asia/Almaty\"\n".utf8), mode: 0o600)
        let kz = try plan("2026-10-29")
        #expect(try kz["tz"]?.string == "Asia/Almaty" && seconds(kz) == 0 && seconds(try plan("2026-10-30")) == 7200)
        // The database's days stay in its own zone.
        let (_, cfg) = try runZagon(["log", "config", "--json", "--data-dir", z], stdin: [], env: env)
        #expect(JValue.parse(cfg)?["tz"] == .null && JValue.parse(cfg)?["machine_tz"]?.string == "Asia/Almaty")
    }
}

/// The day summary as one comment on the issue, once per task and day.
@Suite(.enabled(if: hasTool("python3") && hasTool("curl"), "needs python3 and curl"), .timeLimit(.minutes(1)))
struct WorklogCommentTests {
    static let state = #"{"me": "acc-me", "issues": {"PROJ-1": {"summary": "Parser", "status": "In Progress", "category": "indeterminate", "assignee": "acc-me"}}}"#

    func comments(_ m: JiraMock) throws -> [[String: Any]] {
        ((try m.state()["issues"] as! [String: [String: Any]])["PROJ-1"]!["comments"] as? [[String: Any]]) ?? []
    }

    @Test func oneCommentPerTaskAndDayAndTheWorklogWithoutIt() throws {
        let m = try JiraMock(state: Self.state)
        let f = try Fixture()
        _ = try Tasks(store: f.store).add(title: "Parser", key: "PROJ-1")
        try f.session("claude:a", branch: "PROJ-1", title: "Parser work", working: [(D0 + 9 * H, D0 + 11 * H)], actions: [D0 + 9 * H])
        try TaskLinker().linkSessions(f.store)
        var w = DayWorklog(store: f.store, linker: try TaskLinker(), jira: try JiraClient(m.config))
        w.texts = FakeEngine([]).builder(f.store)
        let p0 = try w.plan("2026-10-29").plan
        try WorklogTexts(store: f.store).setManualSummary(day: "2026-10-29", task: p0.rows[0].taskId!, text: "What was done\n- fixed")
        let rows = try w.plan("2026-10-29").plan.rows
        #expect(rows.count == 1 && rows[0].summary == "What was done\n- fixed")
        let r = try w.write(rows, day: "2026-10-29", withSummary: true, commentKeys: ["PROJ-1"])
        #expect(r.logged == 1 && r.failed == 0 && r.commented == 1 && r.commentsFailed == 0 && r.commentLines == ["commented day summary on PROJ-1"])
        let issue = (try m.state()["issues"] as! [String: [String: Any]])["PROJ-1"]!
        #expect((issue["worklogs"] as! [[String: Any]]).first?["comment"] as? String == "Parser work")
        #expect(try comments(m).map { $0["body"] as? String } == ["Day summary — 2026-10-29\n\nWhat was done\n- fixed"])
        // Again: marked here; marked from Jira when the mark is gone; never a second comment.
        let again = Worklog.issueComments(rows, commentKeys: ["PROJ-1"])
        #expect(try w.writeComments(again, day: "2026-10-29").lines == ["day summary on PROJ-1 already commented"])
        try f.store.db.run("DELETE FROM meta WHERE key LIKE 'wlcomment:%'")
        #expect(try w.writeComments(again, day: "2026-10-29").lines == ["day summary on PROJ-1 is in Jira: marked"])
        #expect(try comments(m).count == 1)
        // Once in Jira, the task's rows of the day carry no summary any more, also a row for later work.
        try f.interval("claude:a", D0 + 14 * H, D0 + 15 * H)
        let later = try w.plan("2026-10-29").plan.rows
        #expect(later.first?.state == "logged" && later.contains { $0.state == "planned" } && later.allSatisfy { $0.daySummary == false })
    }

    /// With `withSummary` the summary rides on the longest worklog; then it is not offered again that day.
    @Test func theSummaryInAWorklogIsWrittenOnce() throws {
        let m = try JiraMock(state: Self.state)
        let f = try Fixture()
        _ = try Tasks(store: f.store).add(title: "Parser", key: "PROJ-1")
        try f.session("claude:a", branch: "PROJ-1", title: "Parser work", working: [(D0 + 9 * H, D0 + 11 * H)], actions: [D0 + 9 * H])
        try TaskLinker().linkSessions(f.store)
        let w = DayWorklog(store: f.store, linker: try TaskLinker(), jira: try JiraClient(m.config))
        let p0 = try w.plan("2026-10-29").plan
        try WorklogTexts(store: f.store).setManualSummary(day: "2026-10-29", task: p0.rows[0].taskId!, text: "What was done\n- fixed")
        let rows = try w.plan("2026-10-29").plan.rows
        #expect(try w.write(rows, day: "2026-10-29", withSummary: true).logged == 1)
        let issue = (try m.state()["issues"] as! [String: [String: Any]])["PROJ-1"]!
        #expect((issue["worklogs"] as! [[String: Any]]).first?["comment"] as? String == "Parser work\n\nWhat was done\n- fixed")
        try f.interval("claude:a", D0 + 14 * H, D0 + 15 * H)
        let later = try w.plan("2026-10-29").plan.rows
        #expect(try later.contains { $0.state == "planned" } && later.allSatisfy { $0.daySummary == false } && comments(m).isEmpty)
    }

    @Test func aLostReplyIsFoundInJiraNextTime() throws {
        let m = try JiraMock(state: #"{"me": "acc-me", "lose_post_replies": 1, "issues": {"PROJ-1": {"summary": "Parser", "status": "In Progress", "category": "indeterminate", "assignee": "acc-me"}}}"#)
        let f = try Fixture()
        let w = DayWorklog(store: f.store, linker: try TaskLinker(), jira: try JiraClient(m.config))
        let c = [(key: "PROJ-1", task: Int?.none, text: "What was done\n- fixed")]
        let first = try w.writeComments(c, day: "2026-10-29")
        #expect(first.commentsFailed == 1 && first.lines[0].hasPrefix("not sure"))
        #expect(try w.writeComments(c, day: "2026-10-29").lines == ["day summary on PROJ-1 is in Jira: marked"])
        #expect(try comments(m).count == 1)
    }
}
