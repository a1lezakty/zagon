import ArgumentParser
import ZagonCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

struct ScanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "scan", abstract: "Read new data from transcripts once.")
    @OptionGroup var common: Common
    @Flag(help: "Print JSON stats.") var json = false
    func run() throws {
        let store = try common.open()
        let s = try common.scan(store)
        var ru = rusage()
        #if canImport(Glibc)
        getrusage(__rusage_who_t(RUSAGE_SELF.rawValue), &ru)
        #else
        getrusage(RUSAGE_SELF, &ru)
        #endif
        #if canImport(Darwin)
        let rss = Int(ru.ru_maxrss) >> 20  // bytes on macOS
        #else
        let rss = Int(ru.ru_maxrss) >> 10  // KB on Linux
        #endif
        if json { try emit(s); return }
        print("scan: peak RSS \(rss) MB, \(s.filesSeen) files, \(s.filesRead) read, \(Fmt.bytes(s.bytes)), \(s.lines) lines, "
              + "\(s.usageRecords) usage records, \(s.badLines) bad lines, \(s.resets) resets, \(Fmt.secs(s.seconds)) "
              + "(parse \(Fmt.secs(s.parseSeconds)), write \(Fmt.secs(s.applySeconds)), derive \(Fmt.secs(s.deriveSeconds)))")
    }
}
