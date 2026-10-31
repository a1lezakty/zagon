import Foundation
import XCTest
import ZagonCore
@testable import ZagonUIModel

/// Jira settings of this Mac: config.toml and the token file under a temporary HOME.
final class JiraSettingsTests: XCTestCase {
    var home = ""
    var oldHome: String?

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("zagon-jira-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        oldHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", home, 1)
    }

    override func tearDownWithError() throws {
        if let oldHome { setenv("HOME", oldHome, 1) }
        try? FileManager.default.removeItem(atPath: home)
    }

    func mode(_ path: String) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func text(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }

    func testSaveKeepsTheRestAndTheTokenIsPrivate() throws {
        let config = NotifySettings.configPath, token = JiraSettings.tokenPath
        XCTAssertEqual(config, home + "/.zagon/config.toml")
        XCTAssertEqual(token, home + "/.zagon/jira-token")
        XCTAssertNil(JiraSettings.load(config))
        try FileManager.default.createDirectory(atPath: home + "/.zagon", withIntermediateDirectories: true)
        try "# mine\n[notify]\nlimit_reset = false\n\n[jira]\nreview_statuses = [\"qa\"]\n".write(toFile: config, atomically: true, encoding: .utf8)
        // A token file left 0644 by hand becomes 0600 with the new token.
        try "old\n".write(toFile: token, atomically: false, encoding: .utf8)
        chmod(token, 0o644)

        try JiraSettings.save(url: "https://example.atlassian.net", email: "me@example.com", token: "tok-1", saved: nil,
                              configPath: config, tokenPath: token)
        XCTAssertEqual(try text(token), "tok-1\n")
        XCTAssertEqual(try mode(token), 0o600)
        XCTAssertEqual(try text(config), """
            # mine
            [notify]
            limit_reset = false

            [jira]
            url = "https://example.atlassian.net"
            email = "me@example.com"
            token_file = "\(token)"
            review_statuses = ["qa"]

            """)
        let c = try XCTUnwrap(JiraSettings.load(config))
        XCTAssertEqual(c, JiraSettings(url: "https://example.atlassian.net", email: "me@example.com", tokenFile: token))
        XCTAssertEqual(c.browse("PROJ-1")?.absoluteString, "https://example.atlassian.net/browse/PROJ-1")
        // The core reads what was written.
        let core = try XCTUnwrap(JiraConfig.load(configText: try text(config)))
        XCTAssertEqual(core.reviewStatuses, ["qa"])
        XCTAssertNoThrow(try JiraClient(core))

        // An empty token keeps the saved file, even one kept elsewhere by hand.
        let own = home + "/my-token"
        try "tok-2\n".write(toFile: own, atomically: false, encoding: .utf8)
        try JiraSettings.save(url: "https://other.example.com/jira", email: "me@example.com", token: "",
                              saved: JiraSettings(url: c.url, email: c.email, tokenFile: own), configPath: config, tokenPath: token)
        XCTAssertEqual(JiraSettings.load(config)?.tokenFile, own)
        XCTAssertEqual(JiraSettings.load(config)?.url, "https://other.example.com/jira")
        XCTAssertEqual(try text(token), "tok-1\n")

        try JiraSettings.disconnect(configPath: config, tokenPath: token)
        XCTAssertNil(JiraSettings.load(config))
        XCTAssertFalse(FileManager.default.fileExists(atPath: token))
        XCTAssertEqual(try text(config), "# mine\n[notify]\nlimit_reset = false\n\n[jira]\nreview_statuses = [\"qa\"]\n")
        try JiraSettings.disconnect(configPath: config, tokenPath: token)  // again: nothing to do
    }

    /// A new config.toml and token file are both 0600, the folder 0700.
    func testNewFiles() throws {
        let config = NotifySettings.configPath, token = JiraSettings.tokenPath
        try JiraSettings.save(url: "https://example.atlassian.net", email: "me@example.com", token: "tok-1", saved: nil,
                              configPath: config, tokenPath: token)
        XCTAssertEqual(try mode(config), 0o600)
        XCTAssertEqual(try mode(token), 0o600)
        XCTAssertEqual(try mode(home + "/.zagon"), 0o700)
        XCTAssertFalse(FileManager.default.fileExists(atPath: token + ".zagon-tmp"))
    }

    /// Set but not working: no token to read. A config.toml that cannot be edited leaves the old token as it was.
    func testNotReadyAndNoHalfSave() throws {
        let config = NotifySettings.configPath, token = JiraSettings.tokenPath
        try JiraSettings.save(url: "https://example.atlassian.net", email: "me@example.com", token: "tok-1", saved: nil,
                              configPath: config, tokenPath: token)
        XCTAssertEqual(JiraSettings.load(config)?.ready, true)
        try FileManager.default.removeItem(atPath: token)
        XCTAssertEqual(JiraSettings.load(config)?.ready, false)
        try "tok-1\n".write(toFile: token, atomically: false, encoding: .utf8)
        try FileManager.default.removeItem(atPath: config)
        try Data([0x5B, 0xFF, 0x5D, 0x0A]).write(to: URL(fileURLWithPath: config))  // not UTF-8
        XCTAssertThrowsError(try JiraSettings.save(url: "https://example.atlassian.net", email: "other@example.com", token: "tok-2",
                                                   saved: nil, configPath: config, tokenPath: token))
        XCTAssertEqual(try text(token), "tok-1\n")
    }

    /// Whether the source has the AI engine's CLI: asked over two days (the CLI takes --from only before --to), also
    /// on the day clocks go back.
    func testMissingEngine() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let now = Date(timeIntervalSince1970: 1_792_929_600)  // 2026-10-25 12:00 UTC, the end of summer time there
        let b = TaskBackend(source: .local) { args, _ in
            guard let f = args.firstIndex(of: "--from"), let t = args.firstIndex(of: "--to"), args[f + 1] < args[t + 1] else {
                return Proc.Result(status: 64, out: Data(), err: Data("Error: --from must be before --to\n".utf8))
            }
            XCTAssertEqual([args[f + 1], args[t + 1]], ["2026-10-24", "2026-10-25"])
            return Proc.Result(status: 0, out: Data(#"{"key":"k","from":"2026-10-24","to":"2026-10-25","worked":[],"missing":[],"calls":0,"no_cli":"claude"}"#.utf8),
                               err: Data())
        }
        XCTAssertEqual(b.missingEngine(now: now, zone: zone), "claude")
        XCTAssertNil(TaskBackend(source: .local) { _, _ in nil }.missingEngine(now: now, zone: zone))
    }

    func testProblems() {
        func p(_ url: String, _ email: String = "me@example.com", token: String = "t", saved: Bool = false) -> String? {
            JiraSettings.problem(url: url, email: email, token: token, saved: saved)
        }
        XCTAssertNil(p("https://example.atlassian.net"))
        XCTAssertNil(p("HTTPS://example.atlassian.net"))
        XCTAssertEqual(p("http://example.atlassian.net"), "settings.jira.bad.url")
        XCTAssertEqual(p("http://localhost:8080"), "settings.jira.bad.url")  // the core's local mock exception is not offered
        XCTAssertEqual(p("example.atlassian.net"), "settings.jira.bad.url")
        XCTAssertEqual(p("https://"), "settings.jira.bad.url")
        XCTAssertEqual(p("https://a b"), "settings.jira.bad.url")
        XCTAssertEqual(p("https://x.net", ""), "settings.jira.bad.email")
        XCTAssertEqual(p("https://x.net", token: ""), "settings.jira.bad.token")
        XCTAssertNil(p("https://x.net", token: "", saved: true))
        XCTAssertEqual(p("https://x.net", token: "a\nb"), "settings.jira.bad.token")
        XCTAssertEqual(p("https://x.net", token: String(repeating: "t", count: 513)), "settings.jira.bad.token")
    }

    /// The check reaches Jira with the typed token (through the pipe) or the saved one; a refusal reads as such.
    func testCheck() throws {
        let curl = home + "/curl"
        // Answers like Jira's /myself when curl's config on stdin carries the expected login.
        try """
            #!/bin/sh
            cfg=$(cat)
            case "$cfg" in *'user = "me@example.com:tok-1"'*) printf '{"accountId":"a1"}\\n200' ;; *) printf '{}\\n401' ;; esac

            """.write(toFile: curl, atomically: false, encoding: .utf8)
        chmod(curl, 0o755)
        let url = "https://example.atlassian.net"
        XCTAssertNoThrow(try JiraSettings.check(url: url, email: "me@example.com", token: "tok-1", saved: nil, curl: curl))
        XCTAssertThrowsError(try JiraSettings.check(url: url, email: "me@example.com", token: "tok-2", saved: nil, curl: curl)) {
            XCTAssertEqual(JiraSettings.why($0, Fmt(lang: .en, now: Date())), "Jira did not accept the email or token (HTTP 401).")
        }
        let saved = home + "/saved-token"
        try "tok-1\n".write(toFile: saved, atomically: false, encoding: .utf8)
        XCTAssertNoThrow(try JiraSettings.check(url: url, email: "me@example.com", token: "",
                                                saved: JiraSettings(url: url, email: "x", tokenFile: saved), curl: curl))
        // No saved token and none typed: the client cannot start.
        XCTAssertThrowsError(try JiraSettings.check(url: url, email: "me@example.com", token: "", saved: nil, curl: curl))
    }

    /// A server's Jira by what its `task jira-projects` answers.
    func testServer() {
        func answer(_ status: Int32, _ out: String, _ err: String = "") -> JiraSettings.Server {
            JiraSettings.server(TaskBackend(source: .server("build-box")) { _, _ in
                Proc.Result(status: status, out: Data(out.utf8), err: Data(err.utf8))
            })
        }
        XCTAssertEqual(answer(0, "{\"default\":null,\"projects\":[{\"key\":\"PROJ\",\"name\":\"Project\"}]}\n"), .on)
        XCTAssertEqual(answer(1, "", "Error: Jira is not connected ([jira] in config.toml)\n"), .off)
        XCTAssertEqual(answer(1, "", "Error: jira HTTP 503: down\n"), .failed("jira HTTP 503: down"))
        XCTAssertEqual(JiraSettings.server(TaskBackend(source: .server("x")) { _, _ in nil }), .failed("no answer in 120 s"))
    }
}
