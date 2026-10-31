import Foundation
import Testing
@testable import ZagonCore

/// TaskSuggester on hand-made sessions (Fixture), the AI replaced by a stub; no Jira.
struct SuggestFixture {
    let f: Fixture
    let tasks: Tasks
    var s: TaskSuggester
    /// What the stub answered and how often it was called.
    final class Calls { var n = 0; var answer = ""; var prompt = "" }
    let calls = Calls()

    init(engine: String = "claude", lang: NotifyLang = .ru) throws {
        f = try Fixture()
        tasks = Tasks(store: f.store)
        let dir = tempDir(), bin = dir + "/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        Sys.writeFile(bin + "/claude", [0], mode: 0o755)
        var cfg = NotifyConfig()
        cfg.summaryEngine = engine
        cfg.lang = lang
        var e = DaySummary(store: f.store, config: cfg, paths: ZagonPaths(home: dir, dir: dir + "/zagon"), claudeRoot: dir + "/claude")
        e.searchPath = bin
        let calls = self.calls
        e.runner = { _, input, _, _ in
            calls.n += 1; calls.prompt = String(decoding: input, as: UTF8.self)
            let body = JValue.object([.init("is_error", .bool(false)), .init("result", .string(calls.answer)),
                                      .init("total_cost_usd", .number("0.0031")),
                                      .init("usage", .object([.init("input_tokens", .number("2500")), .init("output_tokens", .number("120"))]))])
            return (0, Array(body.compact.utf8), [])
        }
        s = TaskSuggester(store: f.store, linker: try TaskLinker(), jira: nil, engine: e)
    }
}

private let day = "2026-10-29"
private func h(_ x: Double) -> Double { D0 + x * H }

@Suite struct SuggestTests {
    @Test func answersAreChecked() {
        let segs: Set<String> = ["S1", "S2", "S3"], keys: Set<String> = ["PROJ-1", "OPS-2"]
        let p = { (t: String) in TaskSuggester.parse(t, segments: segs, keys: keys, min: 0.6) }
        #expect(p("not json at all").isEmpty && p("[{]").isEmpty && p("").isEmpty)
        let r = p("""
            Sure! ```json
            [{"segment": "S1", "key": "proj-1", "confidence": 0.9, "reason": "\(String(repeating: "x", count: 200))"},
             {"segment": "S1", "key": "OPS-2", "confidence": 0.7, "reason": "less sure"},
             {"segment": "S2", "key": "NOPE-9", "confidence": 0.99, "reason": "not offered"},
             {"segment": "S3", "key": "OPS-2", "confidence": 0.3, "reason": "too unsure"},
             {"segment": "S9", "key": "OPS-2", "confidence": 0.9, "reason": "no such segment"},
             {"segment": "S2", "key": "OPS-2", "confidence": "0.8", "reason": "string confidence"},
             {"segment": "S3", "key": "PROJ-1", "confidence": 85, "reason": "percent"},
             {"segment": "S3", "key": "OPS-2", "confidence": 850, "reason": "nonsense"},
             {"key": "OPS-2", "confidence": 0.9}, 42, "x"]
            ```
            """)
        #expect(r.map(\.segment) == ["S1", "S1", "S2", "S3"] && r.map(\.key) == ["PROJ-1", "OPS-2", "OPS-2", "PROJ-1"])
        #expect(r[0].confidence == 0.9 && r[0].reason.count == 80 && r[2].confidence == 0.8 && r[3].confidence == 0.85)
        // Brackets in the text before the array.
        #expect(p(#"Отрезки [S1, S2]: [{"segment": "S2", "key": "OPS-2", "confidence": 0.9, "reason": "x"}]"#).map(\.key) == ["OPS-2"])
    }

    /// A suggestion counts nowhere (time, plan) until accepted; accepted it is a manual link for its period only;
    /// asking again does not call the AI twice or add the same suggestion twice; a rejected task is not offered again.
    @Test func suggestAcceptReject() throws {
        var x = try SuggestFixture()
        let a = try x.tasks.add(title: "Encoder research", key: "PROJ-1"), b = try x.tasks.add(title: "Meetings", key: "OPS-2")
        try x.tasks.setStatus(a.id, .inProgress); try x.tasks.setStatus(b.id, .inProgress)
        try x.f.session("claude:s1", title: "encoder gains", working: [(h(9), h(10)), (h(10.1), h(11))])
        try x.f.session("claude:s2", title: "standup notes", working: [(h(12), h(12.5))])
        try x.f.session("claude:s3", working: [(h(13), h(13.05))])                       // 3 min: not worth asking
        try x.f.session("claude:s4", title: "PROJ-1 tuning", working: [(h(14), h(15))])  // linked by its title
        x.calls.answer = #"[{"segment": "S1", "key": "PROJ-1", "confidence": 0.85, "reason": "encoder"}, {"segment": "S2", "key": "OPS-2", "confidence": 0.7, "reason": "standup"}]"#
        let r = try x.s.suggest(day, now: h(20))
        #expect(r.made && r.engine == "claude" && r.segments == 2 && r.asked == 2 && x.calls.n == 1 && r.costUSD == 0.0031 && r.inputTokens == 2500)
        #expect(x.calls.prompt.contains("PROJ-1 — Encoder research") && x.calls.prompt.contains("сессия «encoder gains»") && !x.calls.prompt.contains("PROJ-1 tuning"))
        #expect(r.items.map(\.key) == ["PROJ-1", "OPS-2"] && r.items[0].start == h(9) && r.items[0].end == h(11))
        #expect(abs(r.items[0].workedSec - 1.9 * H) < 1e-6 && r.items[0].reason == "encoder" && r.items[0].confidence == 0.85)

        // Not counted yet: the time and the plan see only the title link of s4.
        let before = try TaskTime.compute(x.f.store, from: D0, to: D0 + 24 * H, base: .sessions)
        #expect(abs((before.lines[a.id]?.userSec ?? 0) - H) < 1e-6 && before.lines[b.id] == nil)
        let plan0 = try DayWorklog(store: x.f.store, linker: try TaskLinker(), jira: nil).plan(day).plan
        #expect(plan0.rows.filter { $0.taskId == b.id }.isEmpty)
        #expect(try x.tasks.links(b.id).isEmpty)

        // Asked again: the stored ones, no new call, no duplicates.
        let again = try x.s.suggest(day, now: h(21))
        #expect(!again.made && x.calls.n == 1 && again.items.map(\.id) == r.items.map(\.id))

        let ids = r.items.map(\.id)
        #expect(try x.s.accept([ids[0]]) == ["#\(ids[0]) accepted: PROJ-1 09:00–11:00"])
        #expect(try x.s.reject([ids[1]]) == ["#\(ids[1]) rejected: OPS-2 is not suggested for this session again"])
        #expect(try x.s.accept([ids[1]]) == ["#\(ids[1]): no such open suggestion"])
        let after = try TaskTime.compute(x.f.store, from: D0, to: D0 + 24 * H, base: .sessions)
        #expect(abs((after.lines[a.id]?.userSec ?? 0) - 2.9 * H) < 1e-6)
        let m = try x.tasks.linkMap()
        #expect(m.tasks("claude:s1", at: h(10.5)).map(\.task) == [a.id] && m.tasks("claude:s1", at: h(11.5)).isEmpty)
        #expect(try x.tasks.links(b.id).isEmpty && x.s.blocked().contains("\(b.id) claude:s2"))
        let plan1 = try DayWorklog(store: x.f.store, linker: try TaskLinker(), jira: nil).plan(day).plan
        #expect(plan1.rows.filter { $0.taskId == a.id }.reduce(0) { $0 + $1.seconds } == 10500)   // 2 h 54 m on the 5-minute grid
        #expect(try x.s.list(day).isEmpty)

        // Again from scratch: s1 is linked now, so s2's stretch is S1; OPS-2 was rejected for s2 and is not stored.
        x.calls.answer = #"[{"segment": "S1", "key": "OPS-2", "confidence": 0.9, "reason": "standup"}]"#
        let r2 = try x.s.suggest(day, again: true, now: h(22))
        #expect(r2.made && x.calls.n == 2 && r2.segments == 1 && r2.items.isEmpty)
    }

    @Test func withoutAISharedWords() throws {
        var x = try SuggestFixture(engine: "none")
        let a = try x.tasks.add(title: "Парсер журналов и выгрузка отчётов", key: "PROJ-5")
        _ = try x.tasks.add(title: "Созвоны", key: "OPS-7")
        try x.tasks.setStatus(a.id, .inProgress)
        try x.f.session("claude:s1", title: "Парсер журналов: правка выгрузки", working: [(h(9), h(10))])
        try x.f.session("claude:s2", title: "что-то другое", working: [(h(11), h(12))])
        x.s.minConfidence = 0.6
        let r = try x.s.suggest(day, now: h(20))
        #expect(x.calls.n == 0 && r.engine == "none" && r.segments == 2)
        #expect(r.items.map(\.key) == ["PROJ-5"] && r.items[0].sessionId == "claude:s1" && r.items[0].confidence == 0.7)
        #expect(r.items[0].reason.hasPrefix("общие слова: "))
    }

    /// A failed AI call falls back to shared words and says so.
    @Test func failedCallFallsBack() throws {
        var x = try SuggestFixture()
        _ = try x.tasks.add(title: "Parser rewrite", key: "PROJ-1")
        try x.f.session("claude:s1", title: "parser rewrite part two", working: [(h(9), h(10))])
        let calls = x.calls
        x.s.engine.runner = { _, _, _, _ in calls.n += 1; return (1, [], []) }
        let r = try x.s.suggest(day, now: h(20))
        #expect(calls.n == 1 && r.engine == "none" && r.note?.contains("failed") == true && r.items.map(\.key) == ["PROJ-1"])
    }

    /// `[notify] lang = en`: the evening message, its buttons and the ask (reasons in English) are English.
    @Test func englishMessageAndPrompt() throws {
        let x = try SuggestFixture(lang: .en)
        let a = try x.tasks.add(title: "Encoder research", key: "PROJ-1")
        try x.tasks.setStatus(a.id, .inProgress)
        try x.f.session("claude:s1", title: "encoder gains", working: [(h(9), h(10))])
        x.calls.answer = #"[{"segment": "S1", "key": "PROJ-1", "confidence": 0.9, "reason": "same encoder work"}]"#
        let m = try #require(try x.s.message(day, now: h(19)))
        #expect(x.calls.prompt.contains("Write reason in English") && x.calls.prompt.contains("session \"encoder gains\"")
                && !x.calls.prompt.contains("сессия"), "\(x.calls.prompt)")
        #expect(m.title == "Task suggestions" && m.text.contains("work without a task key") && m.text.contains("— 1 h, 09:00–10:00")
                && m.text.contains("same encoder work (90%)"), "\(m.text)")
        #expect(m.buttons[0][0].text.hasPrefix("Yes #") && m.buttons[0][1].text.hasPrefix("No #"))
    }

    @Test func thresholdFromConfig() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        Sys.writeFile(dir + "/config.toml", Array("[tasks]\nsuggest_min_confidence = 0.55 # lower\n".utf8), mode: 0o644)
        let s = try TaskSuggester.load(store: try Store(path: ":memory:"), paths: ZagonPaths(home: dir, dir: dir), config: NotifyConfig(),
                                       claudeRoot: dir)
        #expect(s.minConfidence == 0.55 && s.jira == nil)
    }

    @Test func botButtons() throws {
        let x = try SuggestFixture()
        let a = try x.tasks.add(title: "Encoder research", key: "PROJ-1")
        try x.tasks.setStatus(a.id, .inProgress)
        try x.f.session("claude:s1", title: "encoder gains", working: [(h(9), h(10))])
        #expect(try x.s.message("2026-10-28") == nil)                                  // a day without work: nothing to send
        x.calls.answer = #"[{"segment": "S1", "key": "PROJ-1", "confidence": 0.9, "reason": "encoder"}]"#
        let m = try #require(try x.s.message(day, now: h(19)))
        let id = try #require(try x.s.list(day).first?.id)
        #expect(m.text.contains("#\(id) PROJ-1 — 1 ч") && m.text.contains("encoder (90 %)"), "\(m.text)")
        let t9 = Int(h(9))
        #expect(m.buttons == [[.init("Да #\(id) PROJ-1", "sg:y:\(id):\(a.id):\(t9)"), .init("Нет #\(id)", "sg:n:\(id):\(a.id):\(t9)")]])
        #expect(m.buttons[0][0].data.utf8.count <= 64)
        #expect(try x.s.callback("day:2026-10-29") == nil && x.s.callback("sg:y:\(id)") == nil)
        // An id reused by another task or another period.
        #expect(try x.s.callback("sg:y:\(id):\(a.id + 1):\(t9)")?.text == "#\(id): no such open suggestion")
        #expect(try x.s.callback("sg:y:\(id):\(a.id):\(t9 + 60)")?.text == "#\(id): no such open suggestion")
        #expect(try x.s.callback("sg:y:\(id):\(a.id):\(t9)")?.text == "#\(id) accepted: PROJ-1 09:00–10:00")
        #expect(try x.s.callback("sg:n:\(id):\(a.id):\(t9)")?.text == "#\(id): no such open suggestion")
        // Without a bot: no buttons, the commands instead; off: no message.
        var y = try SuggestFixture()
        _ = try y.tasks.add(title: "Encoder research", key: "PROJ-1")
        try y.f.session("claude:s1", title: "encoder gains", working: [(h(9), h(10))])
        y.calls.answer = x.calls.answer
        let plain = try #require(try y.s.message(day, buttons: false, now: h(19)))
        #expect(plain.buttons.isEmpty && plain.text.contains("zagon task accept"))
        y.s.evening = false
        #expect(try y.s.message(day, now: h(19)) == nil)
    }
}

@Suite struct SuggestFlowTests {
    /// "No" keeps the task's links to the session that came from keys; the next most confident task gets the stretch.
    @Test func rejectKeepsKeyedLinks() throws {
        let x = try SuggestFixture()
        let a = try x.tasks.add(title: "Encoder research", key: "PROJ-1"), b = try x.tasks.add(title: "Meetings", key: "OPS-2")
        try x.tasks.setStatus(a.id, .inProgress); try x.tasks.setStatus(b.id, .inProgress)
        try x.f.session("claude:s1", working: [(h(9), h(10)), (h(12), h(13))])
        try x.f.message("claude:s1", h(9), keys: ["PROJ-1"])                       // reaches 10:00; the pause ends it
        x.calls.answer = #"[{"segment": "S1", "key": "PROJ-1", "confidence": 0.9, "reason": "same work"}, {"segment": "S1", "key": "OPS-2", "confidence": 0.75, "reason": "second"}]"#
        let r = try x.s.suggest(day, now: h(20))
        #expect(r.items.map(\.key) == ["PROJ-1"] && r.items[0].start == h(12))
        #expect(try x.s.reject([r.items[0].id]).first?.contains("not suggested for this session again") == true)
        #expect(try x.tasks.linkMap().tasks("claude:s1", at: h(9.5)).map(\.task) == [a.id])   // the typed key's time stays
        let r2 = try x.s.suggest(day, again: true, now: h(21))
        #expect(r2.items.map(\.key) == ["OPS-2"] && r2.items[0].reason == "second")
    }

    /// A suggestion whose time got a link since is not accepted (and no longer listed); an earlier call of the day
    /// asks later only about the new work; a failed call is asked again.
    @Test func staleTopUpAndRetry() throws {
        let x = try SuggestFixture()
        let a = try x.tasks.add(title: "Encoder research", key: "PROJ-1"), b = try x.tasks.add(title: "Meetings", key: "OPS-2")
        try x.tasks.setStatus(a.id, .inProgress); try x.tasks.setStatus(b.id, .inProgress)
        try x.f.session("claude:s1", title: "encoder gains", working: [(h(9), h(10))])
        x.calls.answer = #"[{"segment": "S1", "key": "PROJ-1", "confidence": 0.9, "reason": "encoder"}]"#
        let r = try x.s.suggest(day, now: h(10.5))
        #expect(x.calls.n == 1 && r.items.count == 1)

        // New work after that call: only it is asked about.
        try x.f.session("claude:s2", title: "standup notes", working: [(h(11), h(12))])
        x.calls.answer = #"[{"segment": "S1", "key": "OPS-2", "confidence": 0.8, "reason": "standup"}]"#
        let r2 = try x.s.suggest(day, now: h(13))
        #expect(x.calls.n == 2 && r2.made && r2.asked == 1 && !x.calls.prompt.contains("encoder gains") && x.calls.prompt.contains("standup notes"))
        #expect(Set(r2.items.map(\.key)) == ["PROJ-1", "OPS-2"])
        #expect(try !x.s.suggest(day, now: h(14)).made && x.calls.n == 2)       // nothing new

        // s1 is linked by hand to OPS-2 meanwhile: the PROJ-1 suggestion is stale.
        let stale = try #require(r2.items.first { $0.key == "PROJ-1" })
        try x.tasks.link(b.id, session: "claude:s1", how: .manual)
        #expect(try x.s.list(day).map(\.key) == ["OPS-2"])
        #expect(try x.s.accept([stale.id]) == ["#\(stale.id) not accepted: that time is linked to OPS-2 now; suggestion dropped"])

        // A failed call leaves no mark: the next one asks again.
        let y = try SuggestFixture()
        let c = try y.tasks.add(title: "Encoder research", key: "PROJ-1")
        try y.tasks.setStatus(c.id, .inProgress)
        try y.f.session("claude:s1", title: "something else", working: [(h(9), h(10))])
        let calls = y.calls
        var s = y.s
        s.engine.runner = { _, _, _, _ in calls.n += 1; return (1, [], []) }
        #expect(try s.suggest(day, now: h(20 + 1.0 / 60)).note?.contains("asked next time") == true)
        #expect(try s.suggest(day, now: h(20 + 2.0 / 60)).made && calls.n == 2)
    }

    /// "No" without any other link: a key typed later in that session still counts.
    @Test func rejectDoesNotBlockLaterKeys() throws {
        let x = try SuggestFixture()
        let a = try x.tasks.add(title: "Encoder research", key: "PROJ-1")
        try x.tasks.setStatus(a.id, .inProgress)
        try x.f.session("claude:s1", working: [(h(9), h(10))])
        x.calls.answer = #"[{"segment": "S1", "key": "PROJ-1", "confidence": 0.9, "reason": "x"}]"#
        let id = try #require(try x.s.suggest(day, now: h(20)).items.first?.id)
        _ = try x.s.reject([id])
        try x.f.message("claude:s1", h(9), keys: ["PROJ-1"])
        try TaskLinker().linkSessions(x.f.store)
        #expect(try x.tasks.linkMap().tasks("claude:s1", at: h(9.5)).map(\.task) == [a.id])
    }

    /// Asked periods, not one time mark: work going on right after an open suggestion, stretches the size limit left
    /// out, and the rest after a failed call are all asked later; costs add up.
    @Test func everyStretchIsAskedOnce() throws {
        var x = try SuggestFixture()
        let a = try x.tasks.add(title: "Encoder research", key: "PROJ-1")
        try x.tasks.setStatus(a.id, .inProgress)
        try x.f.session("claude:s1", title: "encoder gains", working: [(h(9), h(10))])
        x.calls.answer = #"[{"segment": "S1", "key": "PROJ-1", "confidence": 0.9, "reason": "x"}]"#
        _ = try x.s.suggest(day, now: h(10))
        try x.f.interval("claude:s1", h(10), h(10 + 40.0 / 60))                    // the same stretch goes on
        let r = try x.s.suggest(day, now: h(11))
        #expect(x.calls.n == 2 && r.asked == 1 && x.calls.prompt.contains("10:00–10:40"), "\(x.calls.prompt)")
        #expect(try x.s.meta("suggest:" + day)?["cost"]?.double == 0.0062)

        // A tiny limit: one stretch per call, the other comes next time.
        var y = try SuggestFixture()
        let b = try y.tasks.add(title: "Encoder research", key: "PROJ-1")
        try y.tasks.setStatus(b.id, .inProgress)
        try y.f.session("claude:s1", title: "first", working: [(h(9), h(10))])
        try y.f.session("claude:s2", title: "second", working: [(h(11), h(11.5))])
        y.s.promptLimit = TaskSuggester.instruction(.ru).count + 130   // the task line and one stretch
        y.calls.answer = "[]"
        #expect(try y.s.suggest(day, now: h(20)).asked == 1 && y.calls.prompt.contains("«first»") && !y.calls.prompt.contains("«second»"))
        #expect(try y.s.suggest(day, now: h(20.1)).asked == 1 && y.calls.prompt.contains("«second»") && y.calls.n == 2)
        #expect(try !y.s.suggest(day, now: h(20.2)).made && y.calls.n == 2)

        // A failed call: the shared-words suggestion keeps its reason, the other stretch is asked next time.
        let z = try SuggestFixture()
        let c = try z.tasks.add(title: "Parser rewrite", key: "PROJ-2")
        try z.tasks.setStatus(c.id, .inProgress)
        try z.f.session("claude:s1", title: "parser rewrite part two", working: [(h(9), h(10))])
        try z.f.session("claude:s2", title: "something else", working: [(h(11), h(12))])
        let calls = z.calls
        var s = z.s
        s.engine.runner = { _, _, _, _ in calls.n += 1; return (1, [], []) }
        let f = try s.suggest(day, now: h(20))
        #expect(f.items.map(\.reason) == ["общие слова: parser, rewrite"] && f.items[0].confidence == 0.7)
        _ = try s.suggest(day, now: h(20.1))
        #expect(calls.n == 2)
        s.engine.runner = { _, input, _, _ in
            calls.n += 1; calls.prompt = String(decoding: input, as: UTF8.self)
            return (0, Array(#"{"is_error":false,"result":"[]"}"#.utf8), [])
        }
        _ = try s.suggest(day, now: h(20.2))
        #expect(calls.n == 3 && calls.prompt.contains("«something else»") && !calls.prompt.contains("«parser rewrite part two»"))
    }

    @Test func stretchesAreCut() throws {
        let x = try SuggestFixture()
        try x.f.session("claude:s1", working: [(h(9), h(11.5))])                  // 2 h 30 m: 2 h + 30 m
        try x.f.session("claude:s2", working: [(h(13), h(15.1))])                 // 2 h 6 m: the 6 m rest is too short
        try x.f.session("claude:s3", working: [(h(16), h(16.5)), (h(17), h(17.5))])  // a 30 m pause: two stretches
        let segs = try x.s.segments(from: D0, to: D0 + 24 * H)
        #expect(segs.map { ($0.session, $0.start, $0.end) }.map { "\($0.0) \(($0.1 - D0) / H)-\(($0.2 - D0) / H)" } == [
            "claude:s1 9.0-11.0", "claude:s1 11.0-11.5", "claude:s2 13.0-15.0", "claude:s3 16.0-16.5", "claude:s3 17.0-17.5"])
        #expect(segs.map(\.id) == ["S1", "S2", "S3", "S4", "S5"])
    }

    @Test func promptStaysSmall() {
        var segs: [TaskSuggester.Segment] = [], facts: [String: TaskSuggester.Facts] = [:], cands: [TaskSuggester.Candidate] = []
        for i in 0..<40 {
            segs.append(.init(id: "S\(i + 1)", session: "s\(i)", start: h(9), end: h(10), worked: Double(i) * 60))
            var f = TaskSuggester.Facts(project: "project \(i)", title: String(repeating: "word ", count: 40), cwd: "/work/p\(i)")
            f.prompts = (0..<5).map { (h(9) + Double($0), String(repeating: "typed ", count: 40)) }
            f.files = (0..<20).map { (h(9) + Double($0), "/work/file\($0).swift") }
            facts["s\(i)"] = f
        }
        for i in 0..<20 {
            cands.append(.init(task: TaskItem(id: i, key: "PROJ-\(i)", title: String(repeating: "title ", count: 30), description: nil,
                                              status: .inProgress, jiraKey: nil, created: 0, updated: 0),
                               description: String(repeating: "about ", count: 60), comments: ["c1", "c2"], worklogs: ["w1"]))
        }
        let (text, asked) = TaskSuggester.prompt(segs, facts, cands)
        #expect(text.count <= TaskSuggester.maxPrompt && !asked.isEmpty && asked.count < 40 && asked.first == "S40")
        #expect(Set(asked).isSubset(of: Set(segs.map(\.id))))
    }
}
