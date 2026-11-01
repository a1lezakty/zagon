import Foundation
import Testing
@testable import ZagonCore

/// Codex compresses a cold rollout `<name>` to `<name>.zst` (the same bytes) and deletes the original; to append it
/// unpacks it to `<name>` again (a new inode via a hard link) and deletes the `.zst`. With per-request deltas and no
/// ids (DeltaParser), any recount of a known file would show up as doubled totals.
@Suite struct CompressedRolloutTests {
    let dir = tempDir()
    var live: String { dir + "/sessions" }
    var archived: String { dir + "/archived_sessions" }
    var plain: String { live + "/r.jsonl" }

    init() throws {
        for d in [live, archived] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
    }

    func spec(_ root: String) -> SourceSpec {
        SourceSpec(tool: .codex, root: root, accepts: { $0.hasSuffix(".jsonl") || $0.hasSuffix(".jsonl.zst") },
                   makeParser: { _, _, _ in DeltaParser() })
    }

    func ingest(_ store: Store) -> Ingest { Ingest(store: store, sources: [spec(live), spec(archived)]) }

    func write(_ path: String, _ text: String) throws { try text.write(toFile: path, atomically: false, encoding: .utf8) }

    func append(_ path: String, _ text: String) {
        let h = FileHandle(forWritingAtPath: path)!
        h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); h.closeFile()
    }

    /// Codex's compression: the copy next to the file (`keep`: the original is not deleted yet).
    func compress(_ path: String, to dst: String? = nil, keep: Bool = false) throws {
        let a = Archive(store: try Store(path: ":memory:"), dir: dir)
        _ = try a.compress(path, size: Sys.fileSize(path)!, to: dst ?? path + ".zst")
        if !keep { try FileManager.default.removeItem(atPath: path) }
    }

    /// Codex's unpacking to append: a temporary file hard-linked to `<name>`, then the `.zst` deleted (`keep`: not yet).
    func unpack(_ zst: String, keep: Bool = false) throws {
        let tmp = Sys.dirname(zst) + "/.rollout-materialize-1"
        try Data(Archive.readLog(zst)!).write(to: URL(fileURLWithPath: tmp))
        #expect(link(tmp, String(zst.dropLast(4))) == 0)
        try FileManager.default.removeItem(atPath: tmp)
        if !keep { try FileManager.default.removeItem(atPath: zst) }
    }

    func rows(_ s: Store) throws -> [String] {
        var p: [String] = []
        try s.db.query("SELECT path FROM source_file ORDER BY id") { p.append($0.text(0) ?? "") }
        return p
    }

    @Test func compressedAfterReadingCountsOnlyWhatFollowed() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write(plain, "s1 1761800000 100 10\ns1 1761800060 200 20\n")
        let store = try Store(path: ":memory:"), ing = ingest(store)
        try ing.scan()
        #expect(try totals(store) == (300, 30, 2))

        append(plain, "s1 1761800120 5 1\ns1 17618")  // written before the compression, not seen yet; a partial line
        try compress(plain)
        let st = try ing.scan()
        #expect(st.resets == 0)
        #expect(try totals(store) == (305, 31, 3))
        #expect(try rows(store) == [plain])  // the row keeps the plain name

        let again = try ing.scan()
        #expect(again.filesRead == 0)  // a .zst is read once
        #expect(try totals(store) == (305, 31, 3))
    }

    @Test func bothFormsAtOnceCountOnce() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write(plain, "s1 1761800000 100 10\n")
        let store = try Store(path: ":memory:"), ing = ingest(store)
        try ing.scan()
        try compress(plain, keep: true)
        try ing.scan()
        #expect(try totals(store) == (100, 10, 1))
        #expect(try rows(store) == [plain])  // the copy beside it is skipped

        // The watcher sees the original go; its .zst, skipped before, is taken over then.
        try FileManager.default.removeItem(atPath: plain)
        try ing.update(paths: [plain])
        #expect(try ing.isPacked(1))
        #expect(try totals(store) == (100, 10, 1))
    }

    @Test func unpackedToAppendContinuesAtTheOffset() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write(plain, "s1 1761800000 100 10\n")
        let store = try Store(path: ":memory:"), ing = ingest(store)
        try ing.scan()
        try compress(plain)
        try ing.scan()

        try unpack(plain + ".zst", keep: true)  // for a moment both exist
        var st = try ing.scan()
        #expect(st.resets == 0)
        #expect(try rows(store) == [plain])
        try FileManager.default.removeItem(atPath: plain + ".zst")
        append(plain, "s1 1761800060 7 2\n")
        st = try ing.scan()
        #expect(st.resets == 0)
        #expect(try totals(store) == (107, 12, 2))

        // Cold again: compressed once more.
        try compress(plain)
        st = try ing.scan()
        #expect(st.resets == 0)
        #expect(try totals(store) == (107, 12, 2))
    }

    @Test func compressedAndArchivedWhileAwayCountsOnce() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write(plain, "s1 1761800000 100 10\n")
        let store = try Store(path: ":memory:"), ing = ingest(store)
        try ing.scan()
        append(plain, "s1 1761800060 1 1\n")
        try compress(plain, to: archived + "/r.jsonl.zst")  // another inode in another root
        let st = try ing.scan()
        #expect(st.resets == 0 && st.moves == 1)
        #expect(try totals(store) == (101, 11, 2))
        #expect(try rows(store) == [archived + "/r.jsonl"])

        // Unarchived (a rename: same inode) and unpacked to append, both unseen until now.
        try FileManager.default.moveItem(atPath: archived + "/r.jsonl.zst", toPath: plain + ".zst")
        try unpack(plain + ".zst")
        append(plain, "s1 1761800120 2 2\n")
        try ing.scan()
        #expect(try totals(store) == (103, 13, 3))
        #expect(try rows(store) == [plain])
    }

    @Test func onlyCompressedCountsOnceAndIsNotArchivedAgain() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write(plain, "s1 1761800000 100 10\ns1 1761800060 200 20\n")
        try compress(plain)
        try write(live + "/q.jsonl", "s2 1761800000 1 1\n")
        let store = try Store(path: ":memory:"), ing = ingest(store)
        try ing.scan()
        try ing.scan()
        #expect(try totals(store) == (301, 31, 3))
        // Our archive keeps copies of plain logs only: a .zst is its own compressed copy.
        let a = Archive(store: store, dir: dir + "/archive")
        #expect(try a.tick(now: Sys.now() + 7200).written == 1)
    }

    /// A zagon without `.zst` (a 0.1.4 MCP server still running after the update) on the same database: it sees the
    /// compressed file gone and the unpacked one replaced, so it recounts instead of counting twice.
    @Test func olderZagonOnTheSameDatabaseNeverDoubles() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write(plain, "s1 1761800000 100 10\n")
        let store = try Store(path: ":memory:"), ing = ingest(store)
        let old = Ingest(store: store, sources: [deltaSpec(live), deltaSpec(archived)])  // takes `.jsonl` only
        try ing.scan()
        try compress(plain)
        try ing.scan()
        try old.scan()
        #expect(try totals(store) == (100, 10, 1))
        try unpack(plain + ".zst")
        append(plain, "s1 1761800060 7 2\n")
        let o = try old.scan()
        #expect(o.resets == 1)
        #expect(try totals(store) == (107, 12, 2))
        try ing.scan()
        #expect(try totals(store) == (107, 12, 2))
        #expect(try !ing.isPacked(1))
    }

    @Test func damagedCompressedFileIsSkipped() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try write(live + "/bad.jsonl.zst", "not zstd at all\n")
        let store = try Store(path: ":memory:")
        try ingest(store).scan()
        #expect(try rows(store).isEmpty)
        #expect(try totals(store) == (0, 0, 0))
    }
}
