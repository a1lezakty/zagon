import Foundation
import Testing
@testable import ZagonCore

@Suite struct SummaryDocTests {
    let refs = [SummaryDoc.Ref(project: "alpha", sec: 3600, cost: 4, keys: ["PROJ-1"]), .init(project: "alpha", sec: 600, cost: 1),
                .init(project: "beta", sec: 1200, cost: 2, keys: ["PROJ-2"])]

    @Test func readsTheAnswer() throws {
        let answer = """
            Here it is:
            ```json
            {"overview": "Day  in\\n two lines", "items": [
              {"project": "alpha", "task": "proj-1", "title": "PROJ-1", "refs": [1, "2", 9], "was": "It crashed",
               "done": ["a", "b", "c", "d", "e", "f"], "left": "—"},
              {"project": "made-up", "task": "XYZ-9", "title": "Theme", "refs": [2], "done": ["g"]},
              {"project": "made-up", "title": "No refs", "done": ["h"]},
              {"project": "alpha", "title": "Nothing done", "refs": [1], "done": []}
            ]}
            ```
            """
        let (doc, unused) = try #require(SummaryDoc.parse(answer: answer, refs: refs, tasks: ["PROJ-1": "Parser crash"], lang: "en",
                                                          from: "2026-10-30", to: "2026-10-30"))
        #expect(doc.overview == "Day in two lines" && doc.key == "2026-10-30" && doc.main.isEmpty)
        #expect(doc.items.count == 2)  // an unknown project without refs and a card without points are dropped
        let a = doc.items[0], b = doc.items[1]
        // A known key (any case) with the task's title; "—" is empty; at most five points.
        #expect(a.key == "PROJ-1" && a.title == "Parser crash" && a.was == "It crashed" && a.left == nil && a.done == ["a", "b", "c", "d", "e"])
        // Time and price come from the refs: ref 2 is in two cards and split, ref 9 does not exist.
        #expect(a.sec == 3900 && a.cost == 4.5)
        // An invented key is dropped, the project is the ref's.
        #expect(b.project == "alpha" && b.key == nil && b.title == "Theme" && b.sec == 300 && b.cost == 0.5)
        #expect(unused == [2])  // beta has no card: the caller adds one
    }

    @Test func unnamedRefsGoToTheirProjectsCard() throws {
        let answer = #"{"overview": "x", "items": [{"project": "alpha", "title": "t", "refs": [1], "done": ["a"]}]}"#
        let (doc, unused) = try #require(SummaryDoc.parse(answer: answer, refs: refs, tasks: [:], lang: "ru", from: "d", to: "d"))
        #expect(doc.items.map(\.sec) == [4200] && unused == [2])
    }

    @Test func keysOnlyOfTheCardsSessionsAndOddRefs() throws {
        // PROJ-2 is a task of the day, but not of ref 2's session; refs as huge numbers or strings of numbers.
        let answer = #"{"items": [{"project": "alpha", "task": "PROJ-2", "title": "Other", "refs": [2, 1e30, 99999999999999999999], "done": ["a"]},"#
            + #" {"project": "beta", "task": "proj-2", "title": "", "refs": ["3, 1"], "done": ["b"]}]}"#
        let (doc, unused) = try #require(SummaryDoc.parse(answer: answer, refs: refs, tasks: ["PROJ-1": "One", "PROJ-2": "Two"],
                                                          lang: "en", from: "d", to: "d"))
        #expect(doc.overview == "" && unused.isEmpty)  // no overview: the caller puts its own in
        #expect(doc.items.map(\.key) == [nil, "PROJ-2"] && doc.items.map(\.heading) == ["Other", "PROJ-2 Two"])
        #expect(doc.items[0].sec == 600 && doc.items[1].sec == 1200 + 3600 && doc.items[1].project == "beta")
    }

    @Test func rejectsUnusableAnswers() {
        for bad in ["", "no json here", "{\"overview\": \"x\", \"items\": []}", "{oops",
                    #"{"overview": "x", "items": [{"project": "alpha", "title": "t", "refs": [1], "done": []}]}"#] {
            #expect(SummaryDoc.parse(answer: bad, refs: refs, tasks: [:], lang: "ru", from: "d", to: "d") == nil)
        }
    }

    @Test func storedAndShown() {
        let doc = SummaryDoc(lang: "ru", from: "2026-10-26", to: "2026-11-01", overview: "Итог.", main: ["Главное"],
                             items: [.init(project: "alpha", key: "PROJ-1", title: "Парсер", was: "Падал", done: ["починен"],
                                           left: "тесты", sec: 5400, cost: 12.4)])
        #expect(SummaryDoc.decode(doc.json) == doc && SummaryDoc.decode("• старый текст") == nil)
        #expect(doc.key == "2026-10-26..2026-11-01")
        #expect(doc.text() == "Итог.\n\nГлавное:\n• Главное\n\n▸ alpha · PROJ-1 Парсер — 1 ч 30 м, $12\nЧто было: Падал\nЧто сделано:\n• починен\nЧто осталось: тесты")
        #expect(doc.text(markdown: true) == "Итог.\n\n**Главное за период**\n\n- Главное\n\n### alpha · PROJ-1 Парсер — 1 ч 30 м, $12\n\n"
                + "**Что было:** Падал\n\n**Что сделано:**\n- починен\n\n**Что осталось:** тесты")
        #expect(doc.taskText(doc.items[0]) == "починен")
        var en = doc
        en.lang = "en"; en.items[0].cost = 0.2
        #expect(en.text().contains("▸ alpha · PROJ-1 Парсер — 1 h 30 min, <$1\nWhat it was: Падал\nWhat was done:\n• починен"))
    }
}

@Suite struct SummaryKeepTests {
    func summary(_ store: Store, engine: String = "none") -> DaySummary {
        var c = NotifyConfig()
        c.lang = .en; c.summaryEngine = engine
        let dir = makeTempDir()
        var s = DaySummary(store: store, config: c, paths: ZagonPaths(home: dir, dir: dir + "/.zagon"), claudeRoot: dir + "/none")
        s.searchPath = "/usr/bin:/bin"
        s.systemBins = []  // a claude installed on this machine is not the test's
        return s
    }

    func doc(_ day: String, _ items: [SummaryDoc.Item], to: String? = nil) -> SummaryDoc {
        SummaryDoc(lang: "en", from: day, to: to ?? day, overview: "Overview of \(day).", items: items)
    }

    func exported(_ store: Store, since: Int) throws -> (seq: Int, summaries: [JValue]) {
        var lines: [JValue] = []
        try Export.run(store: store, since: since) { lines.append(JValue.parse($0)!) }
        return (Int(lines[0]["seq"]?.double ?? 0), lines.filter { $0["type"]?.string == "summary" })
    }

    @Test func keptAIFirstAndExported() throws {
        let store = try Store(path: ":memory:"), s = summary(store)
        let ai = doc("2026-10-30", [.init(project: "alpha", title: "t", done: ["a"])]), plain = doc("2026-10-30", [])
        try s.save(ai, engine: "claude", now: 100)
        try s.save(plain, engine: "none", now: 200)
        try store.db.run("INSERT INTO summary(day, engine, text, created) VALUES('2026-10-29', 'claude', '• free text', 50)")
        #expect(try s.kept("2026-10-30")?.doc == ai && s.kept("2026-10-30")?.engine == "claude")
        #expect(try s.kept("2026-10-29") == nil && s.kept("2026-10-28") == nil)
        // The first export sends both rows of the day, not the free text; a later one only what changed.
        let first = try exported(store, since: 0)
        #expect(first.summaries.map { $0["engine"]?.string } == ["claude", "none"])
        #expect(try exported(store, since: first.seq).summaries.isEmpty)
        let week = doc("2026-10-26", [.init(project: "alpha", title: "t", done: ["a"], sec: 60)], to: "2026-11-01")
        try s.save(week, engine: "claude", now: 300)
        let next = try exported(store, since: first.seq)
        #expect(next.summaries.map { $0["day"]?.string } == ["2026-10-26..2026-11-01"])
        // The Mac's copy reads the same.
        let mac = try Store(path: ":memory:")
        var lines: [String] = []
        try Export.run(store: store, since: 0) { lines.append($0) }
        try ExportImport(store: mac, source: "box").apply(lines)
        let m = summary(mac)
        #expect(try m.kept("2026-10-30")?.doc == ai && m.kept("2026-10-26..2026-11-01")?.doc == week)
        #expect(try Query(store: mac).day("2026-10-30").summary?.engine == "claude")
        // A copy of an older summary does not replace a newer one.
        var older = lines.first { $0.contains("\"type\":\"summary\"") && $0.contains("\"engine\":\"claude\"") && $0.contains("2026-10-30") }!
        older = older.replacingOccurrences(of: "\"created\":100", with: "\"created\":10").replacingOccurrences(of: "Overview of", with: "Old")
        try ExportImport(store: mac, source: "box").apply([lines[0], older])
        #expect(try m.kept("2026-10-30")?.doc == ai)
    }

    @Test func findsTheCLIWhereItIsInstalled() throws {
        var s = summary(try Store(path: ":memory:"), engine: "claude")
        let bin = s.paths.home + "/.local/bin"
        Sys.mkdirs(bin)
        #expect(writeScript(bin + "/claude", "#!/bin/sh\ncat >/dev/null\nprintf '{\"is_error\":false,\"result\":\"ok\"}'\n"))
        s.searchPath = "/usr/bin:/bin"  // a user service's PATH
        #expect(s.complete("x")?.text == "ok")
        // nvm's node versions, the newest first (v20 after v9 by name).
        var n = summary(try Store(path: ":memory:"), engine: "claude")
        #expect(n.engineCLI == nil && n.missingCLI == "claude" && n.calls(missing: 2) == 0)
        for (v, answer) in [("v9.11.2", "old"), ("v20.1.0", "new"), ("v18.20.4", "mid")] {
            let dir = n.paths.home + "/.nvm/versions/node/\(v)/bin"
            Sys.mkdirs(dir)
            #expect(writeScript(dir + "/claude", "#!/bin/sh\ncat >/dev/null\nprintf '{\"is_error\":false,\"result\":\"\(answer)\"}'\n"))
        }
        #expect(n.complete("x")?.text == "new" && n.missingCLI == nil && n.calls(missing: 2) == 3)
        n.config.summaryEngine = "none"
        #expect(n.missingCLI == nil && n.engineCLI == nil)
    }

    /// Only the editor extension installed: the newest Claude Code it bundles in any VS Code fork (2.1.40 after 2.1.9 by
    /// name), and only after a claude installed the usual way.
    @Test func findsTheCLIOfTheEditorExtensionLast() throws {
        let s = summary(try Store(path: ":memory:"), engine: "claude")
        for (dir, answer) in [(".vscode/extensions/anthropic.claude-code-2.1.9-darwin-arm64", "old"),
                              (".windsurf/extensions/anthropic.claude-code-2.1.40-darwin-arm64", "new"),
                              (".cursor/extensions/anthropic.claude-code-2.1.12", "mid"),
                              (".vscode-oss/extensions/anthropic.claude-code-2.1.30-linux-x64", "oss")] {
            let bin = s.paths.home + "/" + dir + "/resources/native-binary"
            Sys.mkdirs(bin)
            #expect(writeScript(bin + "/claude", "#!/bin/sh\ncat >/dev/null\nprintf '{\"is_error\":false,\"result\":\"\(answer)\"}'\n"))
        }
        #expect(s.complete("x")?.text == "new" && s.missingCLI == nil)
        let local = s.paths.home + "/.local/bin"
        Sys.mkdirs(local)
        #expect(writeScript(local + "/claude", "#!/bin/sh\ncat >/dev/null\nprintf '{\"is_error\":false,\"result\":\"cli\"}'\n"))
        #expect(s.complete("x")?.text == "cli")
    }

    /// A failed AI call keeps why (`zagon summary --json` sends it) and logs it, never with the prompt codex echoes.
    @Test func aFailedCallSaysWhy() throws {
        var s = summary(try Store(path: ":memory:"), engine: "claude")
        let bin = makeTempDir(), root = "--dangerously-skip-permissions cannot be used with root/sudo privileges for security reasons"
        s.searchPath = bin + ":/usr/bin:/bin"
        var logged: [String] = []
        s.log = { logged.append($0) }
        // What claude says as root when the user's settings make bypassPermissions the default mode.
        #expect(writeScript(bin + "/claude", "#!/bin/sh\ncat >/dev/null\necho '\(root)' >&2\nexit 1\n"))
        #expect(s.complete("secret prompt") == nil && s.failure.reason == "claude: " + root)
        #expect(logged == ["summary: claude failed (1): " + root])
        // An error answer: its result is the error (claude exits 1 with it).
        #expect(writeScript(bin + "/claude", "#!/bin/sh\ncat >/dev/null\nprintf '{\"is_error\":true,\"result\":\"Credit balance is too low\"}'\nexit 1\n"))
        #expect(s.complete("x") == nil && s.failure.reason == "claude: Credit balance is too low")
        #expect(writeScript(bin + "/claude", "#!/bin/sh\ncat >/dev/null\nprintf '{\"is_error\":false,\"result\":\"ok\"}'\n"))
        #expect(s.complete("x")?.text == "ok" && s.failure.reason == nil)
        // codex echoes the prompt to stderr: only its last ERROR line counts, else the exit status.
        s.config.summaryEngine = "codex"
        #expect(writeScript(bin + "/codex", "#!/bin/sh\necho 'OpenAI Codex' >&2\necho user >&2\ncat >&2\necho >&2\necho 'ERROR: unexpected status 401 Unauthorized' >&2\nexit 1\n"))
        #expect(s.complete("secret prompt\nERROR: secret") == nil && s.failure.reason == "codex: unexpected status 401 Unauthorized")
        #expect(writeScript(bin + "/codex", "#!/bin/sh\ncat >&2\necho >&2\nexit 2\n"))
        #expect(s.complete("secret prompt\nERROR: secret in a Jira text") == nil && s.failure.reason == "codex: exit 2")
        #expect(!logged.joined().contains("secret"))
    }

    @Test func hostsOfTheDaysSessions() throws {
        let store = try Store(path: ":memory:"), (start, _) = Time.dayBounds("2026-10-30")!
        try store.mergeSession(SessionMeta(id: "claude:a", tool: .claude, project: "alpha"))
        try store.mergeSession(SessionMeta(id: "claude:b", tool: .claude, project: "beta"), host: "zz-box")
        for id in ["claude:a", "claude:b"] {
            try store.addActivity(sessionId: id, start: start + 9 * 3600, end: start + 10 * 3600, kind: "working")
        }
        #expect(try summary(store).facts("2026-10-30").hosts == [store.host, "zz-box"].sorted())
        #expect(try summary(store).make("2026-10-31").doc.hosts == nil)  // no sessions: it does not say
    }

    @Test func taskTextsSkipCardsWithoutPoints() {
        let d = doc("2026-10-30", [.init(project: "alpha", key: "PROJ-1", title: "a", done: ["fixed", ""]),
                                   .init(project: "alpha", key: "PROJ-1", title: "b", done: []),
                                   .init(project: "alpha", key: "PROJ-2", title: "c", done: [""]),
                                   .init(project: "alpha", key: "PROJ-1", title: "d", done: ["tested"]),
                                   .init(project: "beta", title: "e", done: ["x"])])
        #expect(DaySummary.taskTexts(d).map { "\($0.key)=\($0.text)" } == ["PROJ-1=fixed; tested"])
        let long = doc("2026-10-30", [.init(project: "alpha", key: "PROJ-1", title: "a", done: [String(repeating: "x", count: 400)])])
        #expect(DaySummary.taskTexts(long).first?.text.count == 300)
    }

    @Test func writtenOnceAtItsTime() throws {
        let store = try Store(path: ":memory:")
        var s = summary(store)
        s.config.summaryAt = 20 * 60
        #expect(try !s.autoTick(now: day0 + 19 * 3600))
        #expect(try s.autoTick(now: day0 + 20 * 3600 + 30))
        #expect(try !s.autoTick(now: day0 + 21 * 3600))
        #expect(try s.kept("2026-10-30")?.doc.overview == "No sessions this day.")
        s.config.summaryAt = nil
        #expect(try !s.autoTick(now: day0 + 86400 + 21 * 3600))
    }

    @Test func periodsFromTheirDays() throws {
        let store = try Store(path: ":memory:")
        for (i, d) in ["2026-10-26", "2026-10-27", "2026-10-28"].enumerated() {
            let (start, _) = Time.dayBounds(d)!
            try store.mergeSession(SessionMeta(id: "claude:s\(i)", tool: .claude, project: "alpha"))
            try store.addActivity(sessionId: "claude:s\(i)", start: start + 9 * 3600, end: start + 10 * 3600, kind: "working")
        }
        var s = summary(store, engine: "claude")
        // claude is not installed: no AI calls, the days made without AI count as written.
        #expect(s.calls(missing: 2) == 0 && s.missingCLI == "claude")
        let bin = makeTempDir()
        Sys.writeFile(bin + "/claude", [0], mode: 0o755)
        s.searchPath = bin + ":/usr/bin:/bin"
        var first = doc("2026-10-26", [.init(project: "alpha", key: "PROJ-1", title: "Parser", was: "It crashed", done: ["fixed"], sec: 3600, cost: 2)])
        first.hosts = ["mini", "box"]
        try s.save(first, engine: "claude", now: 1)
        try s.save(doc("2026-10-27", [.init(project: "alpha", key: "PROJ-1", title: "Parser", done: ["tests", "fixed"], left: "docs", sec: 1800, cost: 1),
                                      .init(project: "beta", title: "Docs", done: ["readme"], sec: 600),
                                      .init(project: "gamma", title: "Peek", done: ["looked"], sec: 60)]), engine: "none", now: 2)
        let (worked, missing) = try s.days("2026-10-26", "2026-11-01")
        #expect(worked == ["2026-10-26", "2026-10-27", "2026-10-28"] && missing == ["2026-10-27", "2026-10-28"])
        #expect(s.calls(missing: 2) == 3)
        s.searchPath = "/usr/bin:/bin"
        #expect(try s.days("2026-10-26", "2026-11-01").missing == ["2026-10-28"])
        s.searchPath = bin + ":/usr/bin:/bin"
        // Without AI: the cards of one task are merged, nothing is written for the missing days.
        s.config.summaryEngine = "none"
        #expect(try s.days("2026-10-26", "2026-11-01").missing == ["2026-10-28"] && s.calls(missing: 1) == 0)
        let plain = try s.period("2026-10-26", "2026-11-01", make: false, now: 3).doc
        #expect(plain.key == "2026-10-26..2026-11-01" && plain.items.map(\.heading) == ["PROJ-1 Parser", "Docs", "Peek"])
        #expect(plain.items[0].sec == 5400 && plain.items[0].cost == 3 && plain.items[0].done == ["fixed", "tests"]
                && plain.items[0].was == "It crashed" && plain.items[0].left == "docs")
        #expect(plain.main.first == "alpha · PROJ-1 Parser — 1 h 30 min" && plain.overview.hasPrefix("Days with work: 2"))
        #expect(try s.kept(plain.key)?.engine == "none" && plain.hosts == ["box", "mini"])
        // With AI: one call over the days' cards, numbered across days.
        s.config.summaryEngine = "claude"
        var prompts: [String] = []
        s.runner = { argv, input, _, _ in
            prompts.append(String(decoding: input, as: UTF8.self))
            let answer = #"{\"overview\": \"A week on the parser.\", \"main\": [\"Parser fixed\"], \"items\": [{\"project\": \"alpha\", \"task\": \"PROJ-1\", \"title\": \"Parser\", \"refs\": [1, 2], \"done\": [\"fixed and tested\"]}]}"#
            return (0, Array(#"{"is_error":false,"result":"\#(answer)"}"#.utf8), [])
        }
        let (week, engine) = try s.period("2026-10-26", "2026-11-01", make: false, now: 4)
        #expect(engine == "claude" && prompts.count == 1)
        #expect(prompts[0].contains("[1] alpha · PROJ-1 Parser — 1 h") && prompts[0].contains("[3] beta · Docs — 10 min"))
        // Ref 3 the AI left out keeps its card; ref 4 (a minute) does not.
        #expect(week.main == ["Parser fixed"] && week.items.map(\.heading) == ["PROJ-1 Parser", "Docs"])
        #expect(week.items[0].sec == 5400 && week.items[1].sec == 600)
        #expect(try s.kept(week.key)?.engine == "claude")
    }

    @Test func aMonthsDigestHasEveryDay() {
        let item = SummaryDoc.Item(project: "alpha", title: String(repeating: "t", count: 60), was: String(repeating: "w", count: 300),
                                   done: Array(repeating: String(repeating: "d", count: 200), count: 5), left: String(repeating: "l", count: 300), sec: 600)
        let days = DaySummary.range("2026-10-01", "2026-10-31").map { SummaryDoc(lang: "en", from: $0, to: $0, overview: "o", items: Array(repeating: item, count: 6)) }
        let d = DaySummary.periodDigest(days, from: "2026-10-01", to: "2026-10-31", .english)
        #expect(d.count <= DaySummary.maxPeriodDigest && d.contains("[186] alpha") && !d.contains("Was: "))
        let two = DaySummary.periodDigest(Array(days.prefix(2)), from: "2026-10-01", to: "2026-10-02", .english)
        #expect(two.contains("[12] alpha") && two.contains("Was: ") && two.contains("Left: "))  // all of it fits
    }

    @Test func commitsNameTheirTask() {
        #expect(DaySummary.mentions("proj-1: fix", "PROJ-1") && DaySummary.mentions("Fix (PROJ-1)", "PROJ-1"))
        #expect(!DaySummary.mentions("PROJ-12 fix", "PROJ-1") && !DaySummary.mentions("XPROJ-1", "PROJ-1"))
        #expect(DaySummary.mentions("fix #123 now", "#123") && !DaySummary.mentions("fix #1234", "#123"))
    }

    @Test func weeksAndMonths() {
        for d in ["2026-10-26", "2026-10-30", "2026-11-01"] { #expect(DaySummary.week(of: d)! == ("2026-10-26", "2026-11-01")) }
        #expect(DaySummary.month("2026-02")! == ("2026-02-01", "2026-02-28") && DaySummary.month("2026-12")! == ("2026-12-01", "2026-12-31"))
        #expect(DaySummary.month("2026-13") == nil && DaySummary.month("2026-1") == nil)
        #expect(DaySummary.range("2026-10-30", "2026-11-02").count == 4 && DaySummary.range("2026-01-01", "2027-12-31").count == DaySummary.maxDays)
    }

    @Test func summaryTime() throws {
        let c = NotifyConfig.parse("[notify]\nsummary_at = \"21:30\"\n[summary]\ntime = \"19:15\"\n", home: "/h")
        #expect(c.summaryAt == 19 * 60 + 15)
        #expect(NotifyConfig.parse("[summary]\ntime = \"\"\n", home: "/h").summaryAt == nil)
        let dir = makeTempDir(), paths = ZagonPaths(home: dir, dir: dir + "/.zagon")
        Sys.mkdirs(paths.dir)
        Sys.writeFile(paths.config, Array("[notify]\nlang = \"ru\"\n".utf8))
        try Settings.setSummaryTime(paths, "07:05")
        #expect(NotifyConfig.load(paths).summaryAt == 7 * 60 + 5 && NotifyConfig.load(paths).lang == .ru)
        try Settings.setSummaryTime(paths, nil)
        #expect(NotifyConfig.load(paths).summaryAt == nil)
        #expect(throws: SettingsError.self) { try Settings.setSummaryTime(paths, "25:00") }
    }
}
