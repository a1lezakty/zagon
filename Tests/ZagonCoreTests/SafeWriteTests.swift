import Foundation
import Testing
@testable import ZagonCore

/// A temporary file name is never written through a planted symlink or over someone else's file.
@Suite struct SafeWriteTests {
    @Test func plantedSymlinkIsNotFollowed() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        Sys.writeFile(dir + "/victim", Array("precious".utf8))
        Sys.writeFile(dir + "/settings.json", Array("{}".utf8))
        #expect(symlink(dir + "/victim", dir + "/settings.json.zagon-tmp") == 0)
        #expect(!Sys.writeFile(dir + "/settings.json", Array("{\"a\":1}".utf8)))
        #expect(Sys.readFile(dir + "/victim") == Array("precious".utf8))
        #expect(Sys.readFile(dir + "/settings.json") == Array("{}".utf8))
        // A directory in the way is refused too.
        mkdir(dir + "/other.zagon-tmp", 0o700)
        #expect(!Sys.writeFile(dir + "/other", [1]))

        // The archive's temporary copy is protected the same way.
        Sys.writeFile(dir + "/t.jsonl", Array("line\n".utf8))
        #expect(symlink(dir + "/victim", dir + "/t.jsonl.zst.tmp") == 0)
        let a = Archive(store: try Store(path: ":memory:"), dir: dir)
        #expect(throws: ArchiveError.self) { _ = try a.compress(dir + "/t.jsonl", size: 5, to: dir + "/t.jsonl.zst") }
        #expect(Sys.readFile(dir + "/victim") == Array("precious".utf8))
    }

    @Test func ownLeftoverIsReplacedAndModeKept() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        Sys.writeFile(dir + "/f", Array("old".utf8), mode: 0o640)
        Sys.writeFile(dir + "/f.zagon-tmp", Array("half-written".utf8))  // an interrupted earlier write of ours
        #expect(Sys.writeFile(dir + "/f", Array("new".utf8)))
        #expect(Sys.readFile(dir + "/f") == Array("new".utf8) && !Sys.exists(dir + "/f.zagon-tmp"))
        var st = stat()
        stat(dir + "/f", &st)
        #expect(st.st_mode & 0o777 == 0o640)
        #expect(Sys.writeFile(dir + "/g", [1], mode: 0o755))
        stat(dir + "/g", &st)
        #expect(st.st_mode & 0o777 == 0o755)
    }
}
