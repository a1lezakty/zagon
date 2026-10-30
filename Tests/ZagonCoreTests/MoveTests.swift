import Foundation
import Testing
@testable import ZagonCore

/// Per-request deltas without ids (like Codex `last_token_usage`): a recount after a move would double them.
/// Line format: `<session> <unix ts> <input> <output>`.
struct DeltaParser: LineParser {
    mutating func parse(line: UnsafeRawBufferPointer, into out: inout ParseOutput) {
        let f = String(decoding: line, as: UTF8.self).split(separator: " ")
        guard f.count == 4, let ts = Double(f[1]), let i = Int(f[2]), let o = Int(f[3]) else { out.badLines += 1; return }
        out.usage.append(UsageRecord(sessionId: "codex:" + f[0], ts: ts, model: "m", input: i, output: o))
        out.events.append(ActivityEvent(sessionId: "codex:" + f[0], ts: ts))
    }
    func saveState() -> String? { nil }
}

func deltaSpec(_ root: String) -> SourceSpec {
    SourceSpec(tool: .codex, root: root, accepts: { $0.hasSuffix(".jsonl") }, makeParser: { _, _, _ in DeltaParser() })
}

func tempDir() -> String {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("zagon-test-\(UUID().uuidString)").path
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

func totals(_ s: Store) throws -> (input: Int, output: Int, requests: Int) {
    try s.db.one("SELECT coalesce(sum(input),0), coalesce(sum(output),0), coalesce(sum(requests),0) FROM usage_hour") {
        ($0.int(0), $0.int(1), $0.int(2))
    }!
}

@Suite struct MoveTests {
    @Test func movedFileKeepsItsContribution() throws {
        let dir = tempDir(), live = dir + "/sessions", archived = dir + "/archived_sessions"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: live, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: archived, withIntermediateDirectories: true)
        try "s1 1761800000 100 10\ns1 1761800060 200 20\n".write(toFile: live + "/r.jsonl", atomically: false, encoding: .utf8)

        let store = try Store(path: ":memory:")
        let ingest = Ingest(store: store, sources: [deltaSpec(live), deltaSpec(archived)])
        try ingest.scan()
        let before = try totals(store)
        #expect(before.input == 300 && before.output == 30 && before.requests == 2)

        try FileManager.default.moveItem(atPath: live + "/r.jsonl", toPath: archived + "/r.jsonl")
        let st = try ingest.scan()
        #expect(st.moves == 1 && st.resets == 0)
        let after = try totals(store)
        #expect(after == before)
        #expect(try store.db.one("SELECT count(*), max(path) FROM source_file") { ($0.int(0), $0.text(1)) }! == (1, archived + "/r.jsonl"))

        // Tailing continues at the new path: only the appended line is added.
        let h = FileHandle(forWritingAtPath: archived + "/r.jsonl")!
        h.seekToEndOfFile(); h.write("s1 1761800120 5 1\n".data(using: .utf8)!); h.closeFile()
        try ingest.scan()
        #expect(try totals(store) == (305, 31, 3))
    }

    @Test func copyIsNotAMove() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "s1 1761800000 100 10\n".write(toFile: dir + "/a.jsonl", atomically: false, encoding: .utf8)
        let store = try Store(path: ":memory:")
        let ingest = Ingest(store: store, sources: [deltaSpec(dir)])
        try ingest.scan()
        try FileManager.default.copyItem(atPath: dir + "/a.jsonl", toPath: dir + "/b.jsonl")
        let st = try ingest.scan()
        #expect(st.moves == 0)
        #expect(try totals(store).requests == 2)  // a real second file (other inode) is counted
    }

    @Test func archivedFlagIsMergedAndHiddenFromLiveList() throws {
        let store = try Store(path: ":memory:")
        try store.mergeSession(SessionMeta(id: "codex:a", tool: .codex, title: "t", titleRank: TitleRank.external))
        #expect(try store.db.one("SELECT archived FROM session") { $0.optInt(0) } == .some(nil))
        try store.mergeSession(SessionMeta(id: "codex:a", tool: .codex, archived: true))
        try store.mergeSession(SessionMeta(id: "codex:a", tool: .codex))  // nil = unknown, keeps the flag
        #expect(try store.db.one("SELECT archived FROM session") { $0.optInt(0) } == 1)

        try store.db.run("UPDATE session SET last_at = 1761800000")
        try store.mergeSession(SessionMeta(id: "codex:b", tool: .codex, archived: false))
        try store.db.run("UPDATE session SET last_at = 1761800000 WHERE id = 'codex:b'")
        #expect(try Reports(store: store).sessions().map(\.id) == ["codex:b"])
    }
}
