import Foundation
import XCTest
@testable import ZagonUIModel

/// The bundled CLI, played by a shell script that answers like `zagon`.
final class ConnectTests: XCTestCase {
    func fakeCLI(_ dir: String) throws -> String {
        let bin = dir + "/zagon"
        try """
        #!/bin/sh
        case "$1" in
          doctor) echo "ok       hooks in ~/.claude/settings.json"; echo "MISSING  MCP server in Claude Code"
                  echo "ok       codex: MCP skipped (no codex CLI on PATH)"; echo "daemon log:"; echo "  ok not a check"; exit 1 ;;
          install) [ "$2" = "--bin" ] && [ "$3" = "$0" ] || exit 64; echo "$PATH" > "$(dirname "$0")/path"; echo installed; exit 0 ;;
          uninstall) echo "Error: uninstall: cannot parse /Users/al/.claude/settings.json" >&2; exit 64 ;;
          editor-panels) [ "$2" = on ] && [ "$3" = "--bin" ] && [ "$4" = "$0" ] || exit 64; exit 0 ;;
        esac
        exit 64
        """.write(toFile: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin)
        return bin
    }

    func testRunsTheCLI() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zagon-cli-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let bin = try fakeCLI(dir)
        let path = Connect.path(loginShell: "/opt/homebrew/bin:/custom/bin:/usr/bin", home: "/Users/me")
        XCTAssertEqual(path, "/opt/homebrew/bin:/custom/bin:/usr/bin:/Users/me/.local/bin:/Users/me/.claude/local:/Users/me/.bun/bin:/usr/local/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(Connect.path(loginShell: nil, home: "/Users/me"),
                       "/Users/me/.local/bin:/Users/me/.claude/local:/Users/me/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")

        let status = try XCTUnwrap(Connect.doctor(bin, path: path))
        XCTAssertEqual(status, Connect.Status(ok: ["hooks in ~/.claude/settings.json"], missing: ["MCP server in Claude Code"],
                                              notes: ["codex: MCP skipped (no codex CLI on PATH)"]))
        XCTAssertTrue(Connect.parseDoctor("ok       claude: hooks\nok       codex: MCP skipped (no codex CLI on PATH)\n").connected)
        XCTAssertFalse(status.connected)
        XCTAssertFalse(status.mcpSkipped, "codex's skip is not Claude's tools")
        XCTAssertTrue(Connect.parseDoctor("ok       claude: MCP skipped (no claude CLI on PATH)\n").mcpSkipped)

        XCTAssertNil(Connect.change(bin, "install", path: path))
        XCTAssertEqual(try String(contentsOfFile: dir + "/path", encoding: .utf8), path + "\n")  // the CLI got the full PATH
        XCTAssertEqual(Connect.change(bin, "uninstall", path: path), "Error: uninstall: cannot parse ~/.claude/settings.json")
        XCTAssertNil(Connect.doctor(dir + "/missing", path: path))
        XCTAssertNil(Connect.change(bin, "editor-panels on", path: path))  // one word per argument
        XCTAssertEqual(Connect.change(bin, "editor-panels off", path: path), "exit 64")
        // A shell whose rc files print around the PATH.
        let noisy = dir + "/noisy-sh"
        try "#!/bin/sh\necho welcome\nPATH=/a:/b\nprintf 'motd'\neval \"$4\"\necho bye\n".write(toFile: noisy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: noisy)
        XCTAssertEqual(Connect.loginShellPath(shell: noisy), "/a:/b")
        #if os(macOS)
        // An rc file that leaves a job holding stdout: answered at once, not after the time limit. (Linux Foundation
        // sees a process exit only when its descendants let go as well, so this runs on the Mac CI only.)
        let started = Date()
        let held = dir + "/held-sh"
        try "#!/bin/sh\nsleep 30 &\nPATH=/c\neval \"$4\"\n".write(toFile: held, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: held)
        XCTAssertEqual(Connect.loginShellPath(shell: held), "/c")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        #endif
        // An interactive shell that never runs the command (exec tmux in .zshrc): the plain login shell answers.
        let execs = dir + "/exec-sh"
        try "#!/bin/sh\n[ \"$1\" = -i ] && exit 1\nPATH=/d\neval \"$3\"\n".write(toFile: execs, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execs)
        XCTAssertEqual(Connect.loginShellPath(shell: execs), "/d")
        XCTAssertTrue(Connect.temporaryLocation("/private/var/folders/x/AppTranslocation/1/d/Zagon.app"))
        XCTAssertTrue(Connect.temporaryLocation("/Volumes/Zagon/Zagon.app"))
        XCTAssertFalse(Connect.temporaryLocation("/Applications/Zagon.app"))
        XCTAssertFalse(Connect.temporaryLocation("/Volumes/SSD/Applications/Zagon.app"))
    }

    /// "Check the panel": never, started without a reading, both (today by time, another day by weekday).
    func testPanelCheck() {
        let f = Fmt(lang: .en, timeZone: TimeZone(identifier: "UTC")!, now: Date(timeIntervalSince1970: 1_793_000_000))
        let run = Date(timeIntervalSince1970: 1_792_990_000), reading = Date(timeIntervalSince1970: 1_792_600_000)
        XCTAssertEqual(EditorPanelsVM.panelCheck(run: nil, reading: reading, f), f.t("editors.notSeen"))
        XCTAssertEqual(EditorPanelsVM.panelCheck(run: run, reading: nil, f), f.t("editors.seenNoReading", "at 04:46"))
        XCTAssertEqual(EditorPanelsVM.panelCheck(run: run, reading: reading, f), f.t("editors.seen", "at 04:46", "Wed 16:26"))
        let old = Date(timeIntervalSince1970: 1_791_000_000)
        XCTAssertEqual(EditorPanelsVM.panelCheck(run: run, reading: old, f), f.t("editors.seen", "at 04:46", "Oct 3 04:00"))
    }
}
