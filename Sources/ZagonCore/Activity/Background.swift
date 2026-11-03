/// Background tasks still running in a Claude session (`session.bg_tasks`, v9), as its transcript tells: written by
/// transcript ingest (launches and ends), cleared by a new process of the session (`SpoolIngest`, SessionStart).
/// Stored as `id@launched@until` entries (epoch seconds) separated by spaces; `session.bg_until` = the latest `until`.
public enum Background {
    public struct Task: Equatable, Sendable { public var launched: Timestamp, until: Timestamp }

    static func decode(_ s: String?) -> [String: Task] {
        var out: [String: Task] = [:]
        for e in (s ?? "").split(separator: " ") {
            let p = e.split(separator: "@")
            guard p.count == 3, let l = Double(p[1]), let u = Double(p[2]) else { continue }
            out[String(p[0])] = Task(launched: l, until: u)
        }
        return out
    }

    /// The column values: nil, nil for no tasks.
    static func encode(_ tasks: [String: Task]) -> (tasks: String?, until: Timestamp?) {
        guard !tasks.isEmpty else { return (nil, nil) }
        let s = tasks.sorted { $0.key < $1.key }.map { "\($0.key)@\(Int64($0.value.launched))@\(Int64($0.value.until))" }
        return (s.joined(separator: " "), tasks.values.map(\.until).max())
    }

    /// How many of the stored tasks still run at `now`.
    public static func count(_ s: String?, now: Timestamp) -> Int { decode(s).values.filter { $0.until > now }.count }

    /// Applies launches (`until` set) and ends of one session's tasks to `stored`, in order; drops tasks past their
    /// `until` by the last record's time. Nil when nothing changed.
    static func apply(_ xs: [BackgroundTask], to stored: String?) -> (tasks: String?, until: Timestamp?)? {
        var open = decode(stored)
        for t in xs { open[t.id] = t.until.map { Task(launched: t.ts, until: $0) } }
        if let last = xs.map(\.ts).max() { open = open.filter { $0.value.until > last } }
        let e = encode(open)
        return e.tasks == stored ? nil : e
    }

    /// The tasks of `stored` launched before `ts` dropped (a new process started then: they died with the old one).
    /// Nil when nothing changed.
    static func restart(_ stored: String?, at ts: Timestamp) -> (tasks: String?, until: Timestamp?)? {
        let e = encode(decode(stored).filter { $0.value.launched >= ts.rounded(.down) })
        return e.tasks == stored ? nil : e
    }
}
