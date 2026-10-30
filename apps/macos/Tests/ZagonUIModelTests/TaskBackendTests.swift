import Foundation
import XCTest
import ZagonCore
@testable import ZagonUIModel

/// Tasks over a stand-in ssh: it runs the remote command in a shell with a fake HOME whose `zagon` answers with what
/// the core produced for the sample store (the same JSON as `--json`) and writes down every call.
final class TaskBackendTests: XCTestCase {
    var home = ""

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("zagon-tasks-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home + "/.local/bin", withIntermediateDirectories: true)
        try script(home + "/ssh", """
            #!/bin/sh
            for a; do last=$a; done
            HOME='\(home)' exec /bin/sh -c "$last"
            """)
        try script(home + "/.local/bin/zagon", """
            #!/bin/sh
            { for a in "$@"; do printf '%s|' "$a"; done; echo; } >> "$HOME/calls"
            case "$1 $2" in
            "task list") if [ "$3" = --all ] && [ -e "$HOME/old" ]; then echo "Error: Unknown option '--all'" >&2; exit 64; fi
                echo "Last login: a banner"; cat "$HOME/list.json" ;;
            "task show") case "$*" in *NOPE*) echo "Error: no task NOPE" >&2; echo "Usage: zagon task show <task>" >&2; exit 64 ;; esac
                cat "$HOME/card.json" ;;
            "log plan") cat "$HOME/plan.json"; if [ -e "$HOME/jira-down" ]; then echo "jira: HTTP 401 reading /home/al/.zagon/jira-token" >&2; fi ;;
            "log commit") want=$(cat "$HOME/digest" 2>/dev/null)
                case "$*" in *"--expect "*) case "$* " in *"--expect $want "*) ;; *) echo "plan changed: nothing logged"; exit 3 ;; esac ;; esac
                echo "  #3 PROJ-12 10:00–11:00 1h planned  text with logged in it"
                if [ -e "$HOME/commit-fails" ]; then echo "Error: Jira: HTTP 500" >&2; exit 1; fi
                echo "  not logged #4 PROJ-12 11:00–12:00: overlaps a worklog now in Jira"; echo "1 worklogs logged, 1 not logged" ;;
            "task drafts") if [ -e "$HOME/old-drafts" ]; then echo "Error: Unexpected argument 'drafts'" >&2; exit 64; fi
                cat "$HOME/drafts.json" ;;
            "task jira-projects") if [ -e "$HOME/no-jira" ]; then echo "Error: Jira is not connected ([jira] in config.toml)" >&2; exit 1; fi
                echo '{"default":"PROJ","projects":[{"key":"OPS","name":"Operations"},{"key":"PROJ","name":"Project"}]}' ;;
            "task accept") case "$*" in
                *--create-in-jira*) if [ -e "$HOME/jira-fails" ]; then echo "Error: Jira: HTTP 400 summary too long" >&2; exit 1; fi
                    echo "Create in Jira: a Task in PROJ, assigned to you"; echo "N3 accepted: PROJ-99 Fix login · 2h 10m · created in Jira" ;;
                *) echo "N3 accepted: ZAG-5 Fix login · 2h 10m" ;; esac ;;
            "task reject") echo "N3 rejected" ;;
            esac
            """)
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: home) }

    func script(_ path: String, _ text: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    var calls: [String] {
        ((try? String(contentsOfFile: home + "/calls", encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func testListCardPlanEditsAndCommitOverSsh() throws {
        let p = try StoreDataProvider.fixture(StoreDataProviderTests.fixtures)
        let sample = try p.fixtureTasks()
        let day = TaskBackend.day(p.now.addingTimeInterval(-86400))
        for (file, args) in [("list", ["task", "list", "--all", "--json"]), ("card", ["task", "show", "--json", "--", "PROJ-12"]),
                             ("plan", ["log", "plan", "--json", "--", day])] {
            let r = try XCTUnwrap(try sample.run(args, 60))
            XCTAssertEqual(r.status, 0, String(decoding: r.err, as: UTF8.self))
            try r.out.write(to: URL(fileURLWithPath: home + "/\(file).json"))
        }
        let jiraOff = try sample.plan(day)
        XCTAssertEqual(jiraOff.digest, DayPlan.commitDigest(jiraOff.plan.rows), "today's zagon sends the digest of what it would write")
        XCTAssertEqual(jiraOff.worklog(Fmt(lang: .en, now: p.now)).jiraBlocked,
                       "Jira is not connected there ([jira] in config.toml): the plan stays in Zagon.")
        XCTAssertEqual(WorklogVM(jiraOff.worklog(Fmt(lang: .en, now: p.now)), Fmt(lang: .en, now: p.now)).stats[2].value, "—")
        // The server as if Jira were connected: 1 h of your worklogs there.
        var connected = jiraOff.plan
        connected.jiraSec = 3600
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        // As a zagon from before `--expect` answers: no commit_digest (that path is checked first).
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: try e.encode(connected)) as? [String: Any])
        old["commit_digest"] = nil
        try JSONSerialization.data(withJSONObject: old).write(to: URL(fileURLWithPath: home + "/plan.json"))
        let b = TaskBackend.server("build-box", controlDir: home, ssh: home + "/ssh")

        let list = try b.list().map(TaskBackend.item)
        XCTAssertEqual(list.map(\.key).sorted(), ["PROJ-12", "PROJ-14", "ZAG-1"])
        let main = try XCTUnwrap(list.first { $0.key == "PROJ-12" })
        XCTAssertEqual(main.state, .active)
        XCTAssertEqual(main.jiraKey, "PROJ-12")
        XCTAssertNil(list.first { $0.key == "ZAG-1" }?.jiraKey)
        // PROJ-14 is a session's title; the own task was done (and its note written) before the last 7 days.
        XCTAssertEqual(list.filter { !$0.worked }.map(\.key), ["ZAG-1"])
        XCTAssertEqual(calls.last, "task|list|--all|--json|")
        // A zagon from before `--all` gets the plain list.
        FileManager.default.createFile(atPath: home + "/old", contents: nil)
        XCTAssertEqual(try b.list().count, 3)
        XCTAssertEqual(calls.suffix(2), ["task|list|--all|--json|", "task|list|--json|"])
        try FileManager.default.removeItem(atPath: home + "/old")

        let c = try b.card("PROJ-12")
        XCTAssertFalse(c.sessions.isEmpty, "the sample's PROJ-12 branch links its sessions")
        let card = TaskBackend.item(c, sessions: p.taskSessions(c.sessions, source: b.source))
        XCTAssertEqual(card.todo.map(\.done), [true, false, false])
        XCTAssertEqual(card.notes, ["Staging webhook secret rotates on Mondays."])
        XCTAssertEqual(card.doneByDay.map(\.text), ["Found the retry path that skips the key check."])
        XCTAssertGreaterThan(card.userSec, 0)
        XCTAssertEqual(card.sessions.count, c.sessions.count)
        XCTAssertTrue(card.sessions.allSatisfy { $0.host == "laptop" && $0.sec > 0 }, "known sessions come from this Mac's store")
        let detail = try XCTUnwrap(TasksVM([card], filter: .active, Fmt(lang: .en, now: p.now)).detail("PROJ-12"))
        XCTAssertEqual(detail.jiraLines.map(\.text), ["Can't check PROJ-12 against Jira: Jira is not connected on the machine that keeps this task."])

        XCTAssertThrowsError(try b.card("NOPE")) { XCTAssertEqual("\($0)", "no task NOPE") }

        let plan = try b.plan(day)
        XCTAssertNil(plan.jiraError)
        let w = plan.worklog(Fmt(lang: .en, now: p.now))
        XCTAssertTrue(w.rows.contains { $0.key == "PROJ-12" && $0.destination == .jira }, "\(plan.plan.rows)")
        XCTAssertNil(w.jiraBlocked)
        let vm = WorklogVM(w, Fmt(lang: .en, now: p.now))
        XCTAssertEqual(vm.stats[2].value, "1h 00m")
        XCTAssertNotNil(vm.commitTitle)
        // The samples' worklog screen opens on "today" of the sample.
        let today = try XCTUnwrap(try sample.run(["log", "plan", "--json", "--", TaskBackend.day(p.now)], 60))
        XCTAssertTrue(String(decoding: today.out, as: UTF8.self).contains("\"jira_key\":\"PROJ-12\""))

        // Words with quotes, spaces and a leading dash reach the CLI as they are.
        try b.addTodo("PROJ-12", "it's -x \"q\" $HOME")
        try b.checkTodo("PROJ-12", number: 2, done: false)
        try b.addNote("PROJ-12", "-- a note")
        try b.setStatus("PROJ-12", .active)
        XCTAssertEqual(calls.suffix(4), ["task|todo|--|PROJ-12|it's -x \"q\" $HOME|", "task|todo|--uncheck|2|--|PROJ-12|",
                                         "task|note|--|PROJ-12|-- a note|", "task|status|--|PROJ-12|in_progress|"])

        guard case .written(let logged, let failed, let problems) = try b.commit(day, shown: plan) else { return XCTFail("not written") }
        XCTAssertEqual([logged, failed], [1, 1])
        XCTAssertEqual(problems, ["not logged #4 PROJ-12 11:00–12:00: overlaps a worklog now in Jira"])
        XCTAssertEqual(calls.last, "log|commit|--yes|--no-scan|--|\(day)|")
        // A failure before writing is not taken for a summary, even with "logged" in a row's text.
        _ = FileManager.default.createFile(atPath: home + "/commit-fails", contents: nil)
        XCTAssertThrowsError(try b.commit(day, shown: plan)) { XCTAssertEqual("\($0)", "Jira: HTTP 500") }
        try FileManager.default.removeItem(atPath: home + "/commit-fails")
        // Jira failed now or when the plan was made: the CLI is not asked to write.
        _ = FileManager.default.createFile(atPath: home + "/jira-down", contents: nil)
        let down = try b.plan(day)
        XCTAssertEqual(down.jiraError, "HTTP 401 reading ~/.zagon/jira-token")
        let blocked = WorklogVM(down.worklog(Fmt(lang: .en, now: p.now)), Fmt(lang: .en, now: p.now))
        XCTAssertNil(blocked.commitTitle)
        XCTAssertTrue(blocked.notes.contains("Jira did not answer, so the plan is made without it and cannot be logged: HTTP 401 reading ~/.zagon/jira-token"))
        XCTAssertFalse(blocked.notes.contains { $0.contains("Nothing overlaps") })
        XCTAssertThrowsError(try b.commit(day, shown: plan))
        XCTAssertThrowsError(try b.commit(day, shown: down))
        try FileManager.default.removeItem(atPath: home + "/jira-down")
        XCTAssertEqual(calls.filter { $0.hasPrefix("log|commit") }.count, 2)

        // The server planned again meanwhile: nothing is written, the new plan comes back.
        var moved = plan
        let i = try XCTUnwrap(moved.plan.rows.firstIndex { $0.state == "planned" && $0.jiraKey != nil })
        moved.plan.rows[i].end += 60
        guard case .changed(let fresh) = try b.commit(day, shown: moved) else { return XCTFail("written a stale plan") }
        XCTAssertEqual(TaskBackend.toJira(fresh.plan), TaskBackend.toJira(plan.plan))
        XCTAssertEqual(calls.filter { $0.hasPrefix("log|commit") }.count, 2)
        XCTAssertNil(plan.digest, "a zagon from before --expect")

        // A zagon with `--expect`: the shown plan's digest goes along, and the CLI itself refuses a changed plan.
        let line = try String(contentsOfFile: home + "/plan.json", encoding: .utf8)
        try ("{\"commit_digest\":\"d1\"," + line.dropFirst()).write(toFile: home + "/plan.json", atomically: true, encoding: .utf8)
        try "d1".write(toFile: home + "/digest", atomically: true, encoding: .utf8)
        let current = try b.plan(day)
        XCTAssertEqual(current.digest, "d1")
        guard case .written(let n, _, _) = try b.commit(day, shown: current) else { return XCTFail("not written") }
        XCTAssertEqual(n, 1)
        XCTAssertEqual(calls.last, "log|commit|--yes|--no-scan|--expect|d1|--|\(day)|")
        try "d2".write(toFile: home + "/digest", atomically: true, encoding: .utf8)
        guard case .changed = try b.commit(day, shown: current) else { return XCTFail("written a stale plan") }
        XCTAssertEqual(calls.suffix(2).first, "log|commit|--yes|--no-scan|--expect|d1|--|\(day)|")
        XCTAssertTrue(calls.last?.hasPrefix("log|plan") == true, "the new plan is fetched to show")
    }

    func testFailuresAreShortLines() throws {
        let gone = TaskBackend(source: .server("x")) { _, _ in nil }
        XCTAssertThrowsError(try gone.list()) { XCTAssertEqual("\($0)", "no answer in 120 s") }
        let old = TaskBackend(source: .server("x")) { _, _ in Proc.Result(status: 0, out: Data("{\"x\":1}\n".utf8), err: Data()) }
        XCTAssertThrowsError(try old.list()) { XCTAssertTrue("\($0)".contains("another version")) }
        let ssh = TaskBackend(source: .server("x")) { _, _ in
            Proc.Result(status: 255, out: Data(), err: Data("ssh: connect to host x port 22: Connection refused\n".utf8))
        }
        XCTAssertThrowsError(try ssh.list()) { XCTAssertEqual("\($0)", "ssh: connect to host x port 22: Connection refused") }
        let older = TaskBackend(source: .server("x")) { _, _ in
            Proc.Result(status: 64, out: Data(), err: Data("Error: Unknown option '--json'\nUsage: zagon task list\n".utf8))
        }
        XCTAssertThrowsError(try older.list()) {
            XCTAssertEqual("\($0)", "zagon there is older than this app, update it (Unknown option '--json')")
        }
    }

    func testSuggestedNewTasksOverSsh() throws {
        try """
            [{"confidence":0.8,"day":"2026-10-29","description":"It was: login failed.\\nDone: fixed the check.","done":"Fixed the login check",\
            "id":"N3","stretches":[{"end":1793267800,"project":"example-project","session_id":"claude:s1","session_title":"login bug",\
            "start":1793260000},{"end":1793270000,"session_id":"codex:s2","session_title":"login bug","start":1793269000},\
            {"end":1793271000,"session_id":"codex:s3","start":1793270500}],"title":"Fix login","worked_sec":7800}]
            """.write(toFile: home + "/drafts.json", atomically: true, encoding: .utf8)
        let b = TaskBackend.server("build-box", controlDir: home, ssh: home + "/ssh")

        let (drafts, jira) = try b.suggestions()
        XCTAssertEqual(drafts.map(\.id), ["N3"])
        XCTAssertEqual(drafts.first?.stretches.first?.sessionId, "claude:s1")
        XCTAssertEqual(jira, TaskBackend.JiraProjects(default: "PROJ", projects: [.init(key: "OPS", name: "Operations"),
                                                                                   .init(key: "PROJ", name: "Project")]))
        XCTAssertEqual(calls, ["task|drafts|--json|", "task|jira-projects|--json|"])
        let utc = TimeZone(identifier: "UTC")!
        let card = TaskBackend.draft(try XCTUnwrap(drafts.first), Fmt(lang: .en, timeZone: utc, now: Date()))
        XCTAssertEqual([card.title, card.meta, card.name, card.worked],
                       ["New task: Fix login · 2h 10m", "Thu, October 29 · login bug", "Fix login", "2h 10m"])
        XCTAssertEqual(card.description, "It was: login failed.\nDone: fixed the check.")
        XCTAssertEqual(TaskBackend.draft(try XCTUnwrap(drafts.first), Fmt(lang: .ru, timeZone: utc, now: Date())).title,
                       "Новая задача: Fix login · 2 ч 10 м")

        // Texts with a leading dash stay values; only the Jira create says --yes.
        XCTAssertEqual(try b.accept("N3"), "N3 accepted: ZAG-5 Fix login · 2h 10m")
        XCTAssertEqual(try b.accept("N3", title: "-x \"q\" $HOME", description: "--what"), "N3 accepted: ZAG-5 Fix login · 2h 10m")
        XCTAssertEqual(try b.reject("N3"), "N3 rejected")
        XCTAssertEqual(try b.createInJira("N3", project: "PROJ", title: "-Fix login", description: "It was: a=b"),
                       "N3 accepted: PROJ-99 Fix login · 2h 10m · created in Jira")
        XCTAssertEqual(calls.suffix(4), ["task|accept|--|N3|", "task|accept|--title=-x \"q\" $HOME|--description=--what|--|N3|",
                                         "task|reject|--|N3|",
                                         "task|accept|--create-in-jira|--project=PROJ|--title=-Fix login|--description=It was: a=b|--yes|--|N3|"])
        XCTAssertEqual(calls.filter { $0.contains("--yes") }.count, 1)
        FileManager.default.createFile(atPath: home + "/jira-fails", contents: nil)
        XCTAssertThrowsError(try b.createInJira("N3", project: "PROJ", title: "t", description: "d")) {
            XCTAssertEqual("\($0)", "Jira: HTTP 400 summary too long")
        }

        // Jira not connected there: suggestions without the Jira button; none at all: Jira is not asked.
        FileManager.default.createFile(atPath: home + "/no-jira", contents: nil)
        XCTAssertNil(try b.suggestions().jira)
        try "[]".write(toFile: home + "/drafts.json", atomically: true, encoding: .utf8)
        let before = calls.count
        XCTAssertTrue(try b.suggestions().drafts.isEmpty)
        XCTAssertEqual(calls.count, before + 1)
        // A zagon from before 0.1.1: no suggestions, no error.
        FileManager.default.createFile(atPath: home + "/old-drafts", contents: nil)
        XCTAssertTrue(try b.drafts().isEmpty)
    }
}
