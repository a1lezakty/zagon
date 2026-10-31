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
    func wrap(_ args: [String], dir: String) throws -> (Process, FileHandle) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: zagonBin)
        p.arguments = ["claude-wrap"] + args
        p.environment = ["HOME": dir, "ZAGON_DIR": dir, "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        p.standardOutput = out; p.standardInput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        return (p, out.fileHandleForReading)
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
        let (p, out) = try wrap([dir + "/claude", "--output-format", "stream-json", "--verbose", "--input-format", "stream-json"], dir: dir)
        let got = out.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(Array(got) == data)
        #expect(p.terminationReason == .exit && p.terminationStatus == 7)
        #expect(limits(dir).count == 1)  // the same reading twice is spooled once
        #expect(limits(dir).first?.contains(#""five_hour_pct":42.4,"five_hour_resets_at":1793000000"#) == true)
    }

    /// `$$` of `sh -c` is the pid of the process started: zagon itself when it execs.
    @Test(.enabled(if: Sys.exists(zagonBin))) func otherRunsAreExecdAndRecordNothing() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let (p, out) = try wrap(["/bin/sh", "-c", "echo $$; echo '\(Self.event)'"], dir: dir)
        let got = String(decoding: out.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(got.hasPrefix("\(p.processIdentifier)\n"))
        #expect(limits(dir).isEmpty)
        let (q, out2) = try wrap(["/bin/sh", "-c", "echo $$", "sh", "--output-format", "stream-json"], dir: dir)
        let pid = String(decoding: out2.readDataToEndOfFile(), as: UTF8.self)
        q.waitUntilExit()
        #expect(!pid.isEmpty && pid != "\(q.processIdentifier)\n" && q.terminationStatus == 0)
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
        let (p, out) = try wrap([dir + "/claude", "--output-format", "stream-json"], dir: dir)
        let child = Int32(String(decoding: out.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        p.terminate()
        p.waitUntilExit()
        #expect(p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGTERM)
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

    /// The script in the editor setting: through zagon when it is there, Claude Code directly when it is gone.
    @Test func scriptRunsClaudeDirectlyWithoutZagon() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let args = ["/bin/echo", "hi", "--output-format", "stream-json"]
        for zagon in [dir + "/gone/zagon"] + (Sys.exists(zagonBin) ? [zagonBin] : []) {
            writeScript(dir + "/claude-wrap", Installer.wrapScriptText(zagon: zagon))
            let r = Sys.capture(["/bin/sh", dir + "/claude-wrap"] + args, env: ["HOME": dir, "ZAGON_DIR": dir])
            #expect(r.status == 0 && String(decoding: r.out, as: UTF8.self) == "hi --output-format stream-json\n")
        }
    }
}
