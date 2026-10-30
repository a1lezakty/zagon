import Foundation
import Testing
@testable import ZagonCore

/// Replays the notification rules over real logs as the daemon saw them: transcripts and the hook spool are
/// rewritten line by line up to each tick, then ingest, spool and `Notifier.tick` run. Read-only on the sources;
/// prints only times, keys and durations. Run locally with the real logs mounted read-only, e.g.
/// `ZAGON_REPLAY_SESSIONS=1b2c3d4e,5f6a7b8c ZAGON_REPLAY_SPOOL=/data/spool/2026-10-30.ndjson
///  ZAGON_REPLAY_FROM=2026-10-30T12:12:52Z ZAGON_REPLAY_TO=2026-10-30T13:00:00Z swift test --filter NotifyReplay`
/// (projects in /data/projects). The first tick starts from an empty store, like a daemon start. ZAGON_REPLAY_STEP:
/// seconds between ticks (30). ZAGON_REPLAY_TRACE=<prefixes>: status, last working stretch and `busy` whenever they change.
@Suite struct NotifyReplay {
    /// A real file rewritten up to a moment; a line without its own time goes with the line before.
    final class Feed {
        let data: [UInt8], out: String
        var ends: [(end: Int, ts: Double)] = []
        var next = 0, offset = 0
        init(_ src: String, to out: String, ts: ([UInt8]) -> Double?) {
            data = Array(FileManager.default.contents(atPath: src) ?? Data())
            self.out = out
            var start = 0, last = 0.0
            while let nl = data[start...].firstIndex(of: 0x0A) {
                last = ts(Array(data[start..<nl])) ?? last
                ends.append((nl + 1, last))
                start = nl + 1
            }
        }
        func advance(to t: Double) {
            var end = offset
            while next < ends.count, ends[next].ts <= t { end = ends[next].end; next += 1 }
            guard end > offset else { return }
            if offset == 0 {
                try! FileManager.default.createDirectory(atPath: Sys.dirname(out), withIntermediateDirectories: true)
                _ = FileManager.default.createFile(atPath: out, contents: nil)
            }
            let h = FileHandle(forWritingAtPath: out)!
            h.seekToEndOfFile(); h.write(Data(data[offset..<end])); h.closeFile()
            offset = end
        }
    }

    static let env = ProcessInfo.processInfo.environment

    @Test(.enabled(if: env["ZAGON_REPLAY_SESSIONS"] != nil)) func replay() throws {
        let e = Self.env, fm = FileManager.default
        let projects = e["ZAGON_REPLAY_PROJECTS"] ?? "/data/projects"
        let from = Time.parseISO(e["ZAGON_REPLAY_FROM"]!)!, to = Time.parseISO(e["ZAGON_REPLAY_TO"]!)!
        let root = tempDir()
        defer { try? fm.removeItem(atPath: root) }
        let lineTime: ([UInt8]) -> Double? = { JValue.topLevelStrings($0, keys: ["timestamp"])?["timestamp"].flatMap(Time.parseISO) }
        var feeds: [Feed] = []
        for prefix in e["ZAGON_REPLAY_SESSIONS"]!.split(separator: ",") {
            for proj in try fm.contentsOfDirectory(atPath: projects) {
                for f in (try? fm.contentsOfDirectory(atPath: projects + "/" + proj)) ?? [] where f.hasPrefix(prefix) && f.hasSuffix(".jsonl") {
                    var rels = [proj + "/" + f]
                    let sub = proj + "/" + f.dropLast(6) + "/subagents"
                    for a in (try? fm.contentsOfDirectory(atPath: projects + "/" + sub)) ?? [] where a.hasSuffix(".jsonl") { rels.append(sub + "/" + a) }
                    feeds += rels.map { Feed(projects + "/" + $0, to: root + "/projects/" + $0, ts: lineTime) }
                }
            }
        }
        let spoolSrc = e["ZAGON_REPLAY_SPOOL"]!
        feeds.append(Feed(spoolSrc, to: root + "/spool/" + Sys.basename(spoolSrc)) { JValue.parse($0)?["ts"]?.double })
        print("replay: \(feeds.count - 1) transcript files")

        var o = IngestOptions()
        o.host = "replay"
        o.dedupDays = 1e6
        let store = try Store(path: ":memory:"), ch = FakeChannel()
        let ingest = Ingest(store: store, sources: [ClaudeSource.spec(root: root + "/projects")], options: o)
        var c = NotifyConfig()
        c.quiet = nil; c.summaryAt = nil; c.worklogAt = nil; c.lang = .ru
        let n = Notifier(store: store, config: c, channels: [ch])
        n.log = { _ in }
        var t = from, trace: [String: String] = [:]
        while t <= to {
            for f in feeds { f.advance(to: t) }
            _ = try ingest.scan()
            try SpoolIngest.run(store: store, spoolDir: root + "/spool", now: t)
            for pre in (e["ZAGON_REPLAY_TRACE"] ?? "").split(separator: ",") {
                guard let id = try store.db.one("SELECT id FROM session WHERE id LIKE ?", [.text("claude:\(pre)%")], { $0.text(0) }) ?? nil,
                      let row = try n.session(id) else { continue }
                var xs: [Interval] = []
                try store.db.query("SELECT start, \"end\" FROM activity WHERE kind = 'working' AND session_id = ? AND \"end\" > ?",
                                   [.text(id), .real(t - 12 * 3600)]) { xs.append(Interval($0.real(0), $0.real(1))) }
                let m = Intervals.merge(xs), last = m.last
                func c(_ x: Double?) -> String { x.map { String(iso($0).dropFirst(11).prefix(8)) } ?? "-" }
                let busy = try last.map { try n.busy(id, since: $0.start, now: t) ? " BUSY" : "" } ?? ""
                let line = "\(row.status ?? "-")@\(c(row.statusAt)) last \(c(last?.start))-\(c(last?.end)) \(Int((last?.length ?? 0) / 60))m n=\(m.count)\(busy)"
                if trace[id] != line { trace[id] = line; print("trace: \(c(t)) \(pre) \(line)") }
            }
            let sent = try n.tick(now: t)
            for (k, m) in zip(sent, ch.sent.suffix(sent.count)) where k.hasPrefix("done:") || k.hasPrefix("wait:") {
                let p = k.split(separator: ":")
                let what = p[0] == "done" ? "работала " + (m.text.components(separatedBy: "работала ").last ?? "") : m.title
                print("replay: \(iso(t).dropFirst(11).prefix(8)) \(p[0]) \(p[2].prefix(8)) \(what)")
            }
            t += Double(e["ZAGON_REPLAY_STEP"] ?? "30")!
        }
    }
}
