import Foundation
import Testing
@testable import ZagonCore

@Suite struct ExportTests {
    func lines(_ s: Store, since: Int, version: String? = nil) throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        try Export.run(store: s, since: since, version: version) { out.append(try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]) }
        return out
    }

    @Test func exportsOnlyWhatChanged() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // 2025-10-30 12:00 UTC and the next day.
        try "s1 1761825600 100 10\n".write(toFile: dir + "/a.jsonl", atomically: false, encoding: .utf8)
        let store = try Store(path: ":memory:")
        var o = IngestOptions(); o.host = "h"
        let ingest = Ingest(store: store, sources: [deltaSpec(dir)], options: o)
        try ingest.scan()
        try store.addLimitSnapshot(LimitSnapshot(tool: .codex, window: "primary", usedPct: 12, ts: 1761825600))

        let all = try lines(store, since: 0)
        #expect(all.first?["type"] as? String == "export")
        #expect(all.first?["version"] == nil)
        #expect(try lines(store, since: 0, version: "0.1.0").first?["version"] as? String == "0.1.0")
        let seq1 = all.first?["seq"] as? Int ?? -1
        #expect(seq1 > 0)
        #expect(all.filter { $0["type"] as? String == "session" }.map { $0["id"] as? String } == ["codex:s1"])
        let days = all.filter { $0["type"] as? String == "day" }
        #expect(days.count == 1)
        let rows = days.first?["rows"] as? [[String: Any]] ?? []
        #expect(rows.contains { $0["model"] as? String == "m" && $0["input"] as? Int == 100 && $0["output"] as? Int == 10 })
        #expect(all.filter { $0["type"] as? String == "limit" }.count == 1)

        // Nothing new: header and limits only.
        #expect(try lines(store, since: seq1).map { $0["type"] as! String } == ["export", "limit"])

        // A new record on the next day: that day (complete rows) and the session, not the old day.
        let h = FileHandle(forWritingAtPath: dir + "/a.jsonl")!
        h.seekToEndOfFile(); h.write("s1 1761912000 5 1\n".data(using: .utf8)!); h.closeFile()
        try ingest.scan()
        let next = try lines(store, since: seq1)
        #expect(next.filter { $0["type"] as? String == "day" }.map { $0["day"] as? String } == [Time.dayString(1761912000)])
        #expect(next.filter { $0["type"] as? String == "session" }.count == 1)
        #expect((next.first?["seq"] as? Int ?? 0) > seq1)
    }

    @Test func updateIngestsOnlyPathsOfItsSources() throws {
        let dir = tempDir(), other = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir); try? FileManager.default.removeItem(atPath: other) }
        try "s1 1761825600 100 10\n".write(toFile: dir + "/a.jsonl", atomically: false, encoding: .utf8)
        try "s2 1761825600 7 7\n".write(toFile: other + "/b.jsonl", atomically: false, encoding: .utf8)
        try "s3 1761825600 9 9\n".write(toFile: dir + "/c.txt", atomically: false, encoding: .utf8)
        let store = try Store(path: ":memory:")
        let ingest = Ingest(store: store, sources: [deltaSpec(dir)])
        let s = try ingest.update(paths: [dir + "/a.jsonl", other + "/b.jsonl", dir + "/c.txt", dir + "/missing.jsonl"])
        #expect(try totals(store) == (100, 10, 1))
        #expect(try store.db.one("SELECT count(*) FROM day_agg") { $0.int(0) }! > 0)  // derived tables refreshed
        #expect(s.lines == 1 && s.usageRecords == 1)
        // The stats are those of each update (the daemon adds them up for its health line).
        let h = FileHandle(forWritingAtPath: dir + "/a.jsonl")!
        h.seekToEndOfFile(); h.write("s1 1761825601 1 1\ns1 1761825602 1 1\n".data(using: .utf8)!); h.closeFile()
        let next = try ingest.update(paths: [dir + "/a.jsonl"])
        #expect(next.lines == 2 && next.usageRecords == 2 && next.filesRead == 1)
    }

    @Test func dayEmptiedByARetractionIsExported() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "s1 1761825600 100 10\n".write(toFile: dir + "/a.jsonl", atomically: false, encoding: .utf8)
        let store = try Store(path: ":memory:")
        let ingest = Ingest(store: store, sources: [deltaSpec(dir)])
        try ingest.scan()
        let seq = try lines(store, since: 0).first?["seq"] as? Int ?? -1
        try "".write(toFile: dir + "/a.jsonl", atomically: false, encoding: .utf8)  // truncated: contribution retracted
        try ingest.scan()
        let days = try lines(store, since: seq).filter { $0["type"] as? String == "day" }
        #expect(days.count == 1)
        let rows = days.first?["rows"] as? [[String: Any]] ?? []
        #expect(rows.count == 1 && rows.first?["model"] as? String == "" && rows.first?["requests"] as? Int == 0)
    }
}
