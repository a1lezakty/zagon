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

        // Work of no task after the build is no reason to build again.
        try f.session("claude:other", working: [(D0 + 21 * H, D0 + 21.5 * H)], actions: [D0 + 21 * H])
        let p1b = try w.plan(day, refresh: true, now: D0 + 21.6 * H).plan
        #expect(ai.prompts.count == 1 && p1b.sessionsAfterSummary == 0 && p1b.unassigned == [ProjectTime(project: "—", seconds: Int(0.5 * H))])
        // A text by hand; then the task's session works after the build: the rebuild keeps the hand-made text.
        #expect(try w.setText(row: b.id, day: day, summary: false, text: "By hand").textSource == "manual")
        try f.interval("claude:a", D0 + 22 * H, D0 + 22.5 * H)
        #expect(try w.plan(day).plan.sessionsAfterSummary == 1)
        let p2 = try w.plan(day, refresh: true, now: D0 + 23 * H).plan
        #expect(ai.prompts.count == 2 && p2.rows.count == 3)
        #expect(p2.rows.prefix(2).map(\.text) == ["Morning again.", "By hand"] && p2.rows.map(\.textSource) == ["summary", "manual", "titles"])
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
        // In parallel with the task's session, an excluded project takes nothing from it.
        try f.interval("claude:z", D0 + 9 * H, D0 + 12 * H)
        c.exclude = [WorklogExclusion(kind: "project", name: "example-tool")]
        let par = try Worklog(store: f.store).plan(day: day, config: c)
        #expect(par.rows.reduce(0) { $0 + $1.seconds } == Int(5 * H) && par.excluded?.first?.seconds == Int(2 * H))
        // An excluded task: its time is in no row and no line; next to work of no task (09:00–12:00) they share it.
        c.exclude = [WorklogExclusion(kind: "task", name: "proj-1")]
        let t = try Worklog(store: f.store).plan(day: day, config: c)
        #expect(t.rows.isEmpty && t.tasks.isEmpty && t.excluded?.first?.seconds == Int(3.5 * H) && t.unassignedSec == 3.5 * H)
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
        let mac014 = try d.decode(OldPlan.self, from: data)
        #expect(mac014.rows.map(\.text) == ["One.", "Two."] && mac014.commitDigest == p.commitDigest)
        let v = try #require(JValue.parse(Array(data)))
        #expect(v["rows"]?.array?[0]["day_summary"] == .bool(true) && v["rows"]?.array?[0]["text_source"]?.string == "summary")
        #expect(v["rows"]?.array?[0]["sessions"]?.array?[0]["how"]?.string == "branch" && v["summary_built_at"]?.double != nil)
        let oldJSON = #"{"day":"2026-10-29","user_sec":1,"session_sec":1,"rows":[{"id":1,"day":"2026-10-29","start":0,"end":300,"seconds":300,"text":"t","state":"planned"}],"tasks":[],"unassigned_sec":0,"unknown_keys":[],"unplaced":{},"notes":[],"commit_digest":""}"#
        let back = try d.decode(DayPlan.self, from: Data(oldJSON.utf8))
        #expect(back.tz == nil && back.excluded == nil && back.rows[0].textSource == nil && back.rows[0].sessions == nil)
        // Without flags the digest is the 0.1.4 one: `key|start|end|seconds|text` of the planned Jira rows.
        var jr = p.rows
        for i in jr.indices { jr[i].jiraKey = "PROJ-1" }
        let old = jr.map { "PROJ-1|\(Int64($0.start))|\(Int64($0.end))|\($0.seconds)|\($0.text)" }.joined(separator: "\n")
        #expect(jr[0].summary != nil && DayPlan.commitDigest(jr) == String(UInt64(bitPattern: fnv1a64(old)), radix: 16))
    }

    /// A row laid outside its sessions' work is described from their words of the day.
    @Test func aRowAwayFromItsWorkGetsTheDaysWords() throws {
        let f = try Fixture(), b = FakeEngine([]).builder(f.store)
        let s = RowSession(id: "claude:a", title: "Parser work", role: "single", how: "branch", seconds: 600)
        let t = WorklogTextBuilder.TaskInput(id: 1, key: "PROJ-1", title: "Parser", rows: [
            .init(id: 7, task: 1, start: D0 + 20 * H, end: D0 + 20.5 * H, sessions: [s]),
            .init(id: 8, task: 1, start: D0 + 9 * H, end: D0 + 10 * H, sessions: [s])])
        let said = ["claude:a": [WorklogTextBuilder.Said(ts: D0 + 9.5 * H, kind: .prompt, text: "split the parser")]]
        let d = b.digest([t], said: said, commits: [], prompts: 3, replies: 2, len: 300)
        #expect(d.components(separatedBy: "split the parser").count == 3)   // both rows
    }

    /// A text kept by hand follows its row when the row moves (here: starts later), not another row of the task.
    @Test func aManualTextFollowsItsMovedRow() throws {
        let f = try Fixture(), kept = WorklogTexts(store: f.store)
        try kept.setManual(day: day, task: 1, start: D0 + 9 * H, text: "Morning")
        let rows = [Interval(D0 + 9.5 * H, D0 + 12 * H), Interval(D0 + 14 * H, D0 + 16 * H)]
        #expect(try kept.row("manual", day, 1, rows[0].start, rows[0].end, siblings: rows) == "Morning")
        #expect(try kept.row("manual", day, 1, rows[1].start, rows[1].end, siblings: rows) == nil)
        #expect(try kept.row("manual", day, 2, rows[0].start, rows[0].end, siblings: rows) == nil)
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

    /// A Jira read kept by 0.1.4 has no project list: it is read again at once, so BRIEF-2 and the like stop counting.
    @Test func aReadFromBeforeTheProjectListIsReadAgain() throws {
        let m = try JiraMock(state: Self.state)
        let f = try Fixture()
        try f.store.db.run("INSERT INTO meta(key, value) VALUES('jira:issues', ?)", [.text(#"{"at": \#(D0), "tried": \#(D0), "issues": {}, "mine": []}"#)])
        #expect(JiraCache.current(f.store, try JiraClient(m.config), now: D0 + 60).at == D0 + 60)
        #expect(JiraCache.current(f.store, try JiraClient(m.config), now: D0 + 700).at == D0 + 60)   // now with its list: fresh
    }

    /// A comment whose reply was lost is found by the next plan; one that never arrived is offered again.
    @Test func aLostCommentReplyIsSettledByTheNextPlan() throws {
        let m = try JiraMock(state: #"{"me": "acc-me", "lose_comment_replies": 1, "issues": {"PROJ-1": {"summary": "Parser", "status": "In Progress", "category": "indeterminate", "assignee": "acc-me"}}}"#)
        let f = try Fixture()
        _ = try Tasks(store: f.store).add(title: "Parser", key: "PROJ-1")
        try f.session("claude:a", branch: "PROJ-1", title: "Parser work", working: [(D0 + 9 * H, D0 + 11 * H), (D0 + 14 * H, D0 + 15 * H)],
                      actions: [D0 + 9 * H])
        try TaskLinker().linkSessions(f.store)
        let w = DayWorklog(store: f.store, linker: try TaskLinker(), jira: try JiraClient(m.config))
        let p0 = try w.plan("2026-10-29").plan
        try WorklogTexts(store: f.store).setManualSummary(day: "2026-10-29", task: p0.rows[0].taskId!, text: "What was done\n- fixed")
        let rows = try w.plan("2026-10-29").plan.rows
        let first = try w.write(rows.filter { $0.daySummary == true }, day: "2026-10-29", commentKeys: ["PROJ-1"])
        #expect(first.commentsFailed == 1 && first.commentLines.last?.hasPrefix("not sure") == true)
        // Still `writing`: offered (the commit would look in Jira first); the next plan finds it.
        let again = try w.plan("2026-10-29").plan
        #expect(again.notes.contains("day summary on PROJ-1 is in Jira: marked") && again.rows.allSatisfy { $0.daySummary == false })
        #expect(try comments(m).count == 1)
    }

    /// The worklog that carried the summary never reached Jira: re-planned, its summary is offered again.
    @Test func aSummaryWorklogThatFailedIsOfferedAgain() throws {
        let m = try JiraMock(state: #"{"me": "acc-me", "post_status": [500], "issues": {"PROJ-1": {"summary": "Parser", "status": "In Progress", "category": "indeterminate", "assignee": "acc-me"}}}"#)
        let f = try Fixture()
        _ = try Tasks(store: f.store).add(title: "Parser", key: "PROJ-1")
        try f.session("claude:a", branch: "PROJ-1", title: "Parser work", working: [(D0 + 9 * H, D0 + 11 * H)], actions: [D0 + 9 * H])
        try TaskLinker().linkSessions(f.store)
        let w = DayWorklog(store: f.store, linker: try TaskLinker(), jira: try JiraClient(m.config))
        let p0 = try w.plan("2026-10-29").plan
        try WorklogTexts(store: f.store).setManualSummary(day: "2026-10-29", task: p0.rows[0].taskId!, text: "What was done\n- fixed")
        let r = try w.write(try w.plan("2026-10-29").plan.rows, day: "2026-10-29", withSummary: true)
        #expect(r.failed == 1 && r.lines.last?.hasPrefix("not sure") == true)
        #expect(try w.plan("2026-10-29").plan.rows.map(\.state) == ["writing"])   // in flight: not offered elsewhere
        #expect(try w.settle("2026-10-29", now: Time.now() + 600).first?.hasSuffix("planned again") == true)
        #expect(try w.plan("2026-10-29").plan.rows.map(\.daySummary) == [true])
    }

    @Test func aLostReplyIsFoundInJiraNextTime() throws {
        let m = try JiraMock(state: #"{"me": "acc-me", "lose_comment_replies": 1, "issues": {"PROJ-1": {"summary": "Parser", "status": "In Progress", "category": "indeterminate", "assignee": "acc-me"}}}"#)
        let f = try Fixture()
        let w = DayWorklog(store: f.store, linker: try TaskLinker(), jira: try JiraClient(m.config))
        let c = [(key: "PROJ-1", task: Int?.none, text: "What was done\n- fixed")]
        let first = try w.writeComments(c, day: "2026-10-29")
        #expect(first.commentsFailed == 1 && first.lines[0].hasPrefix("not sure"))
        #expect(try w.writeComments(c, day: "2026-10-29").lines == ["day summary on PROJ-1 is in Jira: marked"])
        #expect(try comments(m).count == 1)
    }
}

/// The 0.1.5 options of the worklog tools reach TaskTools through MCP.
@Suite struct WorklogMCPTests {
    @Test func newOptionsReachTheTools() throws {
        let m = try TaskMCP()
        _ = try m.call("task_create", #"{"title":"Parser work","key":"PROJ-1"}"#)
        let j = try m.call("worklog_plan", #"{"date":"2026-10-29","format":"json","refresh":true}"#)
        let v = try #require(JValue.parse(j.text), "\(j.text)")
        #expect(!j.isError && v["tz"]?.string != nil && v["rows"]?.array != nil && v["sessions_after_summary"] != nil)
        #expect(v["notes"]?.array?.contains(.string("texts not rebuilt: no AI engine")) == true)
        let c = try m.call("worklog_config", "{}")
        #expect(!c.isError && JValue.parse(c.text)?["day_summary"] == .bool(true) && JValue.parse(c.text)?["tz"] == .null)
        let w = try m.call("worklog_commit", #"{"date":"2026-10-29","confirm":true,"with_summary":true,"summary_comment":["PROJ-1"]}"#)
        #expect(w.isError && w.text.contains("Jira is not connected"), "\(w.text)")
    }
}
