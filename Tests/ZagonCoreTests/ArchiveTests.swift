import Foundation
import Testing
@testable import ZagonCore

@Suite struct ArchiveTests {
    func tempDir() -> String {
        let d = NSTemporaryDirectory() + "zagon-archive-" + UUID().uuidString
        try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    func setMtime(_ path: String, _ t: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: t)], ofItemAtPath: path)
    }

    func unpack(_ path: String) throws -> [UInt8] {
        var out: [UInt8] = []
        try Archive.decompress(path) { out.append(contentsOf: $0) }
        return out
    }

    /// Made-up transcript lines (no real text).
    func lines(_ n: Int, from k: Int = 0) -> String {
        (k..<(k + n)).map { i in
            #"{"type":"assistant","timestamp":"2026-10-01T10:\#(i % 50 + 10):00.000Z","sessionId":"s1","cwd":"/w/p","message":{"id":"m\#(i)","model":"claude-opus-4","role":"assistant","content":[{"type":"text","text":"step \#(i) of the made-up plan"}],"usage":{"input_tokens":10,"output_tokens":5}}}"#
        }.joined(separator: "\n") + "\n"
    }

    /// A Claude projects dir with one session (main file + one sub-agent), ingested into a fresh store.
    func setUp() throws -> (Archive, root: String, main: String, agent: String) {
        let dir = tempDir(), root = dir + "/projects"
        let main = root + "/-w-p/s1.jsonl", agent = root + "/-w-p/s1/subagents/agent-a1.jsonl"
        Sys.mkdirs(root + "/-w-p/s1/subagents")
        Sys.writeFile(main, Array(lines(300).utf8))
        Sys.writeFile(agent, Array(lines(40, from: 1000).utf8))
        let store = try Store(path: ":memory:")
        try Ingest(store: store, sources: [ClaudeSource.spec(root: root)]).scan()
        for p in [main, agent] { try setMtime(p, Sys.now() - 7200) }
        return (Archive(store: store, dir: dir + "/archive"), root, main, agent)
    }

    @Test func roundTripByteForByte() throws {
        let dir = tempDir()
        var rng = SystemRandomNumberGenerator()
        let samples: [[UInt8]] = [
            [], [0x41], Array(lines(20000).utf8),                                    // empty, 1 byte, ~4 MB of text
            (0..<3_000_000).map { _ in UInt8.random(in: 0...255, using: &rng) },     // incompressible
        ]
        let a = Archive(store: try Store(path: ":memory:"), dir: dir)
        for (i, b) in samples.enumerated() {
            Sys.writeFile(dir + "/in\(i)", b)
            let (raw, packed) = try a.compress(dir + "/in\(i)", size: b.count, to: dir + "/out\(i).zst")
            #expect(raw == b.count && packed == Sys.fileSize(dir + "/out\(i).zst"))
            #expect(Archive.contentSize(dir + "/out\(i).zst") == b.count)
            #expect(try unpack(dir + "/out\(i).zst") == b)
        }
        #expect(Sys.fileSize(dir + "/out2.zst")! * 5 < samples[2].count)
    }

    @Test func quietSessionsAreCopiedOnceWithSubagents() throws {
        var (a, _, main, agent) = try setUp()
        let s = try a.tick()
        #expect(s.written == 2)
        let copy = try #require(try a.store.db.one("SELECT archive_path FROM session WHERE id = 'claude:s1'") { $0.text(0) } ?? nil)
        #expect(copy.hasPrefix(a.dir + "/claude/2026-10/s1.jsonl.zst"))
        #expect(try unpack(copy) == Sys.readFile(main))
        #expect(try unpack(a.dir + "/claude/2026-10/s1/subagents/agent-a1.jsonl.zst") == Sys.readFile(agent))
        var st = stat()
        stat(copy, &st)
        #expect(st.st_mode & 0o777 == 0o600)
        stat(a.dir + "/claude/2026-10", &st)
        #expect(st.st_mode & 0o777 == 0o700)
        #expect(try a.tick().written == 0)  // nothing changed

        // Appended later: copied again once quiet, whole file.
        FileHandle(forWritingAtPath: main).map { $0.seekToEndOfFile(); $0.write(Data(lines(5, from: 500).utf8)); $0.closeFile() }
        try setMtime(main, Sys.now() - 120)
        #expect(try a.tick().written == 0)  // written two minutes ago: still active
        try setMtime(main, Sys.now() - 4000)
        #expect(try a.tick().written == 1)
        #expect(try unpack(copy) == Sys.readFile(main))

        let stats = try a.stats()
        #expect(stats.sessions == 1 && stats.files == 2 && stats.orphans == 0)
        #expect(stats.rawBytes == (Sys.fileSize(main)! + Sys.fileSize(agent)!) && stats.packedBytes < stats.rawBytes / 5)
        a.idle = 1e9
        #expect(try a.tick().written == 0)
    }

    @Test func sameNamesGetSeparateCopies() throws {
        var (a, root, main, agent) = try setUp()
        // The session went on in another project dir, and a workflow sub-agent has the same file name.
        let main2 = root + "/-w-q/s1.jsonl", agent2 = root + "/-w-p/s1/subagents/workflows/w1/agent-a1.jsonl"
        Sys.mkdirs(root + "/-w-q"); Sys.mkdirs(root + "/-w-p/s1/subagents/workflows/w1")
        Sys.writeFile(main2, Array(lines(7, from: 2000).utf8))
        Sys.writeFile(agent2, Array(lines(9, from: 3000).utf8))
        try Ingest(store: a.store, sources: [ClaudeSource.spec(root: root)]).scan()
        for p in [main, agent, main2, agent2] { try setMtime(p, Sys.now() - 7200) }
        #expect(try a.tick().written == 4)
        let d = a.dir + "/claude/2026-10/"
        let id2 = try #require(try a.store.db.one("SELECT id FROM source_file WHERE path = ?", [.text(main2)]) { $0.int(0) })
        #expect(try unpack(d + "s1.jsonl.zst") == Sys.readFile(main))
        #expect(try unpack(d + "s1-\(id2).jsonl.zst") == Sys.readFile(main2))
        #expect(try unpack(d + "s1/subagents/agent-a1.jsonl.zst") == Sys.readFile(agent))
        #expect(try unpack(d + "s1/subagents/workflows/w1/agent-a1.jsonl.zst") == Sys.readFile(agent2))
        #expect(try a.tick().written == 0)  // stable: no ping-pong between the two main files
        a.idle = 0
        #expect(try a.tick().written == 0)
    }

    @Test func activeSessionIsNotCopied() throws {
        let (a, _, main, _) = try setUp()
        try setMtime(main, Sys.now() - 60)  // the sub-agent is quiet, the session is not
        #expect(try a.tick().written == 0)
        #expect(!Sys.exists(a.dir))
    }

    @Test func interruptedWriteKeepsTheOldCopy() throws {
        var (a, _, main, _) = try setUp()
        try a.tick()
        let copy = a.dir + "/claude/2026-10/s1.jsonl.zst"
        let before = try #require(Sys.readFile(copy))
        FileHandle(forWritingAtPath: main).map { $0.seekToEndOfFile(); $0.write(Data(lines(5, from: 600).utf8)); $0.closeFile() }
        try setMtime(main, Sys.now() - 4000)
        a.beforeRename = { throw ArchiveError("power cut") }
        #expect(throws: ArchiveError.self) { try a.tick() }
        #expect(Sys.readFile(copy) == before && !Sys.exists(copy + ".tmp"))
        // A copy cut short (e.g. by a full disk outside the rename) is reported, not silently read.
        Sys.writeFile(a.dir + "/cut.zst", Array(before.prefix(before.count / 2)))
        #expect(throws: ArchiveError.self) { try unpack(a.dir + "/cut.zst") }
    }

    @Test func goneOriginalIsReadFromTheCopy() throws {
        let (a, _, main, agent) = try setUp()
        let original = try #require(Sys.readFile(main))
        try a.tick()
        #expect(try a.transcript("claude:s1") == original)  // original still there
        unlink(main); unlink(agent)
        #expect(try a.tick().written == 0)                    // the copy is left alone
        #expect(try a.transcript("claude:s1") == original)
        #expect(try a.stats().orphans == 1)
        #expect(try a.resolve("s1") == "claude:s1" && a.resolve("claude:s1") == "claude:s1" && a.resolve("zz") == nil)
    }
}
