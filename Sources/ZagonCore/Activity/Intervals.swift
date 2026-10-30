/// Half-open time interval [start, end).
public struct Interval: Sendable, Equatable, Codable {
    public var start: Timestamp
    public var end: Timestamp
    public init(_ start: Timestamp, _ end: Timestamp) { self.start = start; self.end = end }
    public var length: Double { max(0, end - start) }
}

public enum Intervals {
    /// Union of intervals: sorted, overlapping and touching ones merged, empty ones dropped.
    public static func merge(_ xs: [Interval]) -> [Interval] {
        var out: [Interval] = []
        for x in xs.filter({ $0.end > $0.start }).sorted(by: { $0.start < $1.start }) {
            if let last = out.last, x.start <= last.end {
                out[out.count - 1].end = max(last.end, x.end)
            } else {
                out.append(x)
            }
        }
        return out
    }

    /// Total length of the union of `xs` inside [from, to).
    public static func covered(_ xs: [Interval], from: Timestamp, to: Timestamp) -> Double {
        merge(xs).reduce(0) { $0 + max(0, min($1.end, to) - max($1.start, from)) }
    }

    /// Chains sorted points into intervals [first, last] when consecutive points are at most `gap` apart.
    /// Isolated points give empty intervals and are dropped.
    public static func chain(_ points: [Timestamp], gap: Double) -> [Interval] {
        var out: [Interval] = []
        var cur: Interval?
        for t in points.sorted() {
            if var c = cur, t - c.end <= gap {
                c.end = max(c.end, t); cur = c
            } else {
                if let c = cur, c.end > c.start { out.append(c) }
                cur = Interval(t, t)
            }
        }
        if let c = cur, c.end > c.start { out.append(c) }
        return out
    }
}

/// Builds `working` intervals of one file from its events in order. Turn rule: a typed message starts a new
/// interval; agent events extend it; a silence longer than `sessionGap` between events ends it.
/// State is persisted per file so tailing can continue later.
public struct TurnBuilder: Codable, Sendable {
    /// Open interval per session id (end = last event so far).
    public var open: [String: Interval] = [:]
    /// Working directory of each open interval (optional: state saved before v4 has none).
    public var cwd: [String: String]?
    public init() {}

    public struct Output {
        /// Intervals that will not change any more, with the directory they were worked in.
        public var closed: [(session: String, interval: Interval, cwd: String?)] = []
        /// User actions: kind `msg` (typed) or `read` (end of the answer the user replied to).
        public var actions: [(session: String, ts: Timestamp, kind: String)] = []
    }

    public func cwd(of session: String) -> String? { cwd?[session] }
    mutating func setCwd(_ session: String, _ c: String?) {
        guard let c else { return }
        if cwd == nil { cwd = [:] }
        cwd![session] = c
    }

    public mutating func user(_ session: String, _ t: Timestamp, cwd c: String? = nil, idleGap: Double,
                              into out: inout Output) {
        // Records far older than the open interval are copies of history (resume/fork): not activity now.
        if let o = open[session], t < o.start - idleGap { return }
        if let o = open[session] {
            if o.end > o.start { out.closed.append((session, o, cwd(of: session))) }
            // The user replied to this answer: they were around when it ended.
            if t > o.end, t - o.end <= idleGap, o.end > o.start { out.actions.append((session, o.end, "read")) }
        }
        open[session] = Interval(t, t)
        setCwd(session, c)
        out.actions.append((session, t, "msg"))
    }

    /// An agent event. A new directory inside a turn splits the interval at the last event in the old one.
    public mutating func agent(_ session: String, _ t: Timestamp, cwd c: String? = nil, sessionGap: Double,
                               into out: inout Output) {
        if var o = open[session], t - o.end <= sessionGap {
            if t < o.start - sessionGap { return } // stale copy, see user()
            if let c, let was = cwd(of: session), c != was, t > o.end {
                if o.end > o.start { out.closed.append((session, o, was)) }
                open[session] = Interval(o.end, t)
                setCwd(session, c)
                return
            }
            if t > o.end { o.end = t }
            if t < o.start { o.start = t }
            open[session] = o
            if cwd(of: session) == nil { setCwd(session, c) }
        } else {
            if let o = open[session], o.end > o.start { out.closed.append((session, o, cwd(of: session))) }
            open[session] = Interval(t, t)
            setCwd(session, c)
        }
    }
}
