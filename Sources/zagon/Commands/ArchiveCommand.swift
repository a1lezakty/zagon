import ArgumentParser
import ZagonCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// zstd copies of transcripts in `<data dir>/archive`, readable after Claude Code or Codex removed the originals.
struct ArchiveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "archive", abstract: "Compressed copies of transcripts (kept after the originals are cleaned up).",
        subcommands: [Run.self, Stats.self, Cat.self])

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Copy quiet sessions (a pass every 10 minutes).")
        @OptionGroup var common: Common
        @Flag(help: "One pass, then exit.") var once = false
        @Option(help: "Minutes a session must be quiet before it is copied.") var idle: Double = 60

        func run() throws {
            let store = try common.open()
            var a = Archive(store: store, dir: common.dataDir + "/archive")
            a.idle = idle * 60
            repeat {
                let t0 = Time.monotonic()
                do {
                    try common.scan(store)
                    let s = try a.tick()
                    print("archive: \(s.written) file(s) written, \(Fmt.bytes(s.rawBytes)) → \(Fmt.bytes(s.packedBytes)), "
                          + Fmt.secs(Time.monotonic() - t0))
                } catch { print("archive: \(error)") }
                if !once { sleep(600) }
            } while !once
        }
    }

    struct Stats: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Sessions and bytes before / after compression.")
        @OptionGroup var common: Common
        func run() throws {
            let s = try Archive(store: try common.open(), dir: common.dataDir + "/archive").stats()
            let ratio = s.packedBytes > 0 ? Double(s.rawBytes) / Double(s.packedBytes) : 0
            print("\(s.sessions) sessions, \(s.files) files, \(Fmt.bytes(s.rawBytes)) → \(Fmt.bytes(s.packedBytes))"
                  + " (×\(Fmt.one(ratio))), originals gone: \(s.orphans)")
        }
    }

    struct Cat: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print a session's archived transcript.")
        @Argument(help: "Session id (claude:<id>, <id> or a unique prefix).") var session: String
        @OptionGroup var common: Common
        func run() throws {
            let store = try common.open()
            let a = Archive(store: store, dir: common.dataDir + "/archive")
            guard let id = try a.resolve(session) else { throw ValidationError("no single session matches \(session)") }
            guard let copy = try store.db.one("SELECT archive_path FROM session WHERE id = ?", [.text(id)], { $0.text(0) }) ?? nil,
                  Sys.exists(copy) else { throw ValidationError("\(id) has no archive yet") }
            signal(SIGPIPE, SIG_DFL)
            try Archive.decompress(copy) { b in
                if !b.isEmpty && !Sys.writeAll(fd: 1, Array(b)) { throw ExitCode(1) }
            }
        }
    }
}
