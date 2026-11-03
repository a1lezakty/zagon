/// Background tasks still running in a Claude session (`session.bg_tasks`, v9), as its transcript tells: written by
/// transcript ingest (launches and ends) and by a new process of the session (`SpoolIngest`, SessionStart), which
/// moves `session.bg_since`: launches before it belong to another process (or to the history a fork copied) and do
/// not count, whichever of the two is read first.
/// Stored as `id@launched@until` entries (epoch seconds) separated by spaces; `session.bg_until` = the latest `until`.
public enum Background {
    public struct Task: Equatable, Sendable { public var launched: Timestamp, until: Timestamp }
    public struct State: Equatable, Sendable { public var tasks: String?, until: Timestamp?, since: Timestamp? }

    /// An ended task still counts this long: Claude Code starts a turn on its notification a few seconds later, and
    /// until the transcript shows it the session is not waiting for you.
    static let grace: Double = 120

    static func decode(_ s: String?) -> [String: Task] {
        var out: [String: Task] = [:]
        for e in (s ?? "").split(separator: " ") {
            let p = e.split(separator: "@")
            guard p.count == 3, let l = Double(p[1]), let u = Double(p[2]) else { continue }
            out[String(p[0])] = Task(launched: l, until: u)
        }
        return out
    }

    static func encode(_ tasks: [String: Task], since: Timestamp?) -> State {
        guard !tasks.isEmpty else { return State(tasks: nil, until: nil, since: since) }
        let s = tasks.sorted { $0.key < $1.key }.map { "\($0.key)@\(Int64($0.value.launched))@\(Int64($0.value.until))" }
        return State(tasks: s.joined(separator: " "), until: tasks.values.map(\.until).max(), since: since)
    }

    /// How many of the stored tasks still run at `now`.
    public static func count(_ s: String?, now: Timestamp) -> Int { decode(s).values.filter { $0.until > now }.count }

    /// Applies one session's launches (`until` set), ends (`until` nil) and fork marks (`id` "": launches before `ts`
    /// are copied history) to the stored state, in order; drops tasks past their `until` by the last record's time.
    /// Nil when nothing changed.
    static func apply(_ xs: [BackgroundTask], to stored: State) -> State? {
        var open = decode(stored.tasks), since = stored.since
        for t in xs {
            if t.id.isEmpty {
                since = max(since ?? t.ts, t.ts)
                open = open.filter { $0.value.launched >= since!.rounded(.down) }
            } else if let u = t.until {
                if t.ts >= since ?? -.infinity { open[t.id] = Task(launched: t.ts, until: u) }
            } else if var e = open[t.id] {
                e.until = min(e.until, t.ts + grace)
                open[t.id] = e
            }
        }
        if let last = xs.map(\.ts).max() { open = open.filter { $0.value.until > last } }
        let e = encode(open, since: since)
        return e == stored ? nil : e
    }

    /// A new process started at `ts`: the tasks launched before it died with the old one, and launches before it
    /// read later do not count. Nil when nothing changed.
    static func restart(_ stored: State, at ts: Timestamp) -> State? {
        apply([BackgroundTask(sessionId: "", id: "", ts: ts, until: nil)], to: stored)
    }
}
