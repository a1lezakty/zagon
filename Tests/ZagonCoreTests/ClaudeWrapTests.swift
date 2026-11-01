import Foundation
import Testing
@testable import ZagonCore

/// `zagon claude-wrap`, which the Claude Code of an editor panel runs through. Event values are made up.
@Suite struct ClaudeWrapTests {
    static let event = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.4237,"resetsAt":1793000000,"status":"allowed"},"seven_day":{"utilization":0.12,"resetsAt":1793500000}}},"uuid":"u-1","session_id":"s-1"}"#

    @Test func eventBecomesAStatusLineReading() throws {
        let input = try #require(ClaudeWrap.statusInput(Array(Self.event.utf8)))
        let l = try #require(StatusLine.limitsLine(input, ts: 2))
        #expect(l.line == #"{"kind":"limits","tool":"claude","ts":2.000,"session_id":"s-1","five_hour_pct":42.4,"five_hour_resets_at":1793000000,"seven_day_pct":12.0,"seven_day_resets_at":1793500000}"#)
        #expect(l.text == "5h 42% · wk 12%")
        let over = #"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":1.7}}}}"#
        let capped = try #require(ClaudeWrap.statusInput(Array(over.utf8)))
        #expect(StatusLine.limitsLine(capped, ts: 2)?.line.contains(#""five_hour_pct":100.0}"#) == true)
        for bad in [#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#,
                    #"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":"x"}}}}"#,
                    #"{"type":"assistant","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.5}}}}"#, "garbage"] {
            #expect(ClaudeWrap.statusInput(Array(bad.utf8)) == nil)
        }
    }

    @Test func onlyStreamJSONRunsAsAChild() {
        #expect(ClaudeWrap.isStream(["/c", "--output-format", "stream-json", "--verbose"]))
        #expect(ClaudeWrap.isStream(["/c", "--output-format=stream-json"]))
        #expect(!ClaudeWrap.isStream(["/c", "--output-format", "json"]))
        #expect(!ClaudeWrap.isStream(["/c", "auth", "status", "--output-format"]))
    }

    /// Starts `zagon claude-wrap <args>` with HOME and ZAGON_DIR in `dir`.
    func wrap(_ args: [String], dir: String) throws -> Child {
        try Child([zagonBin, "claude-wrap"] + args, env: ["HOME": dir, "ZAGON_DIR": dir, "PATH": "/usr/bin:/bin"], stdout: true)
    }

    func limits(_ dir: String) -> [String] { spoolLines(dir).filter { $0.contains(#""kind":"limits""#) } }

    @Test(.enabled(if: Sys.exists(zagonBin))) func streamIsCopiedByteForByteAndLimitsAreSpooled() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var data = Array((Self.event + "\n" + #"{"type":"system","subtype":"init","session_id":"s-1"}"# + "\n").utf8)
        data += Array(#"{"type":"assistant","text":""#.utf8) + [UInt8](repeating: 0x78, count: 300_000) + Array("\"}\n".utf8)
        data += Array((Self.event + "\n{\"type\":\"result\",\"text\":\"ю — ok\"}\n{\"type\":\"partial\"").utf8)
        Sys.writeFile(dir + "/stream", data)
        writeScript(dir + "/claude", "#!/bin/sh\ncat \"$HOME/stream\"\nexit 7\n")
        let p = try wrap([dir + "/claude", "--output-format", "stream-json", "--verbose", "--input-format", "stream-json"], dir: dir)
        let got = try p.readOutput()
        #expect(try p.wait() == 7)
        #expect(got == data)
        #expect(limits(dir).count == 1)  // the same reading twice is spooled once
        #expect(limits(dir).first?.contains(#""five_hour_pct":42.4,"five_hour_resets_at":1793000000"#) == true)
    }

    /// `$$` of `sh -c` is the pid of the process started: zagon itself when it execs.
    @Test(.enabled(if: Sys.exists(zagonBin))) func otherRunsAreExecdAndRecordNothing() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let p = try wrap(["/bin/sh", "-c", "echo $$; echo '\(Self.event)'"], dir: dir)
        let got = String(decoding: try p.readOutput(), as: UTF8.self)
        try p.wait()
        #expect(got.hasPrefix("\(p.pid)\n"))
        #expect(limits(dir).isEmpty)
        let q = try wrap(["/bin/sh", "-c", "echo $$", "sh", "--output-format", "stream-json"], dir: dir)
        let pid = String(decoding: try q.readOutput(), as: UTF8.self)
        #expect(try q.wait() == 0)
        #expect(!pid.isEmpty && pid != "\(q.pid)\n")
    }

    @Test(.enabled(if: Sys.exists(zagonBin))) func sigtermReachesClaudeAndTheWrapperDiesOfIt() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        writeScript(dir + "/claude", """
            #!/bin/sh
            trap 'echo term > "$HOME/mark"; trap - TERM; kill -TERM $$' TERM
            echo $$
            while :; do sleep 0.1; done

            """)
        let p = try wrap([dir + "/claude", "--output-format", "stream-json"], dir: dir)
        let child = Int32(String(decoding: try p.readOutput(line: true), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        p.send(SIGTERM)
        #expect(try p.wait() == 128 + SIGTERM)
        #expect(Sys.readFile(dir + "/mark") == Array("term\n".utf8))
        #expect(child.map { kill($0, 0) != 0 } == true)
    }

    @Test(.enabled(if: Sys.exists(zagonBin))) func aProcessLeftBehindDoesNotHoldTheWrapper() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        writeScript(dir + "/claude", "#!/bin/sh\nsleep 30 &\necho $!\nexit 3\n")
        // Not Process: Foundation learns of an exit through a socket every descendant inherits, the sleep too.
        let start = Sys.now()
        let r = Sys.capture([zagonBin, "claude-wrap", dir + "/claude", "--output-format", "stream-json"], timeout: 20,
                            env: ["HOME": dir, "ZAGON_DIR": dir])
        if let sleeper = Int32(String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(sleeper, SIGKILL)
        }
        #expect(r.status == 3 && Sys.now() - start < 10)
    }

    /// The script in the editor setting: through zagon when it knows claude-wrap; Claude Code directly when zagon is
    /// gone, older (a rollback: `/bin/false` stands for it) or uninstalled.
    @Test func scriptRunsClaudeDirectlyWithoutZagon() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let args = ["/bin/echo", "hi", "--output-format", "stream-json"]
        for zagon in [dir + "/gone/zagon", "/bin/false", nil] + (Sys.exists(zagonBin) ? [zagonBin] : []) {
            writeScript(dir + "/claude-wrap", Installer.wrapScriptText(zagon: zagon))
            let r = Sys.capture(["/bin/sh", dir + "/claude-wrap"] + args, env: ["HOME": dir, "ZAGON_DIR": dir])
            #expect(r.status == 0 && String(decoding: r.out, as: UTF8.self) == "hi --output-format stream-json\n")
        }
    }

    /// A data directory other than ~/.zagon reaches the wrapper through the script, not the editor's environment.
    @Test(.enabled(if: Sys.exists(zagonBin))) func scriptCarriesTheDataDirectory() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        writeScript(dir + "/claude", "#!/bin/sh\necho '\(Self.event)'\n")
        writeScript(dir + "/claude-wrap", Installer.wrapScriptText(zagon: zagonBin, dataDir: dir + "/data"))
        let r = Sys.capture(["/usr/bin/env", "-u", "ZAGON_DIR", "/bin/sh", dir + "/claude-wrap", dir + "/claude",
                             "--output-format", "stream-json"], env: ["HOME": dir])
        #expect(r.status == 0 && limits(dir + "/data").count == 1 && limits(dir).isEmpty)
    }

    @Test(.enabled(if: Sys.exists(zagonBin))) func failuresAndMissingBinary() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Nothing to spawn: the exec fallback fails too, with a word on stderr.
        let gone = Sys.capture([zagonBin, "claude-wrap", dir + "/missing", "--output-format", "stream-json"], env: ["ZAGON_DIR": dir])
        #expect(gone.status == 127 && String(decoding: gone.err, as: UTF8.self).contains("cannot run \(dir)/missing"))
        // No bundled binary: the extension passes the arguments alone, claude comes from PATH.
        writeScript(dir + "/claude", "#!/bin/sh\necho \"$@\"\n")
        let path = Sys.capture([zagonBin, "claude-wrap", "--version"], env: ["ZAGON_DIR": dir, "PATH": dir + ":/usr/bin:/bin"])
        #expect(path.status == 0 && String(decoding: path.out, as: UTF8.self) == "--version\n")
        #expect(Sys.capture([zagonBin, "claude-wrap", "--probe"]).status == 0)
    }

    /// The editor closes the stream: Claude's writes fail as without the wrapper (this one exits then), the wrapper ends.
    @Test(.enabled(if: Sys.exists(zagonBin))) func aClosedStdoutStopsClaude() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        writeScript(dir + "/claude", "#!/bin/sh\nwhile echo '{\"type\":\"x\"}'; do :; done\n")
        let start = Sys.now()
        let r = Sys.capture(["/bin/sh", "-c", "\"$0\" claude-wrap \"$1\" --output-format stream-json | head -c 10 >/dev/null; echo done",
                             zagonBin, dir + "/claude"], timeout: 20, env: ["ZAGON_DIR": dir])
        #expect(r.status == 0 && String(decoding: r.out, as: UTF8.self) == "done\n" && Sys.now() - start < 10)
    }
}
