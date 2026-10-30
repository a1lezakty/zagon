import Foundation

/// The app log: `zagon.log` in `~/Library/Logs/Zagon` plus `keep` rotated copies of up to `maxBytes` each (5 MB in
/// all). The home folder is written as `~`; conversation text is never logged.
public final class Log: @unchecked Sendable {
    public static let shared = Log()
    let maxBytes: Int, keep: Int
    private let lock = NSLock()
    private var dir: String?

    init(maxBytes: Int = 1_000_000, keep: Int = 4) { self.maxBytes = maxBytes; self.keep = keep }

    /// Lines written before this are dropped (tests, snapshots).
    public func start(dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        lock.withLock { self.dir = dir }
    }

    public var directory: String? { lock.withLock { dir } }

    public static func scrub(_ s: String, home: String = NSHomeDirectory()) -> String {
        home.count > 1 ? s.replacingOccurrences(of: home, with: "~") : s
    }

    public func write(_ message: String, at date: Date = Date()) {
        lock.withLock {
            guard let dir else { return }
            let path = dir + "/zagon.log"
            let line = Data((date.formatted(.iso8601) + " " + Log.scrub(message) + "\n").utf8)
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
            if size > 0, size + line.count > maxBytes { rotate(dir) }
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile()
                h.write(line)
                try? h.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: line)
            }
        }
    }

    private func rotate(_ dir: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: "\(dir)/zagon.\(keep).log")
        for i in stride(from: keep - 1, through: 1, by: -1) {
            try? fm.moveItem(atPath: "\(dir)/zagon.\(i).log", toPath: "\(dir)/zagon.\(i + 1).log")
        }
        try? fm.moveItem(atPath: "\(dir)/zagon.log", toPath: "\(dir)/zagon.1.log")
    }
}

/// Health lines and the diagnostics folder sent to the developers: versions, counters and logs, no conversation text
/// and no home-folder paths.
public enum Diagnostics {
    static func mb(_ bytes: Int) -> String { String(format: "%.1fMB", Double(bytes) / 1_000_000) }

    /// "health rss=48.2MB cpu=0.4% db=12.5MB scanErrors=0 servers=1/2"
    public static func health(rss: Int, cpuPct: Double, dbBytes: Int, scanErrors: Int, servers: Int, offline: Int) -> String {
        "health rss=\(mb(rss)) cpu=\(String(format: "%.1f", cpuPct))% db=\(mb(dbBytes)) scanErrors=\(scanErrors)"
            + " servers=\(servers - offline)/\(servers)"
    }

    /// `info.txt`: versions, system, database counters, server state.
    public static func info(version: String, system: String, counters: [(String, Int)], dbBytes: Int,
                            hostErrors: [String: String], servers: [String], at: Date, zone: String? = nil) -> String {
        let shown = zone.map { ", shown in " + $0 } ?? ""
        var lines = ["Zagon \(version)", "System: \(system)", "Time: \(at.formatted(.iso8601))",
                     "Time zone: " + TimeZone.current.identifier + shown, "Database: \(mb(dbBytes))"]
        lines += counters.map { "  \($0.0): \($0.1)" }
        lines.append("Servers: \(servers.count)")
        lines += servers.map { "  \($0): " + (hostErrors[$0].map { "error: " + $0 } ?? "ok") }
        return Log.scrub(lines.joined(separator: "\n") + "\n")
    }

    /// A new folder `Zagon-diagnostics-<time>` in `parent` with the logs (home paths scrubbed again) and `info.txt`.
    public static func folder(logs: String?, info: String, in parent: String, at: Date) throws -> String {
        let stamp = at.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        let dir = parent + "/Zagon-diagnostics-" + stamp
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try info.write(toFile: dir + "/info.txt", atomically: true, encoding: .utf8)
        for name in (logs.flatMap { try? fm.contentsOfDirectory(atPath: $0) } ?? []).sorted() where name.hasSuffix(".log") {
            guard let logs, let text = try? String(contentsOfFile: logs + "/" + name, encoding: .utf8) else { continue }
            try Log.scrub(text).write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
        }
        return dir
    }
}
