import Foundation
import Testing
@testable import ZagonCore

/// `zagon setup jira`, `zagon notify setup`: files and config keys.
@Suite struct SetupFileTests {
    @Test func secretIs0600EvenOverAnOpenFile() throws {
        let dir = makeTempDir(), p = dir + "/sub/jira-token"
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        Sys.writeFile(p, Array("old\n".utf8), mode: 0o644)
        try Setup.writeSecret(p, "tok\n")
        var st = stat()
        #expect(stat(p, &st) == 0 && st.st_mode & 0o777 == 0o600)
        #expect(Sys.readFile(p) == Array("tok\n".utf8) && !Sys.exists(p + ".zagon-tmp"))
    }

    @Test func jiraKeysInOrderOtherLinesKept() throws {
        let dir = makeTempDir(), paths = ZagonPaths(home: dir, dir: dir)
        Sys.writeFile(paths.config, Array("# mine\ntimezone = \"UTC\"\n\n[jira]\nreview_statuses = [\"qa\"]\nurl = \"https://old.atlassian.net\"\n\n[notify]\nlang = \"en\"\n".utf8))
        try Setup.saveJira(paths, url: "https://team.atlassian.net", email: "me@example.com", token: "secret-token")
        var text = String(decoding: Sys.readFile(paths.config)!, as: UTF8.self)
        #expect(text == "# mine\ntimezone = \"UTC\"\n\n[jira]\nemail = \"me@example.com\"\ntoken_file = \"\(dir)/jira-token\"\n"
                    + "review_statuses = [\"qa\"]\nurl = \"https://team.atlassian.net\"\n\n[notify]\nlang = \"en\"\n")
        #expect(Sys.readFile(dir + "/jira-token") == Array("secret-token\n".utf8))
        // No token typed: the token file stays as set.
        Sys.writeFile(paths.config, Array(text.replacing("\(dir)/jira-token", with: "~/own-token").utf8))
        try Setup.saveJira(paths, url: "https://team.atlassian.net", email: "other@example.com", token: nil)
        text = String(decoding: Sys.readFile(paths.config)!, as: UTF8.self)
        let c = try #require(JiraConfig.load(configText: text))
        #expect(c.email == "other@example.com" && c.tokenFile == "~/own-token" && c.reviewStatuses == ["qa"])
    }

    @Test func newConfigIs0600() throws {
        let dir = makeTempDir(), paths = ZagonPaths(home: dir, dir: dir + "/data")
        try Setup.saveTelegram(paths, token: "123:abc", chatId: "-100200")
        try Setup.saveNtfy(paths, topic: "zagon-x", url: "https://ntfy.sh")
        var st = stat()
        #expect(stat(paths.config, &st) == 0 && st.st_mode & 0o777 == 0o600)
        let c = NotifyConfig.load(paths)
        #expect(c.telegramTokenFile == dir + "/data/telegram-token" && c.telegramChatId == "-100200")
        #expect(c.ntfyTopic == "zagon-x" && c.ntfyURL == "https://ntfy.sh")
        #expect(Sys.readFile(dir + "/data/telegram-token") == Array("123:abc\n".utf8))
        let t = Setup.ntfyTopic()
        #expect(t.hasPrefix("zagon-") && t.count == 22 && t != Setup.ntfyTopic())
    }

    @Test func jiraAddress() {
        #expect(Setup.jiraURL("team.atlassian.net") == "https://team.atlassian.net")
        #expect(Setup.jiraURL(" https://team.atlassian.net/jira/software/projects/P/boards/1 ") == "https://team.atlassian.net")
        #expect(Setup.jiraURL("https://jira.example.com/jira/") == "https://jira.example.com/jira")
    }

    @Test func chatOfTheNewestMessage() throws {
        let u = try #require(JValue.parse(#"""
            [{"update_id": 1, "message": {"date": 100, "chat": {"id": 5, "first_name": "Old"}}},
             {"update_id": 2, "message": {"date": 1000, "chat": {"id": -1001234567890123, "title": "Team"}}},
             {"update_id": 3, "message": {"date": 1001, "chat": {"id": 42, "first_name": "Ann", "last_name": "Lee"}}},
             {"update_id": 4, "callback_query": {"id": "x"}}]
            """#))
        #expect(Setup.Bot.chat(u) == .init(id: "42", name: "Ann Lee"))
        #expect(Setup.Bot.chat(.array(Array(u.array!.prefix(2)))) == .init(id: "-1001234567890123", name: "Team"))
        #expect(Setup.Bot.chat(.array(Array(u.array!.suffix(1)))) == nil)
    }
}

/// Against the local mocks of Jira and of the Bot API.
@Suite(.serialized, .enabled(if: hasTool("python3") && hasTool("curl"), "needs python3 and curl"), .timeLimit(.minutes(1)))
struct SetupMockTests {
    @Test func jiraCheckTypedAndSavedToken() throws {
        let m = try JiraMock(state: JiraClientTests.state)
        #expect(try Setup.checkJira(url: m.url, email: "me@example.com", token: "secret-token", saved: nil) == "acc-me")
        #expect(try Setup.checkJira(url: m.url, email: "me@example.com", token: nil, saved: m.config) == "acc-me")
        do {
            _ = try Setup.checkJira(url: m.url, email: "me@example.com", token: "wrong", saved: nil)
            Issue.record("a wrong token passed")
        } catch { #expect(Setup.why(error).hasPrefix("Jira refused the login (HTTP 401)") && !Setup.why(error).contains("wrong")) }
        #expect(throws: JiraError.self) { try Setup.checkJira(url: "http://jira.example.com", email: "a@b", token: "t", saved: nil) }
    }

    /// What waits already is a backlog: confirmed and skipped; the message after it is the user's, whatever its date.
    @Test func botWaitsForAMessage() throws {
        let dir = makeTempDir(), mock = try MockHTTP(dir: dir), log = mock.log, updates = dir + "/updates.json"
        try #"[{"update_id": 7, "message": {"date": 100, "chat": {"id": 5, "first_name": "Old"}}}]"#
            .write(toFile: updates, atomically: true, encoding: .utf8)
        // After the second poll (the backlog has been read), the user writes; the date is far off this machine's clock.
        let writer = Thread {
            while ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").components(separatedBy: "getUpdates").count < 3 { usleep(5000) }
            try? #"[{"update_id": 9, "message": {"date": 5, "chat": {"id": 42, "first_name": "Me"}}}]"#
                .write(toFile: updates, atomically: true, encoding: .utf8)
        }
        writer.start()
        let bot = Setup.Bot(curl: try #require(Curl()), api: "http://127.0.0.1:\(mock.port)/", token: "123:SECRET")
        #expect(try bot.name() == "@?")
        #expect(try bot.waitForChat(deadline: Sys.now() + 10) == .init(id: "42", name: "Me"))
        let r = mock.requests.filter { $0.path.hasSuffix("/getUpdates") }.compactMap { JValue.parse($0.body) }
        #expect(mock.requests.first?.path == "/bot123:SECRET/getMe" && r.count >= 3)
        #expect(r.first?["timeout"] == .number("0") && r.first?["offset"] == nil)
        #expect(r.dropFirst().allSatisfy { $0["offset"] == .number("8") } && r.allSatisfy { $0["allowed_updates"] == nil })
    }

    /// The day of `JiraClientTests.state` (2026-10-29, UTC): PROJ-1 worked 05:00–09:00, Jira has 06:00–07:00 on PROJ-1
    /// and 11:30–12:00 on PROJ-2 (an issue that is no task here).
    func day() throws -> Fixture {
        let f = try Fixture()
        try Tasks(store: f.store).add(title: "dialogs", key: "PROJ-1")
        try f.session("claude:a", branch: "PROJ-1", title: "Dialog work", working: [(D0 + 5 * H, D0 + 9 * H)], actions: [D0 + 5 * H])
        try f.user([(D0 + 5 * H, D0 + 9 * H)])
        return f
    }

    @Test func hoursArePlanAndJira() throws {
        let m = try JiraMock(state: JiraClientTests.state), j = try JiraClient(m.config), f = try day()
        let w = DayWorklog(store: f.store, linker: try TaskLinker(), jira: j)
        let (lines, err) = try w.hours(from: "2026-10-28", to: "2026-10-31", today: "2026-10-29")
        #expect(err == nil)
        let planned = lines.filter { $0.state == "planned" }, logged = lines.filter { $0.state == "logged" }
        #expect(planned.reduce(0) { $0 + $1.seconds } == Int(3 * H) && planned.allSatisfy { $0.jiraKey == "PROJ-1" && $0.title == "dialogs" })
        #expect(logged.map(\.jiraKey) == ["PROJ-1", "PROJ-2"] && logged.map(\.seconds) == [3600, 1800])
        #expect(logged[1].title == "Done one" && logged[1].taskKey == nil)
        #expect(lines.map(\.start) == lines.map(\.start).sorted())
        for (a, b) in zip(lines, lines.dropFirst()) { #expect(a.start + Double(a.seconds) <= b.start) }

        // A planned row written to Jira comes back once, from Jira.
        let r = try #require(planned.first), row = try #require(try Worklog(store: w.store).rows(day: "2026-10-29").first { $0.start == r.start })
        try Worklog(store: w.store).mark(row.id, state: "logged",
                                         jiraWorklogId: try j.addWorklog(issue: "PROJ-1", started: r.start, seconds: r.seconds, comment: r.text))
        let again = try w.hours(from: "2026-10-29", to: "2026-10-29", today: "2026-10-29").lines
        #expect(again.reduce(0) { $0 + $1.seconds } == lines.reduce(0) { $0 + $1.seconds })
        #expect(again.filter { $0.start == r.start }.map(\.state) == ["logged"])

        // Jira set up but not readable: the plans as kept and Zagon's own logged row; the worklog by hand is missing.
        let off = DayWorklog(store: f.store, linker: try TaskLinker(), jira: nil, jiraSetupError: "jira token: cannot read")
        let (kept, why) = try off.hours(from: "2026-10-29", to: "2026-10-29", today: "2026-10-29")
        #expect(why == "jira token: cannot read")
        #expect(kept.reduce(0) { $0 + $1.seconds } == Int(3 * H) && kept.filter { $0.state == "logged" }.map(\.start) == [r.start])

        // A write that never reached Jira (left `writing`) is settled and planned again, not lost.
        let other = try #require(try Worklog(store: f.store).rows(day: "2026-10-29").first { $0.state == "planned" })
        try Worklog(store: f.store).mark(other.id, state: "writing")
        let settled = try w.hours(from: "2026-10-29", to: "2026-10-29", today: "2026-10-29").lines
        #expect(settled.filter { $0.start == other.start }.map(\.state) == ["planned"])
        #expect(settled.reduce(0) { $0 + $1.seconds } == again.reduce(0) { $0 + $1.seconds })
    }

    /// `2026-10-1` is `2026-10-01` (no plan rows under another key); a date that does not exist is refused.
    @Test func hoursDatesAreNormalized() throws {
        let f = try day(), w = DayWorklog(store: f.store, linker: try TaskLinker(), jira: nil)
        let lines = try w.hours(from: "2026-10-1", to: "2026-10-31", today: "2026-10-29").lines
        #expect(lines.reduce(0) { $0 + $1.seconds } == Int(4 * H) && lines.allSatisfy { $0.day == "2026-10-29" && $0.state == "planned" })
        #expect(try f.store.db.one("SELECT count(*) FROM worklog_plan WHERE length(day) != 10") { $0.int(0) } == 0)
        #expect(throws: TaskError.self) { try w.hours(from: "2026-02-30", to: "2026-03-02", today: "2026-10-29") }
    }
}

@Suite struct HoursTextTests {
    let lines = [
        HoursLine(day: "2026-10-29", start: D0 + 9 * H + 5 * 60, seconds: 5400, jiraKey: "PROJ-1", taskKey: "PROJ-1", title: "Dialogs",
                  text: "Fixed the \"save\" step,\nthen tests", state: "planned"),
        HoursLine(day: "2026-10-29", start: D0 + 13 * H, seconds: 1799, jiraKey: nil, taskKey: "ZAG-2", title: "Own", text: "", state: "logged"),
    ]

    @Test func csv() {
        #expect(HoursText.csv(lines) == """
            date,start,end,hours,task,title,text,state
            2026-10-29,09:05,10:35,1.50,PROJ-1,Dialogs,"Fixed the ""save"" step,
            then tests",planned
            2026-10-29,13:00,13:29,0.50,ZAG-2,Own,,logged

            """)
    }

    /// Toggl Track's import columns: Email, Start Date, Start Time, Duration (HH:MM:SS), Description, Project.
    @Test func toggl() {
        #expect(HoursText.toggl(lines, email: "me@example.com") == """
            Email,Start Date,Start Time,Duration,Description,Project
            me@example.com,2026-10-29,09:05:00,1:30:00,"PROJ-1 Fixed the ""save"" step, then tests",PROJ
            me@example.com,2026-10-29,13:00:00,0:29:59,ZAG-2 Own,

            """)
        #expect(HoursText.duration(36 * 3600 + 61) == "36:01:01" && HoursText.hours(0) == "0.00" && HoursText.hours(17) == "0.00")
        #expect(HoursText.safe("=1+1") == "'=1+1" && HoursText.safe("- fixed") == "'- fixed" && HoursText.safe("@x") == "'@x")
        #expect(HoursText.safe("plain") == "plain" && HoursText.safe("") == "")
    }
}
