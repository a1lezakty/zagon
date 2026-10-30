/// Pure worklog layout for one day. Invariant: entries never overlap each other or `busy` (worklogs already in
/// Jira, entries already logged or skipped), stay inside the day and sit on a 5-minute grid.
public enum WorklogPlanner {
    public static let step: Double = 300
    /// A task's share of a stretch below this many steps moves to its biggest stretch (no 5-minute worklogs).
    public static let minPiece = 3

    public struct Share: Sendable {
        public var task: Int
        public var seconds: Double
        /// First activity of the task inside the stretch (orders tasks within it).
        public var first: Timestamp
        public init(task: Int, seconds: Double, first: Timestamp) { self.task = task; self.seconds = seconds; self.first = first }
    }

    public struct Entry: Sendable, Hashable, Codable {
        public var task: Int
        public var start: Timestamp
        public var end: Timestamp
        public var seconds: Int { Int((end - start).rounded()) }
    }

    public struct Output: Sendable {
        public var entries: [Entry]
        /// Seconds per task that found no free time in the day.
        public var unplaced: [Int: Int]
    }

    /// `stretches[i]` is your i-th stretch of work with its per-task shares. Each task's time is reduced by what is
    /// already logged for it (`already`), rounded to 5 minutes and laid out inside the stretches it came from, tasks one
    /// after another in order of first activity, each from its first activity on (then earlier free time of the
    /// stretch). What does not fit goes to the free time nearest to its stretch.
    public static func plan(day: Interval, stretches: [(interval: Interval, shares: [Share])], already: [Int: Double] = [:],
                            busy: [Interval] = []) -> Output {
        let order = stretches.indices.sorted { stretches[$0].interval.start < stretches[$1].interval.start }
        // Whole 5-minute units per task, spread over its stretches by largest remainder.
        var need: [Int: Double] = [:]
        for s in stretches { for x in s.shares where x.seconds > 0 { need[x.task, default: 0] += x.seconds } }
        var units: [Int: [Int: Int]] = [:]  // stretch index -> task -> units
        for (task, total) in need {
            let n = Int((max(0, total - (already[task] ?? 0)) / step).rounded())
            guard n > 0 else { continue }
            var parts: [(i: Int, exact: Double)] = []
            for i in order { for x in stretches[i].shares where x.task == task && x.seconds > 0 { parts.append((i, Double(n) * x.seconds / total)) } }
            var got = parts.map { Int($0.exact.rounded(.down)) }
            let left = n - got.reduce(0, +)
            for k in parts.indices.sorted(by: { (parts[$0].exact - Double(got[$0])) > (parts[$1].exact - Double(got[$1])) }).prefix(left) {
                got[k] += 1
            }
            if let big = parts.indices.max(by: { parts[$0].exact < parts[$1].exact }) {
                for k in parts.indices where k != big && got[k] < minPiece { got[big] += got[k]; got[k] = 0 }
            }
            for (k, p) in parts.enumerated() where got[k] > 0 { units[p.i, default: [:]][task, default: 0] += got[k] }
        }

        var free = subtract([Interval(up(day.start), down(day.end))], busy.map { Interval(down($0.start), up($0.end)) })
        var entries: [Entry] = []
        var overflow: [(task: Int, seconds: Double, anchor: Timestamp)] = []
        for i in order {
            guard let us = units[i] else { continue }
            let st = stretches[i]
            let window = Interval(down(st.interval.start), up(st.interval.end))
            let firsts = Dictionary(st.shares.map { ($0.task, $0.first) }, uniquingKeysWith: min)
            for task in us.keys.sorted(by: { (firsts[$0] ?? 0, $0) < (firsts[$1] ?? 0, $1) }) {
                var left = Double(us[task]!) * step
                let from = min(max(window.start, down(firsts[task] ?? window.start)), window.end)
                // From the task's first activity to the stretch end, then the stretch's free time before it.
                for (lo, hi) in [(from, window.end), (window.start, from)] where hi > lo {
                    for f in free where left > 0 && f.end > lo && f.start < hi {
                        let a = max(f.start, lo), len = min(min(f.end, hi) - a, left)
                        guard len > 0 else { continue }
                        entries.append(Entry(task: task, start: a, end: a + len)); left -= len
                    }
                }
                for e in entries where e.task == task { cut(&free, Interval(e.start, e.end)) }
                if left > 0 { overflow.append((task, left, window.end)) }
            }
        }
        var unplaced: [Int: Int] = [:]
        for o in overflow {
            var left = o.seconds
            while left > 0, let k = free.indices.min(by: { distance(free[$0], o.anchor) < distance(free[$1], o.anchor) }) {
                let f = free[k]
                let piece: Interval
                if f.end <= o.anchor { piece = Interval(f.end - min(f.length, left), f.end) }
                else { let a = max(f.start, o.anchor); piece = Interval(a, a + min(f.end - a, left)) }
                entries.append(Entry(task: o.task, start: piece.start, end: piece.end)); left -= piece.length
                cut(&free, piece)
            }
            if left > 0 { unplaced[o.task, default: 0] += Int(left) }
        }
        return Output(entries: merged(entries), unplaced: unplaced)
    }

    static func up(_ t: Timestamp) -> Timestamp { (t / step).rounded(.up) * step }
    static func down(_ t: Timestamp) -> Timestamp { (t / step).rounded(.down) * step }

    static func distance(_ f: Interval, _ t: Timestamp) -> Double { t < f.start ? f.start - t : t > f.end ? t - f.end : 0 }

    /// `xs` minus the union of `ys`.
    static func subtract(_ xs: [Interval], _ ys: [Interval]) -> [Interval] {
        var out = Intervals.merge(xs)
        for y in Intervals.merge(ys) { cut(&out, y) }
        return out
    }

    static func cut(_ xs: inout [Interval], _ y: Interval) {
        xs = xs.flatMap { x -> [Interval] in
            guard y.start < x.end && y.end > x.start else { return [x] }
            return [Interval(x.start, y.start), Interval(y.end, x.end)].filter { $0.end > $0.start }
        }
    }

    /// Adjacent pieces of one task joined, sorted by start.
    static func merged(_ es: [Entry]) -> [Entry] {
        var out: [Entry] = []
        for e in es.sorted(by: { $0.start < $1.start }) {
            if let l = out.last, l.task == e.task, l.end == e.start { out[out.count - 1].end = e.end } else { out.append(e) }
        }
        return out
    }
}
