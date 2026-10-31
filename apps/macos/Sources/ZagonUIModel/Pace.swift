import Foundation

/// One limit reading of the current window.
public struct LimitPoint: Sendable, Equatable {
    public var at: Date
    public var pct: Double
    public init(_ at: Date, _ pct: Double) { self.at = at; self.pct = pct }
}

public enum LimitKind: String, CaseIterable, Sendable { case fiveHour, week }

/// "Pace" view of one limit window: usage against the share of the window that has passed. The diagonal is an even
/// pace; a line above it means spending faster than time.
public struct PaceVM: Sendable, Equatable {
    public struct Point: Sendable, Equatable { public var x: Double; public var y: Double }
    public var title: String
    public var color: UInt32
    /// x = share of the window passed, y = share used, both 0…1, oldest first, ending at "now".
    public var points: [Point]
    public var now: Point
    /// "+12% ahead of time" / "8% behind time" / "on time".
    public var verdict: String
    public var ahead: Bool

    /// `weekdaysOnly`: Saturdays and Sundays do not count as passing time (for a work-week pace).
    public init(title: String, window: LimitWindow, minutes: Double, history: [LimitPoint], base: UInt32,
                weekdaysOnly: Bool = false, f: Fmt) {
        self.title = title
        // The last reading is from a window that has ended: nothing to compare until a new one (RingVM shows "–").
        guard window.resetsAt > f.now else {
            points = [Point(x: 0, y: 0)]; now = Point(x: 0, y: 0); verdict = ""; ahead = false; color = base
            return
        }
        let end = window.resetsAt, start = end.addingTimeInterval(-minutes * 60)
        func x(_ t: Date) -> Double {
            PaceVM.fraction(of: min(max(t, start), end), from: start, to: end, weekdaysOnly: weekdaysOnly, f.calendar)
        }
        let past = history.filter { $0.at >= start && $0.at <= f.now }.sorted { $0.at < $1.at }
        let current = Point(x: x(f.now), y: min(max(window.usedPct / 100, 0), 1))
        points = [Point(x: 0, y: 0)] + past.map { Point(x: x($0.at), y: min(max($0.pct / 100, 0), 1)) } + [current]
        now = current
        let d = Int(((current.y - current.x) * 100).rounded())
        ahead = d > 0
        color = d >= 10 || window.usedPct >= 95 ? Palette.waiting : base
        verdict = d > 2 ? f.t("pace.ahead", f.pct(Double(d))) : d < -2 ? f.t("pace.behind", f.pct(Double(-d))) : f.t("pace.even")
    }

    /// Both windows of the provider's limits, for the pace view.
    public static func both(_ p: any ZagonDataProvider, weekdaysOnly: Bool, _ f: Fmt) -> (five: PaceVM?, week: PaceVM?) {
        let l = p.limits().forRings(at: f.now)
        return (l.fiveHour.map { PaceVM(title: f.t("limit.five"), window: $0, minutes: 300, history: p.limitHistory(.fiveHour),
                                        base: Palette.fiveHour, f: f) },
                l.week.map { PaceVM(title: f.t("limit.week"), window: $0, minutes: 10080, history: p.limitHistory(.week),
                                    base: Palette.week, weekdaysOnly: weekdaysOnly, f: f) })
    }

    /// Share of [from, to] passed at `t`; with `weekdaysOnly` only Monday–Friday time counts.
    public static func fraction(of t: Date, from: Date, to: Date, weekdaysOnly: Bool, _ cal: Calendar) -> Double {
        let total = seconds(from, to, weekdaysOnly, cal)
        return total > 0 ? min(max(seconds(from, t, weekdaysOnly, cal) / total, 0), 1) : 0
    }

    static func seconds(_ a: Date, _ b: Date, _ weekdaysOnly: Bool, _ cal: Calendar) -> Double {
        guard weekdaysOnly else { return max(0, b.timeIntervalSince(a)) }
        var t = a, sum = 0.0
        while t < b {
            let next = min(b, cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: t))!)
            if !cal.isDateInWeekend(t) { sum += next.timeIntervalSince(t) }
            t = next
        }
        return sum
    }
}
