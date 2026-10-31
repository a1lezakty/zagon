import Foundation
import Testing
@testable import ZagonCore

@Suite struct DaemonTests {
    @Test func logRotatesIntoThreeFilesOfBoundedSize() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let log = LogFile(path: dir + "/logs/daemon.log", maxBytes: 1000, keep: 3)
        for i in 0..<200 { log.write("line \(i) " + String(repeating: "x", count: 40)) }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir + "/logs").sorted()
        #expect(names == ["daemon.log", "daemon.log.1", "daemon.log.2"])
        for n in names { #expect((Sys.fileSize(dir + "/logs/" + n) ?? 0) <= 1000) }
        #expect(LogFile.tail(dir + "/logs/daemon.log", lines: 1).first?.hasSuffix("line 199 " + String(repeating: "x", count: 40)) == true)
        // The oldest kept lines are newer than everything that was dropped.
        let oldest = LogFile.tail(dir + "/logs/daemon.log.2", lines: 100).first ?? ""
        #expect(!oldest.contains("line 0 "))
    }

    @Test func healthLineHasTheNumbers() throws {
        let store = try Store(path: ":memory:")
        var h = Health(store: store)
        let line = h.line(watched: 7, batches: 3, files: 5, errors: 1, fullPasses: 0)
        #expect(line.hasPrefix("health: rss "))
        for part in ["watched 7 dirs", "batches 3", "files 5", "errors 1", "full passes 0", " db ", "cpu "] { #expect(line.contains(part)) }
    }

    @Test func permissionWaitKeepsTheToolName() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = try Store(path: ":memory:")
        let day = Sys.utcDay(Sys.now())
        func hook(_ event: String, _ ts: Double, tool: String? = nil) throws {
            let extra = tool.map { ",\"tool_name\":\"\($0)\"" } ?? ""
            let line = "{\"kind\":\"hook\",\"tool\":\"claude\",\"event\":\"\(event)\",\"session_id\":\"s1\",\"ts\":\(ts)\(extra)}\n"
            let h = FileHandle(forWritingAtPath: dir + "/\(day).ndjson") ?? {
                _ = FileManager.default.createFile(atPath: dir + "/\(day).ndjson", contents: nil); return FileHandle(forWritingAtPath: dir + "/\(day).ndjson")!
            }()
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
            try SpoolIngest.run(store: store, spoolDir: dir)
        }
        func status() throws -> [String?] {
            try store.db.one("SELECT status, status_detail FROM session WHERE id='claude:s1'") { [$0.text(0), $0.text(1)] } ?? []
        }
        let t = Sys.now()
        try hook("PermissionRequest", t, tool: "Bash")
        #expect(try status() == ["waiting_permission", "Bash"])
        try hook("PostToolUse", t + 5, tool: "Bash")
        #expect(try status() == ["working", nil])
    }

    @Test func statusLineSpoolsAReadingOnlyWhenItChangesOrOncePerMinute() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let paths = ZagonPaths(home: dir, dir: dir)
        func input(_ pct: Int, session: String = "s1") -> [UInt8] {
            Array(#"{"session_id":"\#(session)","rate_limits":{"five_hour":{"used_percentage":\#(pct),"resets_at":1761900000}}}"#.utf8)
        }
        let t = 1_761_800_000.0
        #expect(StatusLine.shouldSpool(input(62), ts: t, paths: paths))
        #expect(!StatusLine.shouldSpool(input(62), ts: t + 5, paths: paths))     // redrawn, same values
        #expect(StatusLine.shouldSpool(input(63), ts: t + 10, paths: paths))     // changed
        #expect(!StatusLine.shouldSpool(input(63), ts: t + 50, paths: paths))
        #expect(StatusLine.shouldSpool(input(63), ts: t + 71, paths: paths))     // a minute later: refreshed
        #expect(StatusLine.shouldSpool(input(63, session: "s2"), ts: t + 72, paths: paths))  // per session
        #expect(!StatusLine.shouldSpool(Array("{}".utf8), ts: t + 73, paths: paths))        // no reading at all
        // Old state files go with old spool days.
        let store = try Store(path: ":memory:")
        try SpoolIngest.run(store: store, spoolDir: paths.spool, retainDays: 7, now: Sys.now() + 8 * 86400)
        #expect(Sys.listDir(paths.spool).filter { $0.hasPrefix(".limits-") }.isEmpty)
    }
}
