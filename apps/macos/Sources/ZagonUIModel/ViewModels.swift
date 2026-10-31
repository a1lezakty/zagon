import Foundation
import ZagonCore

// One value type per screen: everything a view shows, already formatted and laid out (fractions 0…1).
// Views stay dumb; these are tested on Linux.

public struct Stat: Sendable, Equatable {
    public var value: String
    public var label: String
    public var delta: String?
    /// Whether the delta is good news (green) or bad (red); nil = neutral.
    public var good: Bool?
    public init(_ value: String, _ label: String, delta: String? = nil, good: Bool? = nil) {
        self.value = value; self.label = label; self.delta = delta; self.good = good
    }
}

/// Sentence with one emphasised fragment.
public struct Emphasis: Sendable, Equatable {
    public var before: String
    public var bold: String
    public var after: String
    public var plain: String { before + bold + after }
    public init(before: String, bold: String = "", after: String = "") {
        self.before = before; self.bold = bold; self.after = after
    }
}

/// A coloured dot + text line (notes, checks).
public struct Note: Sendable, Equatable {
    public var color: UInt32
    public var text: String
}

// MARK: - Menu bar

public struct RingVM: Sendable, Equatable {
    public var title: String
    /// Used percent; nil = not known: no reading, or the last one is older than its reset (the window started over).
    public var pct: Int?
    public var fraction: Double
    public var color: UInt32
    public var resetLine: String
    public var inLine: String
    /// The other way to show it (a click on the limits): what is left and the time until the reset.
    public var leftPct: Int?
    public var leftLine: String
    /// What VoiceOver reads for the ring and its lines, in either way of showing it.
    public var spoken: String
    public var spokenLeft: String

    init(title: String, window: LimitWindow, base: UInt32, f: Fmt) {
        self.title = title
        // The last reading is older than its reset: the window has started over, usage is unknown until a new one.
        let stale = window.resetsAt <= f.now
        pct = stale ? nil : Int(window.usedPct.rounded())
        fraction = stale ? 0 : min(max(window.usedPct / 100, 0), 1)
        color = !stale && window.usedPct >= 95 ? Palette.waiting : base
        resetLine = f.t(stale ? "limit.wasReset" : "limit.resets", f.resetMoment(window.resetsAt))
        inLine = stale ? f.t("limit.noReading") : f.t("limit.in", f.duration(window.resetsAt.timeIntervalSince(f.now)))
        leftPct = pct.map { 100 - $0 }
        leftLine = f.t("limit.left")
        spoken = ""; spokenLeft = ""
        speak(f)
    }

    /// A window with no reading at all.
    public static func empty(_ title: String, _ f: Fmt) -> RingVM { RingVM(title: title, f: f) }

    private init(title: String, f: Fmt) {
        self.title = title
        fraction = 0
        color = Palette.track
        resetLine = f.t("limit.noData")
        inLine = ""
        leftLine = resetLine
        spoken = ""; spokenLeft = ""
        speak(f)
    }

    private mutating func speak(_ f: Fmt) {
        let lines = [resetLine, inLine].filter { !$0.isEmpty }.joined(separator: ", ")
        guard let pct, let leftPct else { spoken = title + ": " + lines; spokenLeft = spoken; return }
        spoken = title + ": " + f.t("limit.usedPct", f.pct(Double(pct))) + ", " + lines
        spokenLeft = title + ": " + f.t("limit.leftPct", f.pct(Double(leftPct))) + ", " + inLine
    }
}

/// One AI in the panel when both have a current reading: a ring in a ring, the week outside, 5 hours inside.
public struct AIRingsVM: Sendable, Equatable {
    public var tool: Tool
    public var five: RingVM
    public var week: RingVM
    /// "5h until 14:20" and "week 35%" (what is left of it, `weekLeftLine`, when the panel shows what is left).
    public var fiveLine: String
    public var weekLine: String
    public var weekLeftLine: String
    public var spoken: String
    public var spokenLeft: String

    init(_ tool: Tool, _ l: AILimits, _ c: RingColors, _ f: Fmt) {
        self.tool = tool
        five = l.fiveHour.map { RingVM(title: f.t("limit.five"), window: $0, base: c.five, f: f) } ?? .empty(f.t("limit.five"), f)
        week = l.week.map { RingVM(title: f.t("limit.week"), window: $0, base: c.week, f: f) } ?? .empty(f.t("limit.week"), f)
        let known = five.pct != nil
        fiveLine = l.fiveHour.flatMap { known ? f.t("limit.ai.five", f.time($0.resetsAt)) : nil } ?? f.t("limit.ai.fiveNone")
        weekLine = f.t("limit.ai.week", week.pct.map { f.pct(Double($0)) } ?? "–")
        weekLeftLine = f.t("limit.ai.week", week.leftPct.map { f.pct(Double($0)) } ?? "–")
        spoken = tool.name + ": " + five.spoken + "; " + week.spoken
        spokenLeft = tool.name + ": " + five.spokenLeft + "; " + week.spokenLeft
    }
}

public struct SessionRowVM: Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var time: String
    public var command: String
}

public struct MainVM: Sendable {
    /// One AI (or none with a current reading): its pair of rings.
    public var five: RingVM?
    public var week: RingVM?
    /// Both AIs with a current reading: a ring in a ring each, Claude first; then `five` and `week` serve the pace view.
    public var ais: [AIRingsVM]
    /// The pace view follows Claude's windows (Codex's without them): it stands in for the rings only when they are that
    /// AI's, not Codex's next to Claude's old history.
    public var paceFits: Bool
    public var forecast: Emphasis?
    public var waitingHeader: String
    public var waiting: [SessionRowVM]
    public var workingHeader: String
    public var working: [SessionRowVM]
    public var idleHeader: String
    public var idleButton: String?
    public var idleHideButton: String?
    public var idle: [SessionRowVM]
    public var totals: [Stat]
    /// Under the price: "Claude $X", "Codex $Y" when both spent something today; else empty.
    public var costSplit: [String]
    /// Above the rings: whose limits they are, and how old the reading is once that is over 15 minutes.
    public var limitsHeader: String
    /// Over the rings-in-rings when they show what is left.
    public var limitsHeaderLeft: String
    public var limitsAge: String?
    /// A window has no current reading: the panel says when one comes.
    public var limitsMissing: Bool
    /// No sessions at all: one line instead of an empty block.
    public var noSessions: String?

    public init(_ p: ZagonDataProvider, _ f: Fmt, colors: (Tool) -> RingColors = RingColors.standard) {
        let limits = p.limits(), current = limits.tools(at: f.now), shown = limits.shown(at: f.now)
        let oneTool = current.first ?? (shown.fiveHour ?? shown.week)?.tool ?? .claude, one = colors(oneTool)
        five = shown.fiveHour.map { RingVM(title: f.t("limit.five"), window: $0, base: one.five, f: f) }
        week = shown.week.map { RingVM(title: f.t("limit.week"), window: $0, base: one.week, f: f) }
        let ais = current.count > 1 ? current.map { AIRingsVM($0, limits[$0], colors($0), f) } : []
        self.ais = ais
        paceFits = ais.isEmpty && oneTool == ((limits.fiveHour ?? limits.week)?.tool ?? .claude)
        forecast = ais.isEmpty ? shown.fiveHour.flatMap { MainVM.forecast($0, f) } : ais.lazy.compactMap { a in
            limits[a.tool].fiveHour.flatMap { MainVM.forecast($0, f) }
                .map { Emphasis(before: a.tool.name + ": " + $0.before, bold: $0.bold, after: $0.after) }
        }.first

        let sessions = p.liveSessions().sorted { $0.since < $1.since }
        func row(_ s: LiveSession, _ detail: String) -> SessionRowVM {
            SessionRowVM(id: s.id, title: s.title, subtitle: s.host + " · " + detail,
                         time: f.duration(f.now.timeIntervalSince(s.since)), command: s.command)
        }
        // A worker driven by another session waits for that session, not for you: listed with the idle ones.
        func driven(_ s: LiveSession) -> Bool { s.status == .waitingInput && s.drivenBy != nil }
        waiting = sessions.compactMap {
            switch $0.status {
            case .waitingPermission: return row($0, f.t("status.permission"))
            case .waitingInput where !driven($0): return row($0, f.t("status.input"))
            default: return nil
            }
        }
        working = sessions.filter { $0.status == .working }.map { row($0, $0.model) }
        idle = sessions.compactMap {
            if driven($0), let d = $0.drivenBy {
                return row($0, d.isEmpty ? f.t("status.otherSession") : f.t("status.session", d))
            }
            return $0.status == .idle ? row($0, $0.model) : nil
        }
        waitingHeader = f.t("sessions.waiting", String(waiting.count)).uppercased()
        workingHeader = f.t("sessions.working", String(working.count)).uppercased()
        idleHeader = f.t("sessions.idle", String(idle.count)).uppercased()
        idleButton = idle.isEmpty ? nil : f.t("sessions.idle.show", String(idle.count))
        idleHideButton = idle.isEmpty ? nil : f.t("sessions.idle.hide", String(idle.count))

        let today = p.todayTotals()
        totals = [Stat(f.duration(today.sessionSec), f.t("stat.sessionsWorked")),
                  Stat(f.tokens(today.tokens), f.t("stat.tokensToday")),
                  Stat(f.cost(today.cost), f.t("stat.apiPrices"))]
        let split = Tool.allCases.compactMap { t in
            today.costByTool[t].flatMap { $0 > 0 ? t.name + " " + f.cost($0) : nil }
        }
        costSplit = split.count == 2 ? split : []

        let windows = [shown.fiveHour, shown.week].compactMap { $0 }
        let tools = Tool.allCases.filter { t in windows.contains { $0.tool == t } }
        limitsHeader = (tools.isEmpty || !ais.isEmpty ? f.t("limit.header.none")
            : f.t("limit.header", tools.map(\.name).joined(separator: " · "))).uppercased()
        limitsHeaderLeft = f.t("limit.header.left").uppercased()
        // A reading over 15 minutes old says so; with both AIs each says its own: "Claude 20m · Codex 6h ago".
        func age(_ ws: [LimitWindow?]) -> Double? {
            ws.compactMap { $0?.readAt }.max().map { f.now.timeIntervalSince($0) }.flatMap { $0 > 900 ? $0 : nil }
        }
        if ais.isEmpty {
            limitsAge = age(windows).map { f.t("limit.updated", f.duration($0)) }
        } else {
            let each = ais.compactMap { a in age([limits[a.tool].fiveHour, limits[a.tool].week]).map { a.tool.name + " " + f.duration($0) } }
            limitsAge = each.isEmpty ? nil : f.t("limit.updatedEach", each.joined(separator: " · "))
        }
        limitsMissing = ais.isEmpty ? five?.pct == nil || week?.pct == nil : ais.contains { $0.five.pct == nil || $0.week.pct == nil }
        noSessions = sessions.isEmpty ? f.t("sessions.none") : nil
    }

    /// Warn only when the current pace hits 100 % before the reset.
    static func forecast(_ w: LimitWindow, _ f: Fmt) -> Emphasis? {
        guard let rate = w.pctPerHour, rate > 0, w.usedPct < 100 else { return nil }
        let hit = f.now.addingTimeInterval((100 - w.usedPct) / rate * 3600)
        guard hit < w.resetsAt else { return nil }
        let parts = f.t.split("forecast.five", f.duration(w.resetsAt.timeIntervalSince(hit)))
        return Emphasis(before: parts.before, bold: f.t("at.time", f.time(hit)), after: parts.after)
    }
}

// MARK: - Day

public struct SegmentVM: Sendable, Equatable {
    public var x: Double
    public var width: Double
    public var waiting: Bool
}

public struct LaneVM: Sendable, Equatable {
    public var title: String
    public var host: String
    public var segments: [SegmentVM]
}

public struct TimelineVM: Sendable, Equatable {
    public var fromHour: Int
    public var toHour: Int
    /// Evenly spaced labels from `fromHour` to `toHour`.
    public var ticks: [String]
    public var lanes: [LaneVM]

    public init(day: Date, lanes: [Lane], f: Fmt) {
        let start = f.startOfDay(day)
        func h(_ d: Date) -> Double { d.timeIntervalSince(start) / 3600 }  // ponytail: ±1 h on DST days
        let starts = lanes.flatMap { $0.intervals.map { max(0, h($0.start)) } }
        let from = min(8, Int(starts.min() ?? 8) / 2 * 2)
        fromHour = from
        toHour = 24
        let span = Double(24 - from)
        ticks = stride(from: from, through: 24, by: 2).map { f.pad2($0) }
        self.lanes = lanes.map { lane in
            LaneVM(title: lane.title, host: lane.host, segments: lane.intervals.compactMap { iv in
                let a = min(max(h(iv.start), Double(from)), 24), b = min(max(h(iv.end), Double(from)), 24)
                guard b > a else { return nil }
                return SegmentVM(x: (a - Double(from)) / span, width: (b - a) / span, waiting: iv.waiting)
            })
        }
    }
}

public struct UsageRowVM: Sendable, Equatable {
    public var name: String
    public var tokens: String
    public var cost: String
    /// Share of the day's tokens, 0…1.
    public var share: Double
    public var color: UInt32
}

public struct DayVM: Sendable {
    public var title: String
    public var stats: [Stat]
    public var limitNotes: [Note]
    public var timeline: TimelineVM
    public var longestWait: String?
    public var summaryNote: String?
    public var isEmpty: Bool
    /// "What was done": the written summary as cards, or without one the day's projects from this Mac's data.
    public var summary: SummaryVM?
    public var projects: [DoneProjectVM]
    /// "Not in the summary: …" and the day's projects of the machines a summary made elsewhere leaves out.
    public var leftOutNote: String?
    public var leftOut: [DoneProjectVM] = []
    let data: DayData
    let f: Fmt

    public init(_ d: DayData, _ f: Fmt) {
        data = d; self.f = f
        title = f.dayTitle(d.day)
        stats = [Stat(f.duration(d.totals.sessionSec), f.t("stat.sessionsWorked")),
                 Stat(f.duration(d.totals.userSec), f.t("stat.you")),
                 Stat(f.tokens(d.totals.tokens), f.t("stat.tokens")),
                 Stat(f.cost(d.totals.cost), f.t("stat.apiPrices"))]
        var notes: [Note] = []
        if !d.limitHits.isEmpty {
            notes.append(Note(color: Palette.fiveHour, text: f.t.plural(
                "day.limitHits", d.limitHits.count, d.limitHits.map { f.timeSpan($0.start, $0.end) }.joined(separator: ", "))))
        }
        // b < a: the weekly window reset during the day, the day's share is unknown.
        if let a = d.weekPctStart, let b = d.weekPctEnd, b >= a {
            notes.append(Note(color: Palette.week, text: f.t("day.weekDelta", "+" + f.pct(b - a), String(Int(a.rounded())),
                                                             f.pct(b))))
        }
        limitNotes = notes
        timeline = TimelineVM(day: d.day, lanes: d.lanes, f: f)
        let waits = d.lanes.flatMap { lane in lane.intervals.filter(\.waiting).map { (lane.title, $0) } }
        if let w = waits.max(by: { $0.1.end.timeIntervalSince($0.1.start) < $1.1.end.timeIntervalSince($1.1.start) }) {
            longestWait = f.t("day.longestWait", w.0, f.duration(w.1.end.timeIntervalSince(w.1.start)), f.time(w.1.start),
                              f.time(w.1.end))
        }
        let doc = d.doc, sources = d.summaryInfo?.sources ?? []
        summary = d.summaryInfo.flatMap { s in
            doc.map { SummaryVM(KeptSummary(doc: $0, engine: s.engine, at: s.at), period: false, sources: sources, f) }
        }
        summaryNote = d.summaryInfo.flatMap { s in
            s.weekPct.map { f.t("day.summaryNote", SummaryVM.engineName(s.engine), f.time(s.at), f.decimal($0, digits: 1))
                + (SummaryVM.source(sources, f).map { " " + $0 } ?? "") }
        } ?? summary?.note
        projects = d.projects.enumerated().map { DoneProjectVM($1, index: $0, f) }
        // A summary from one machine says nothing of the sessions on the others (one that does not say: all of them).
        let left = summary == nil || sources.isEmpty ? [] : d.hostProjects.keys.filter { !sources.contains($0) }.sorted()
        if !left.isEmpty {
            leftOutNote = f.t("sum.leftOut", left.joined(separator: ", "))
            leftOut = left.flatMap { d.hostProjects[$0] ?? [] }.enumerated().map { DoneProjectVM($1, index: $0, f) }
        }
        isEmpty = d.lanes.isEmpty && d.totals.sessionSec == 0 && d.totals.tokens == 0
    }

    public func dimensionTitle(_ d: UsageDimension) -> String { f.t("dim.\(d.rawValue)") }

    public func usage(_ dim: UsageDimension) -> [UsageRowVM] {
        // At most five lines: the top four and the rest as "other".
        var rows = data.usage[dim] ?? []
        if rows.count > 5 {
            let rest = rows[4...]
            rows = Array(rows[..<4]) + [UsageRow("", tokens: rest.reduce(0) { $0 + $1.tokens }, cost: rest.reduce(0) { $0 + $1.cost })]
        }
        let total = Double(max(1, rows.reduce(0) { $0 + $1.tokens }))
        // Tools carry call counts (tokens are not split by tool) and no price.
        return rows.enumerated().map { i, r in
            UsageRowVM(name: name(r.name, dim), tokens: dim == .tool ? f.t.plural("usage.calls", r.tokens) : f.tokens(r.tokens),
                       cost: dim == .tool ? "" : f.cost(r.cost),
                       share: Double(r.tokens) / total, color: r.name.isEmpty ? Palette.muted : Palette.series(i))
        }
    }

    func name(_ n: String, _ dim: UsageDimension) -> String {
        n.isEmpty ? f.t(dim == .agent ? "usage.mainThread" : "other") : n
    }

    public var hasSummary: Bool { summary != nil }

    /// The day as Markdown, for worklogs and notes.
    public var markdown: String {
        var out = "# \(title)\n\n" + stats.map { "- \($0.label): \($0.value)" }.joined(separator: "\n") + "\n"
        for n in limitNotes { out += "- \(n.text)\n" }
        func list(_ ps: [DoneProjectVM]) -> String {
            ps.map { p in "### \(p.name) — \(p.numbers)\n\n" + p.sessions.map { "- " + $0 }.joined(separator: "\n") }
                .joined(separator: "\n\n") + "\n"
        }
        if let s = summary {
            out += "\n## \(f.t("day.done"))\n\n" + s.markdown + "\n"
            if let n = leftOutNote { out += "\n" + n + "\n\n" + list(leftOut) }
        } else if !projects.isEmpty {
            out += "\n## \(f.t("day.done"))\n\n" + list(projects)
        }
        return out
    }
}

// MARK: - Week

public enum WeekMetric: String, CaseIterable, Sendable { case hours, tokens, cost }

public struct WeekPartVM: Sendable, Equatable {
    public var project: String
    public var value: Double
    public var color: UInt32
}

public struct WeekDayVM: Sendable, Equatable {
    public var label: String
    public var isToday: Bool
    public var total: String
    public var value: Double
    public var parts: [WeekPartVM]
}

public struct LimitDayVM: Sendable, Equatable {
    public var day: String
    public var pct: Double?
    public var text: String
}

public struct ProjectRowVM: Sendable, Equatable {
    public var name: String
    public var color: UInt32
    public var hours: String
    public var cost: String
    public var delta: String
    public var good: Bool
}

public struct WeekVM: Sendable {
    public var title: String
    public var stats: [Stat]
    public var legend: [(name: String, color: UInt32)]
    public var limit: [LimitDayVM]
    public var limitForecast: Emphasis?
    public var projects: [ProjectRowVM]
    let data: WeekData
    let f: Fmt

    public init(_ w: WeekData, weekLimit: LimitWindow?, _ f: Fmt) {
        data = w; self.f = f
        title = f.weekTitle(w.start)
        let c = w.totals, p = w.previous
        stats = [Stat(f.duration(c.sessionSec), f.t("stat.sessionsWorked"),
                      delta: f.t("week.vsLast", f.delta(c.sessionSec, p.sessionSec)), good: c.sessionSec >= p.sessionSec),
                 Stat(f.duration(c.userSec), f.t("stat.you"), delta: f.delta(c.userSec, p.userSec), good: c.userSec >= p.userSec),
                 Stat(f.tokens(c.tokens), f.t("stat.tokens"), delta: f.delta(Double(c.tokens), Double(p.tokens)),
                      good: c.tokens <= p.tokens),
                 Stat(f.cost(c.cost), f.t("stat.apiPrices"), delta: f.delta(c.cost, p.cost), good: c.cost <= p.cost)]
        legend = w.projects.enumerated().map { (f.t.nonEmpty($1, "other"), Palette.series($0)) }
        limit = w.limitByDay.enumerated().map { i, v in
            LimitDayVM(day: f.weekday(f.addDays(i, to: w.start)), pct: v, text: v.map { "\(Int($0.rounded()))%" } ?? "")
        }
        projects = w.projectRows.enumerated().map { i, r in
            ProjectRowVM(name: f.t.nonEmpty(r.name, "other"), color: Palette.series(i), hours: f.duration(r.sec),
                         cost: f.cost(r.cost), delta: r.prevSec.map { f.delta(r.sec, $0) } ?? f.t("delta.new"),
                         good: r.prevSec.map { r.sec >= $0 } ?? true)
        }
        let end = f.addDays(7, to: w.start)
        limitForecast = weekLimit.flatMap { f.now >= w.start && f.now < end ? WeekVM.forecast($0, w, f) : nil }
    }

    public func metricTitle(_ m: WeekMetric) -> String { f.t("metric.\(m.rawValue)") }

    public func chartTitle(_ m: WeekMetric) -> String { f.t("week.chart.\(m.rawValue)") }

    public func days(_ m: WeekMetric) -> [WeekDayVM] {
        (0..<7).map { i in
            let day = f.addDays(i, to: data.start)
            let parts = i < data.days.count ? data.days[i] : []
            let today = f.calendar.isDate(day, inSameDayAs: f.now)
            let vals = parts.enumerated().map { j, t in
                WeekPartVM(project: f.t.nonEmpty(j < data.projects.count ? data.projects[j] : "", "other"),
                           value: value(t, m), color: Palette.series(j))
            }.filter { $0.value > 0 }
            let sum = vals.reduce(0) { $0 + $1.value }
            let total: String
            switch m {
            case .hours: total = sum > 0 ? f.duration(sum * 3600) : "—"
            case .tokens: total = sum > 0 ? f.tokens(Int(sum)) : "—"
            case .cost: total = sum > 0 ? f.cost(sum) : "—"
            }
            return WeekDayVM(label: f.weekdayDay(day) + (today ? " · " + f.t("today").lowercased() : ""),
                             isToday: today, total: total, value: sum, parts: vals)
        }
    }

    func value(_ t: Totals, _ m: WeekMetric) -> Double {
        switch m {
        case .hours: t.sessionSec / 3600
        case .tokens: Double(t.tokens)
        case .cost: t.cost
        }
    }

    /// Linear pace since the 7-day window opened (reset minus a week), projected to the reset.
    static func forecast(_ lim: LimitWindow, _ w: WeekData, _ f: Fmt) -> Emphasis? {
        guard lim.resetsAt > f.now else { return nil }  // a reading from before the reset: the window is new
        let elapsedDays = 7 - lim.resetsAt.timeIntervalSince(f.now) / 86400
        guard elapsedDays > 0.1, lim.usedPct > 0 else { return nil }
        let perDay = lim.usedPct / elapsedDays
        let leftDays = max(0, lim.resetsAt.timeIntervalSince(f.now) / 86400)
        let projected = lim.usedPct + perDay * leftDays
        if projected >= 100 {
            let hit = f.now.addingTimeInterval((100 - lim.usedPct) / perDay * 86400)
            let p = f.t.split("forecast.week.out", f.resetMoment(lim.resetsAt))
            return Emphasis(before: p.before, bold: f.resetMoment(hit), after: p.after)
        }
        let p = f.t.split("forecast.week", f.resetMoment(lim.resetsAt))
        var after = p.after
        // Headroom in units of the busiest day so far. Only days ending after the window opened count (it need not
        // open on Monday); the window starts from zero.
        let opened = lim.resetsAt.addingTimeInterval(-7 * 86400)
        var prev = 0.0, best: (delta: Double, day: Int)?
        for (i, v) in w.limitByDay.enumerated() {
            guard let v, f.addDays(i + 1, to: w.start) > opened else { continue }
            if v - prev > (best?.delta ?? 0) { best = (v - prev, i) }
            prev = v
        }
        if let best, case let n = Int((100 - projected) / best.delta), n >= 1 {
            after += " " + f.t.plural("forecast.headroom", n, f.weekdayName(f.addDays(best.day, to: w.start)))
        }
        return Emphasis(before: p.before, bold: f.pct(projected), after: after)
    }
}

// MARK: - Calendar

public struct CalendarCellVM: Sendable, Equatable {
    public var day: Int
    public var date: Date
    public var hours: String
    public var level: Int
    public var selected: Bool
    public var today: Bool
    public var future: Bool
}

public struct DayCardVM: Sendable {
    public var title: String
    public var stats: [Stat]
    public var bullets: [String]
}

public struct SearchHitVM: Sendable, Equatable {
    public var title: String
    public var meta: String
    public var command: String
}

public struct CalendarVM: Sendable {
    public var title: String
    public var weekdays: [String]
    /// Monday-first grid; nil = blank cell outside the month.
    public var cells: [CalendarCellVM?]
    public var footer: [String]

    public init(_ m: MonthData, selected: Date, _ f: Fmt) {
        title = f.monthTitle(m.month)
        let monday = f.startOfWeek(m.month)
        weekdays = (0..<7).map { f.weekday(f.addDays($0, to: monday)) }
        let lead = f.calendar.dateComponents([.day], from: monday, to: m.month).day ?? 0
        var cells: [CalendarCellVM?] = Array(repeating: nil, count: lead)
        for (i, h) in m.hours.enumerated() {
            let date = f.addDays(i, to: m.month)
            cells.append(CalendarCellVM(day: i + 1, date: date, hours: h.map(f.hours) ?? "", level: CalendarVM.level(h),
                                        selected: f.calendar.isDate(date, inSameDayAs: selected),
                                        today: f.calendar.isDate(date, inSameDayAs: f.now), future: h == nil))
        }
        cells += Array(repeating: nil, count: (7 - cells.count % 7) % 7)
        self.cells = cells
        footer = [f.t("cal.kept")] + (m.archiveSince.map { [f.t("cal.archive", f.dayMonth($0))] } ?? [])
            + [f.t("cal.claudeDeletes")]
    }

    /// Heat level 0…5 by hours worked.
    public static func level(_ h: Double?) -> Int {
        guard let h, h > 0 else { return 0 }
        return h < 2 ? 1 : h < 4.5 ? 2 : h < 7 ? 3 : h < 9 ? 4 : 5
    }

    public static func card(_ d: DayData, _ f: Fmt) -> DayCardVM {
        DayCardVM(title: f.dayTitle(d.day),
                  stats: [Stat(f.duration(d.totals.sessionSec), f.t("cal.work")), Stat(f.tokens(d.totals.tokens), f.t("stat.tokens")),
                          Stat(f.cost(d.totals.cost), f.t("cal.byApi"))],
                  bullets: d.doc.map { $0.items.prefix(3).map { ($0.project.isEmpty ? "" : $0.project + ": ") + $0.heading } }
                      ?? d.projects.prefix(3).map { f.t.nonEmpty($0.name, "other") + ": " + $0.sessions.prefix(2).map(\.title).joined(separator: "; ") })
    }

    public static func hits(_ hits: [SearchHit], _ f: Fmt) -> [SearchHitVM] {
        hits.map {
            SearchHitVM(title: $0.title, meta: [$0.host, f.shortDay($0.start) + " " + f.timeSpan($0.start, $0.end), $0.model]
                .joined(separator: " · "), command: $0.command)
        }
    }
}

// MARK: - Tasks

/// The main list by status, then `jira`: open Jira issues with no work here in the last 7 days (done ones are not shown).
public enum TaskFilter: String, CaseIterable, Sendable {
    case active, review, planned, done, jira
    func matches(_ t: TaskItem) -> Bool {
        switch self {
        case .active: t.worked && t.state == .active
        case .review: t.worked && t.state == .review
        case .planned: t.worked && t.state == .planned
        case .done: t.worked && t.state == .done
        case .jira: !t.worked && t.state != .done
        }
    }
}

public struct TaskRowVM: Sendable, Identifiable, Equatable {
    public var id: String { key }
    public var key: String
    public var title: String
    public var status: String
    public var state: TaskState
    public var time: String
    public var sessions: String
    public var sync: String
}

public struct TaskSessionVM: Sendable, Equatable {
    public var tool: String
    public var codex: Bool
    public var title: String
    public var meta: String
    public var time: String
}

public struct TaskDetailVM: Sendable {
    public var key: String
    public var status: String
    public var state: TaskState
    public var hasJira: Bool
    public var title: String
    public var description: String
    public var stats: [Stat]
    public var jiraLines: [Note]
    public var todo: [TodoItem]
    public var done: [(day: String, text: String)]
    public var sessions: [TaskSessionVM]
    public var notes: [String]
}

public struct TasksVM: Sendable {
    public var filters: [(filter: TaskFilter, label: String)]
    public var rows: [TaskRowVM]
    let tasks: [TaskItem]
    let cards: [String: TaskItem]
    let f: Fmt

    /// `cards`: full cards by key for the detail (the list's own lines may carry less, e.g. only the last 7 days).
    public init(_ tasks: [TaskItem], filter: TaskFilter, _ f: Fmt, cards: [String: TaskItem] = [:]) {
        self.tasks = tasks; self.cards = cards; self.f = f
        // Empty "In review" and "More in Jira" are left out (most Jiras have no review here, not every source has Jira).
        filters = TaskFilter.allCases.map { fl in (fl, tasks.filter { fl.matches($0) }.count) }
            .filter { $0.1 > 0 || ![.review, .jira].contains($0.0) || $0.0 == filter }
            .map { ($0.0, f.t("filter.\($0.0.rawValue)", String($0.1))) }
        rows = tasks.filter { filter.matches($0) }.map { t in
            TaskRowVM(key: t.key, title: t.title, status: TasksVM.status(t, f), state: t.state, time: f.duration(t.userSec),
                      sessions: f.t.plural("sessions", t.sessionCount),
                      sync: t.jira != nil ? "Jira ✓" : t.jiraKey != nil ? "Jira" : f.t("task.noJira"))
        }
    }

    static func status(_ t: TaskItem, _ f: Fmt) -> String {
        t.jira?.status ?? t.jiraStatus ?? f.t("state.\(t.state)")
    }

    public func detail(_ key: String?) -> TaskDetailVM? {
        guard let line = tasks.first(where: { $0.key == key }) ?? rows.first.flatMap({ r in tasks.first { $0.key == r.key } })
        else { return nil }
        let t = cards[line.key] ?? line
        var jira: [Note] = []
        if let j = t.jira {
            jira.append(j.statusMatches ? Note(color: Palette.working, text: f.t("jira.statusOk", j.status))
                                        : Note(color: Palette.fiveHour, text: f.t("jira.statusDiff", j.status)))
            let missing = t.userSec - j.loggedSec
            jira.append(missing >= 60
                ? Note(color: Palette.fiveHour, text: f.t("jira.unlogged", f.duration(j.loggedSec), f.duration(t.userSec), f.duration(missing)))
                : Note(color: Palette.working, text: f.t("jira.allLogged", f.duration(j.loggedSec))))
        } else if let key = t.jiraKey {
            jira.append(Note(color: Palette.muted, text: t.jiraError.map { f.t("jira.failed", key, $0) } ?? f.t("jira.notAsked", key)))
        } else {
            jira.append(Note(color: Palette.muted, text: f.t("jira.none")))
        }
        return TaskDetailVM(
            key: t.key, status: TasksVM.status(t, f), state: t.state, hasJira: t.jira != nil, title: t.title,
            description: t.description,
            stats: [Stat(f.duration(t.userSec), f.t("task.yourTime")), Stat(f.duration(t.sessionSec), f.t("stat.sessionsWorked")),
                    Stat(f.tokens(t.tokens), f.t("stat.tokens")), Stat(f.pct(t.weekPct), f.t("task.weekShare"))],
            jiraLines: jira, todo: t.todo,
            done: t.doneByDay.map { (f.dayTitleShortWeekday($0.day), $0.text) },
            sessions: t.sessions.map { s in
                let days = f.dayRange(s.first, s.last)
                return TaskSessionVM(tool: s.tool == .codex ? "Codex" : "Claude", codex: s.tool == .codex, title: s.title,
                                     meta: [s.host, s.model, days].joined(separator: " · "), time: f.duration(s.sec))
            },
            notes: t.notes)
    }
}

/// A suggested new task's card: "New task: <title> · 2h 10m", then its day and sessions.
public struct DraftVM: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var meta: String
    /// What the Jira sheet starts from.
    public var name: String
    public var description: String
    public var worked: String
}

// MARK: - Worklog

public struct WorklogSegmentVM: Sendable, Equatable {
    public var x: Double
    public var width: Double
    public var label: String
    public var color: UInt32
    public var logged: Bool
}

public struct WorklogRowVM: Sendable, Equatable {
    public var key: String
    public var span: String
    public var time: String
    public var text: String
    public var destination: String
    public var kind: WorklogDestination
}

public struct WorklogVM: Sendable {
    public var title: String
    public var stats: [Stat]
    public var ticks: [String]
    public var segments: [WorklogSegmentVM]
    public var rows: [WorklogRowVM]
    public var notes: [String]
    /// "Log 2 worklogs to Jira · 1h 00m"; nil when nothing goes to Jira.
    public var commitTitle: String?
    public var copyText: String

    public init(_ w: WorklogData, _ f: Fmt) {
        title = f.t("worklog.title", f.dayTitle(w.day).lowercasedFirstIf(f.lang == .ru))
        let logged = w.rows.filter { $0.destination == .alreadyLogged }
        let toJira = w.rows.filter { $0.destination == .jira }
        let toJiraSec = toJira.reduce(0) { $0 + $1.sec }
        let span = both(w.workStart, w.workEnd).map { ", " + f.timeSpan($0, $1) } ?? ""
        stats = [Stat(f.duration(w.userSec), f.t("worklog.yourTime") + span),
                 Stat(f.duration(w.sessionSec), f.t("worklog.sessions")),
                 Stat(w.jiraSec.map(f.duration) ?? (w.jiraBlocked == nil ? f.duration(logged.reduce(0) { $0 + $1.sec }) : "—"),
                      f.t("worklog.inJira")),
                 Stat(f.duration(toJiraSec), f.t("worklog.suggest"))]

        let starts = w.rows.map(\.start) + [w.workStart].compactMap { $0 }
        let ends = w.rows.map(\.end) + [w.workEnd].compactMap { $0 }
        // The axis starts at the shown midnight before the first row: a plan cut in another zone (the server's) may
        // begin the day before and run past the next midnight.
        let day = f.startOfDay(starts.min() ?? w.day)
        let from = Int((starts.min().map { $0.timeIntervalSince(day) } ?? 9 * 3600) / 3600)
        let to = max(from + 1, Int(ceil((ends.max().map { $0.timeIntervalSince(day) } ?? 18 * 3600) / 3600)))
        ticks = (from...to).map { f.pad2($0 % 24) }
        let keys = w.rows.filter { $0.destination != .alreadyLogged }.map(\.key).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        let span0 = Double(to - from) * 3600, origin = day.addingTimeInterval(Double(from) * 3600)
        segments = w.rows.map { r in
            let isLogged = r.destination == .alreadyLogged
            return WorklogSegmentVM(x: r.start.timeIntervalSince(origin) / span0, width: r.sec / span0,
                                    label: isLogged ? "" : r.sec >= 3600 ? r.key + " · " + f.duration(r.sec)
                                        : String(r.key.prefix { $0 != "-" }),
                                    color: isLogged ? Palette.control : Palette.series(keys.firstIndex(of: r.key) ?? 0),
                                    logged: isLogged)
        }
        rows = w.rows.map { r in
            WorklogRowVM(key: r.key, span: f.timeSpan(r.start, r.end), time: f.duration(r.sec), text: r.text,
                         destination: f.t("dest.\(r.destination)"), kind: r.destination)
        }

        var notes = w.splits.map { s in
            f.t("worklog.split", f.timeSpan(s.start, s.end), f.t.plural("sessions", s.parts.count),
                s.parts.map(\.label).joined(separator: ", "), s.parts.map { f.duration($0.sec) }.joined(separator: " + "))
        }
        let pending = w.rows.filter { $0.destination != .alreadyLogged }
        let clashes = WorklogVM.overlaps(pending, logged: logged)
        if let b = w.jiraBlocked { notes.append(b) }
        notes += clashes.isEmpty ? (w.jiraBlocked == nil ? [f.t("worklog.noOverlap")] : [])
            : clashes.map { f.t("worklog.overlap", $0.key, f.timeSpan($0.start, $0.end)) }
        notes += w.rows.filter { $0.destination == .zagonOnly }.map(\.key).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }.map { f.t("worklog.zagonOnly", $0) }
        notes += w.notes
        self.notes = notes
        commitTitle = toJira.isEmpty || w.jiraBlocked != nil ? nil
            : f.t.plural("worklog.commit", toJira.count, f.duration(toJiraSec))
        copyText = w.rows.filter { $0.destination != .alreadyLogged }
            .map { "\($0.key)\t\(f.timeSpan($0.start, $0.end))\t\(f.duration($0.sec))\t\($0.text)" }.joined(separator: "\n")
    }

    /// Pending rows that intersect a logged row or another pending row (exact duplicates included).
    static func overlaps(_ pending: [WorklogRow], logged: [WorklogRow]) -> [WorklogRow] {
        func meet(_ a: WorklogRow, _ b: WorklogRow) -> Bool { a.start < b.end && b.start < a.end }
        return pending.enumerated().filter { i, r in
            logged.contains { meet($0, r) } || pending.enumerated().contains { j, o in j != i && meet(o, r) }
        }.map(\.element)
    }
}

extension L10n {
    func nonEmpty(_ s: String, _ key: String) -> String { s.isEmpty ? self(key) : s }
}

private func both<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
