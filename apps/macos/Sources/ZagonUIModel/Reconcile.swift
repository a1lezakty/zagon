import Foundation

/// What `zagon log reconcile --json` answers (ZagonCore `Reconcile`): your time in sessions against your Jira worklogs
/// over a range of days, per task and day. Read here as JSON, like the other task answers, so a server's zagon works.
public struct Reconciliation: Decodable, Sendable, Equatable {
    public struct SessionRef: Decodable, Sendable, Equatable {
        public var id: String
        public var title, project, host, tool, branch: String?
        public var sec: Int
    }

    public struct Log: Decodable, Sendable, Equatable {
        public var id: String
        public var start, end: Double
        public var sec: Int
        public var comment: String?
    }

    /// A task, a Jira issue that is no task here, or work with no task in one project and branch; over the range
    /// (`tasks`) or on one day (`days[].rows`, with sessions, worklogs and what was done).
    public struct Row: Decodable, Sendable, Equatable {
        public var taskId: Int?
        public var key, jiraKey, title, project, branch: String?
        public var sessionSec, jiraSec: Int
        public var status: String
        public var done: String?
        public var sessions: [SessionRef]?
        public var worklogs: [Log]?

        /// The same task, issue, or project and branch on every day.
        public var id: String { taskId.map { "t\($0)" } ?? jiraKey.map { "j" + $0 } ?? "-\(project ?? "")|\(branch ?? "")" }
    }

    public struct Day: Decodable, Sendable, Equatable {
        public var day: String
        /// Before `coverageFrom`: not reconciled, Jira time only.
        public var beforeCoverage: Bool
        public var sessionSec, jiraSec: Int
        public var rows: [Row]
    }

    public struct Totals: Decodable, Sendable, Equatable {
        public var sessionSec, jiraSec, unloggedSec, jiraOnlySec, zagonOnlySec, noTaskSec, jiraBeforeCoverageSec: Int
    }

    public var from, to, toRequested: String
    /// First day with whole session history (nil: no sessions at all).
    public var coverageFrom: String?
    public var toleranceMin: Int
    /// `connected` | `not_connected` | `failed`
    public var jira: String
    public var jiraError: String?
    public var totals: Totals
    public var tasks: [Row]
    public var days: [Day]
}

/// How a row compares, in the order the groups are shown.
public enum RecKind: String, CaseIterable, Sendable {
    case onlySessions = "only_sessions", mismatch, onlyJira = "only_jira", match, zagonOnly = "zagon_only", noTask = "no_task"
}

public struct ReconcileVM: Sendable {
    public struct Row: Sendable, Identifiable {
        public var id: String
        public var key: String
        public var title: String
        public var kind: RecKind
        public var sessions: String
        public var jira: String
        /// "+4h 40m" / "−1h 50m"; nil for work that has no Jira side.
        public var diff: String?
        /// 1: time not in Jira, -1: Jira beyond sessions, 0: within the tolerance.
        public var sign: Int
    }

    public struct Group: Sendable, Identifiable {
        public var id: RecKind { kind }
        public var kind: RecKind
        public var title: String
        public var sessions: String
        public var jira: String
        public var diff: String
        public var rows: [Row]
    }

    public struct Session: Sendable {
        public var title: String
        public var meta: String
        public var time: String
    }

    /// One task on one day, as the open row shows it.
    public struct DayLine: Sendable, Identifiable {
        public var id: String { day }
        /// YYYY-MM-DD: the day plan to log from.
        public var day: String
        public var jiraKey: String?
        public var title: String
        public var kind: RecKind
        public var sessions: [Session]
        public var done: String?
        public var sessionTime: String
        public var worklogs: [(span: String, comment: String)]
        /// "Log 3h 30m" / "Add 2h 20m": the day's plan goes to Jira; nil when nothing to log.
        public var action: String?
        public var primary: Bool
    }

    public struct DayGroup: Sendable, Identifiable {
        public var id: String { day }
        public var day: String
        public var title: String
        public var rows: [Row]
    }

    public enum BarKind: Sendable { case before, counted, future }
    public struct Bar: Sendable {
        public var kind: BarKind
        public var sessionH: Double
        public var jiraH: Double
    }

    public var title: String
    /// Under the dates: the clamp to today, the tolerance.
    public var hint: String
    /// Sessions start later than the period: the yellow banner.
    public var coverage: Emphasis?
    /// Jira not connected or failing; no sessions at all.
    public var warnings: [String]
    public var stats: [Stat]
    public var bars: [Bar]
    /// Bar index and label under the chart, by priority: month starts, the first day, Mondays.
    let marks: [(index: Int, label: String)]
    public var coverageIndex: Int?
    public var todayIndex: Int?
    public var groups: [Group]
    public var dayGroups: [DayGroup]
    public var total: (sessions: String, jira: String, diff: String)
    public var notes: [String]
    public var connected: Bool
    public var empty: Bool
    /// Minutes apart a day that still match.
    public var tolerance: String

    let report: Reconciliation
    let f: Fmt

    public init(_ r: Reconciliation, _ f: Fmt) {
        report = r; self.f = f
        let zone = f.calendar.timeZone
        func date(_ d: String) -> Date { StoreDataProvider.start(d, zone) }
        let on = r.jira == "connected"
        connected = on
        empty = r.tasks.isEmpty
        tolerance = String(r.toleranceMin)
        title = f.t("worklog.title", f.dayRange(date(r.from), date(r.toRequested)))
        var hint: [String] = []
        if r.to != r.toRequested { hint.append(f.t("rec.clamped", f.dayMonth(date(r.toRequested)), f.dayMonth(date(r.to)))) }
        if connected { hint.append(f.t("rec.tolerance", String(r.toleranceMin))) }
        self.hint = hint.joined(separator: " ")
        let before = r.coverageFrom.flatMap { $0 > r.from ? $0 : nil }
        coverage = before.map { c in
            let last = f.addDays(-1, to: date(c))
            let after = r.totals.jiraBeforeCoverageSec > 0
                ? f.t("rec.cov.jira", f.dayRange(date(r.from), last), Self.long(r.totals.jiraBeforeCoverageSec, f)) : ""
            return Emphasis(before: f.t("rec.cov.a"), bold: f.t("rec.cov.bold", f.dayMonth(date(c))), after: f.t("rec.cov.b") + after)
        }
        warnings = (r.coverageFrom == nil ? [f.t("rec.noSessions")] : [])
            + (r.jira == "failed" ? [f.t("rec.jiraFailed", Remote.scrubHomes(r.jiraError ?? ""))] : connected ? [] : [f.t("rec.jiraOff")])

        let t = r.totals, span = f.dayRange(date(min(max(r.coverageFrom ?? r.from, r.from), r.to)), date(r.to))
        stats = connected
            ? [Stat(Self.long(t.sessionSec, f), f.t("rec.st.sessions", span)), Stat(Self.long(t.jiraSec, f), f.t("rec.st.jira")),
               Stat(Self.long(t.jiraOnlySec, f), f.t("rec.st.over")), Stat(Self.long(t.unloggedSec, f), f.t("rec.st.unlogged"))]
            : [Stat(Self.long(t.sessionSec, f), f.t("rec.st.sessions", span)), Stat(Self.long(t.zagonOnlySec, f), f.t("rec.st.zagon")),
               Stat(Self.long(t.noTaskSec, f), f.t("rec.st.noTask"))]

        // The chart: every day of the requested range, the days after today empty.
        var bars: [Bar] = [], months: [(Int, String)] = [], first: [(Int, String)] = [], mondays: [(Int, String)] = [], d = date(r.from)
        let byDay = Dictionary(r.days.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a }), end = date(r.toRequested)
        var i = 0
        while d <= end, i < 400 {
            let key = StoreDataProvider.day(d, zone), x = byDay[key]
            let kind: BarKind = key > r.to ? .future : (before.map { key < $0 } ?? false) ? .before : .counted
            bars.append(Bar(kind: kind, sessionH: Double(x?.sessionSec ?? 0) / 3600, jiraH: Double(x?.jiraSec ?? 0) / 3600))
            let dom = f.calendar.component(.day, from: d), monday = f.calendar.component(.weekday, from: d) == 2
            if dom == 1 { months.append((i, f.shortDay(d))) } else if i == 0 { first.append((i, f.shortDay(d))) } else if monday { mondays.append((i, String(dom))) }
            d = f.addDays(1, to: d); i += 1
        }
        marks = months + first + mondays
        self.bars = bars
        // Sessions starting after the period: the whole chart is before them.
        coverageIndex = before.map { c in bars.indices.first { StoreDataProvider.day(f.addDays($0, to: date(r.from)), zone) >= c } ?? bars.count }
        // Only when days to come follow: no line on the chart's right edge.
        todayIndex = bars.lastIndex { $0.kind != .future }.flatMap { $0 < bars.count - 1 ? $0 : nil }

        let rows = r.tasks.map { Self.row($0, f) }
        groups = RecKind.allCases.compactMap { k in
            let g = rows.filter { $0.kind == k }
            guard !g.isEmpty else { return nil }
            let src = r.tasks.filter { (RecKind(rawValue: $0.status) ?? .match) == k }
            let s = src.reduce(0) { $0 + $1.sessionSec }, j = src.reduce(0) { $0 + $1.jiraSec }
            let jiraSide = k != .zagonOnly && k != .noTask
            return Group(kind: k, title: f.t("rec.g." + k.rawValue), sessions: s > 0 ? Self.long(s, f) : "—",
                         jira: jiraSide && j > 0 ? Self.long(j, f) : "—", diff: jiraSide ? Self.diff(s - j, f) : "—", rows: g)
        }
        dayGroups = r.days.filter { !$0.beforeCoverage && !$0.rows.isEmpty }.map { day in
            DayGroup(day: day.day, title: f.t("rec.dayHead", f.dayTitleShortWeekday(date(day.day)), Self.long(day.sessionSec, f),
                                               on ? Self.long(day.jiraSec, f) : "—"),
                     rows: day.rows.map { Self.row($0, f) })
        }
        total = (Self.long(t.sessionSec, f), connected ? Self.long(t.jiraSec, f) : "—", connected ? Self.diff(t.sessionSec - t.jiraSec, f) : "—")
        notes = connected ? [f.t("rec.n.match", String(r.toleranceMin))] + (before.flatMap { c in t.jiraBeforeCoverageSec == 0 ? nil :
            [f.t("rec.n.before", f.dayRange(date(r.from), f.addDays(-1, to: date(c))), Self.long(t.jiraBeforeCoverageSec, f))]
        } ?? []) + [f.t("rec.n.lag")] : []
    }

    static func row(_ x: Reconciliation.Row, _ f: Fmt) -> Row {
        let kind = RecKind(rawValue: x.status) ?? .match
        let jiraSide = kind != .zagonOnly && kind != .noTask
        let d = x.sessionSec - x.jiraSec
        let label = x.title ?? [x.project, x.branch.map { f.t("rec.d.branch", $0) }].compactMap { $0 }.joined(separator: " · ")
        return Row(id: x.id, key: x.key ?? x.jiraKey ?? "—", title: label, kind: kind,
                   sessions: x.sessionSec > 0 ? long(x.sessionSec, f) : "—", jira: x.jiraSec > 0 ? long(x.jiraSec, f) : "—",
                   diff: jiraSide ? diff(d, f) : nil, sign: kind == .match ? 0 : d > 0 ? 1 : d < 0 ? -1 : 0)
    }

    /// Group totals run past two days: hours, never "2d 21h".
    static func long(_ sec: Int, _ f: Fmt) -> String {
        let m = (abs(sec) + 30) / 60
        return m >= 60 ? f.t("dur.hm", String(m / 60), f.pad2(m % 60)) : f.t("dur.m", String(m))
    }

    static func diff(_ sec: Int, _ f: Fmt) -> String {
        abs(sec) < 30 ? "0" : (sec > 0 ? "+" : "−") + long(sec, f)
    }

    /// The labels that fit at this bar width: a label that would touch one before it in `marks` is left out
    /// (the first day next to "Sep 1", a Monday next to a month).
    public func ticks(slot: Double) -> [(index: Int, label: String)] {
        // Width estimated at 7 pt a character of 11 pt text, not measured.
        func span(_ t: (index: Int, label: String)) -> ClosedRange<Double> {
            let x = Double(t.index) * slot
            return x...(x + Double(t.label.count) * 7 + 4)
        }
        var kept: [(index: Int, label: String)] = []
        for t in marks where !kept.contains(where: { span($0).overlaps(span(t)) }) { kept.append(t) }
        return kept.sorted { $0.index < $1.index }
    }

    /// Rows of the groups `filter` keeps (nil: all).
    public func groups(_ filter: RecKind?) -> [Group] { groups.filter { filter == nil || $0.kind == filter } }

    /// Filter chips: "All · 17", then each group with its count.
    public var filters: [(kind: RecKind?, title: String)] {
        [(nil, f.t("rec.all", String(report.tasks.count)))] + groups.map { ($0.kind, f.t("rec.f." + $0.kind.rawValue, String($0.rows.count))) }
    }

    public func count(_ g: Group) -> String { f.t.plural(g.kind == .noTask ? "rec.places" : "rec.tasks", g.rows.count) }

    /// The open row: its days, oldest first.
    public func days(_ id: String) -> [DayLine] {
        let zone = f.calendar.timeZone
        return report.days.filter { !$0.beforeCoverage }.compactMap { day in
            guard let x = day.rows.first(where: { $0.id == id }) else { return nil }
            let kind = RecKind(rawValue: x.status) ?? .match
            let sessions = (x.sessions ?? []).map { s in
                Session(title: s.title ?? s.id,
                        meta: [s.host, s.tool.map { Tool(rawValue: $0)?.name ?? $0 }, s.branch.map { f.t("rec.d.branch", $0) }]
                            .compactMap { $0 }.joined(separator: " · "),
                        time: Self.long(s.sec, f))
            }
            let logs = (x.worklogs ?? []).map { w in
                (f.timeSpan(StoreDataProvider.date(w.start), StoreDataProvider.date(w.end)) + " · " + Self.long(w.sec, f), w.comment ?? "")
            }
            // Only a Jira task's missing time can go to Jira; the day's plan is what is written.
            let gap = x.sessionSec - x.jiraSec
            let action: String? = !connected || x.jiraKey == nil || gap < 60 || kind == .match ? nil
                : f.t(x.jiraSec == 0 ? "rec.d.log" : "rec.d.add", Self.long(gap, f))
            return DayLine(day: day.day, jiraKey: x.jiraKey, title: f.dayTitleShortWeekday(StoreDataProvider.start(day.day, zone)), kind: kind,
                           sessions: sessions, done: x.done, sessionTime: x.sessionSec > 0 ? Self.long(x.sessionSec, f) : "—",
                           worklogs: logs, action: action, primary: x.jiraSec == 0)
        }
    }

    // MARK: export

    public struct Sections: Sendable, Equatable {
        public var totals = true, tasks = true, days = true
        public init() {}
    }

    public func markdown(_ s: Sections = Sections()) -> String {
        let r = report, zone = f.calendar.timeZone
        func cell(_ x: String) -> String { x.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
        var out = ["# " + f.t("rec.md.title", f.dayRange(StoreDataProvider.start(r.from, zone), StoreDataProvider.start(r.toRequested, zone)))]
        let lead = ([hint] + warnings + (coverage.map { [$0.plain] } ?? [])).filter { !$0.isEmpty }
        if !lead.isEmpty { out += [""] + lead.map { "> " + cell($0) } }
        if s.totals {
            out += ["", "## " + f.t("rec.x.totals"), "", "| | \(f.t("rec.md.hours")) |", "|---|--:|"]
            out += stats.map { "| \(cell($0.label)) | \($0.value) |" }
        }
        if s.tasks {
            out += ["", "## " + f.t("rec.x.tasks"), ""]
            if empty { out.append(f.t("rec.empty")) } else {
                out += ["| \(f.t("rec.col.task")) | \(f.t("rec.col.title")) | \(f.t("rec.col.sessions")) | \(f.t("rec.col.jira")) | "
                        + "\(f.t("rec.col.diff")) | \(f.t("rec.col.mark")) |", "|---|---|--:|--:|--:|---|"]
                for g in groups { for x in g.rows {
                    out.append("| \(x.key) | \(cell(x.title)) | \(x.sessions) | \(x.jira) | \(x.diff ?? "—") | \(f.t("rec.k." + x.kind.rawValue)) |")
                } }
                out.append("| **\(f.t("rec.total"))** | | **\(total.sessions)** | **\(total.jira)** | **\(total.diff)** | |")
            }
        }
        if s.days {
            out += ["", "## " + f.t("rec.x.days")]
            for g in dayGroups {
                out += ["", "### " + g.title, ""]
                for x in g.rows {
                    out.append("- **\(x.key)** \(cell(x.title)) — \(f.t("rec.k." + x.kind.rawValue)) · \(x.sessions) / \(x.jira)")
                    guard let src = report.days.first(where: { $0.day == g.day })?.rows.first(where: { $0.id == x.id }) else { continue }
                    for v in src.sessions ?? [] {
                        out.append("  - " + cell([v.title ?? v.id, v.project, v.host, v.branch].compactMap { $0 }.joined(separator: " · "))
                                   + " · " + Self.long(v.sec, f))
                    }
                    if let d = src.done { out.append("  - " + cell(d)) }
                    for w in src.worklogs ?? [] {
                        out.append("  - Jira " + f.timeSpan(StoreDataProvider.date(w.start), StoreDataProvider.date(w.end)) + " · "
                                   + Self.long(w.sec, f) + (w.comment.map { $0.isEmpty ? "" : " · " + cell($0) } ?? ""))
                    }
                }
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// A line per task and day, minutes as numbers (the columns of `zagon log reconcile --csv`).
    public func csv() -> String {
        func field(_ s: String) -> String {
            s.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        func min(_ s: Int) -> String { String(s < 0 ? -((-s + 30) / 60) : (s + 30) / 60) }
        var out = ["day,key,jira_key,title,status,sessions_min,jira_min,diff_min,sessions,worklogs"]
        for d in report.days where !d.beforeCoverage {
            for x in d.rows {
                let label = x.title ?? [x.project, x.branch].compactMap { $0 }.joined(separator: " · ")
                let logs = (x.worklogs ?? []).map { f.timeSpan(StoreDataProvider.date($0.start), StoreDataProvider.date($0.end))
                    + (($0.comment ?? "").isEmpty ? "" : " " + ($0.comment ?? "")) }
                out.append([d.day, x.key ?? "", x.jiraKey ?? "", label, x.status, min(x.sessionSec), min(x.jiraSec),
                            min(x.sessionSec - x.jiraSec), (x.sessions ?? []).map { $0.title ?? $0.id }.joined(separator: "; "),
                            logs.joined(separator: "; ")].map(field).joined(separator: ","))
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// `zagon-reconcile-<from>_<to>.md`
    public func fileName(csv: Bool) -> String { "zagon-reconcile-\(report.from)_\(report.toRequested).\(csv ? "csv" : "md")" }
}

/// The quick periods of the worklog screen, as first and last day.
public enum RecPeriod: String, CaseIterable, Sendable {
    case today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth

    /// ‹ ›: whole months move by months (October → November, not 31 days), anything else by its own length.
    public static func shift(_ from: Date, _ to: Date, by dir: Int, _ f: Fmt) -> (from: Date, to: Date) {
        let after = f.addDays(1, to: to)
        if from == f.startOfMonth(from), after == f.startOfMonth(after) {
            let n = max(1, f.calendar.dateComponents([.month], from: from, to: after).month ?? 1)
            let a = f.addMonths(dir * n, to: from)
            return (a, f.addDays(-1, to: f.addMonths(n, to: a)))
        }
        let n = (f.calendar.dateComponents([.day], from: from, to: to).day ?? 0) + 1
        return (f.addDays(dir * n, to: from), f.addDays(dir * n, to: to))
    }

    public func range(_ f: Fmt) -> (from: Date, to: Date) {
        let today = f.startOfDay(f.now)
        switch self {
        case .today: return (today, today)
        case .yesterday: let y = f.addDays(-1, to: today); return (y, y)
        case .thisWeek: let s = f.startOfWeek(today); return (s, f.addDays(6, to: s))
        case .lastWeek: let s = f.addDays(-7, to: f.startOfWeek(today)); return (s, f.addDays(6, to: s))
        case .thisMonth: let s = f.startOfMonth(today); return (s, f.addDays(-1, to: f.addMonths(1, to: s)))
        case .lastMonth: let s = f.addMonths(-1, to: f.startOfMonth(today)); return (s, f.addDays(-1, to: f.startOfMonth(today)))
        }
    }
}

extension TaskBackend {
    /// `zagon log reconcile` over [from, to] (to may be after today: counted to today). Reads Jira only.
    public func reconcile(from: String, to: String) throws -> Reconciliation {
        try decode(["log", "reconcile", "--json", "--from", from, "--to", to], timeout: 300).0
    }
}

// MARK: - the design sample

extension Reconciliation {
    /// The mockups' period: 60 days back to 27 days ahead of `now`, sessions only for the last 32 days, Jira connected
    /// (or not, or nothing at all). Neutral keys and titles; totals and day rows add up as the CLI's do.
    public static func sample(now: Date, zone: TimeZone, jira: Bool = true, empty: Bool = false, tolerance: Int = 15) -> Reconciliation {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let today = cal.startOfDay(for: now)
        func day(_ n: Int) -> String { StoreDataProvider.day(cal.date(byAdding: .day, value: n, to: today)!, zone) }
        func at(_ n: Int, _ h: Double) -> Double { cal.date(byAdding: .day, value: n, to: today)!.timeIntervalSince1970 + h * 3600 }
        let cover = -31
        // key, Jira key, title, project, branch; per day: (offset from today, minutes in sessions, minutes in Jira)
        typealias Spec = (key: String?, jiraKey: String?, title: String?, project: String, branch: String?, days: [(Int, Int, Int)])
        let specs: [Spec] = empty ? [] : [
            ("PROJ-34", "PROJ-34", "Export reports to CSV", "web-app", "PROJ-34-csv", [(-9, 300, 0), (-8, 250, 0)]),
            ("PROJ-40", "PROJ-40", "Onboarding: hints on the first screen", "web-app", "PROJ-40-hints", [(-15, 210, 0), (-14, 180, 0)]),
            ("OPS-7", "OPS-7", "Renew certificates on the stand", "infra", "main", [(-20, 100, 0)]),
            ("PROJ-21", "PROJ-21", "Web app: settings page, dark theme", "web-app", "PROJ-21-settings-page",
             [(-12, 280, 280), (-11, 270, 270), (-10, 270, 270), (-5, 310, 300), (-4, 380, 240), (-3, 210, 0), (-2, 0, 120), (-1, 160, 120)]),
            ("PROJ-12", "PROJ-12", "State machine: check on dev", "agents", "PROJ-12-dev-check",
             [(-26, 380, 320), (-25, 370, 320), (-19, 380, 320), (-18, 360, 300)]),
            ("PROJ-18", "PROJ-18", "Search over session history", "web-app", "PROJ-18-search", [(-7, 190, 240), (-6, 180, 240)]),
            ("PROJ-27", "PROJ-27", "Calls and sprint planning", "", nil, [(-22, 0, 120), (-8, 0, 120)]),
            ("PROJ-9", "PROJ-9", "Design mockup review", "", nil, [(-16, 0, 120)]),
            ("PROJ-30", "PROJ-30", "Database migration to the new schema", "agents", "PROJ-30-migration",
             [(-29, 380, 375), (-28, 360, 360), (-27, 380, 375)]),
            ("PROJ-15", "PROJ-15", "Mobile layout: tables", "web-app", "PROJ-15-tables", [(-24, 370, 360), (-23, 360, 360)]),
            ("PROJ-33", "PROJ-33", "Logs and alerts", "infra", "PROJ-33-alerts", [(-17, 500, 510)]),
            ("PROJ-8", "PROJ-8", "API documentation", "docs-site", "PROJ-8-api", [(-13, 300, 300)]),
            ("PROJ-41", "PROJ-41", "Role permissions", "agents", "PROJ-41-roles", [(-30, 270, 280)]),
            ("ZAG-1", nil, "Zagon: features, mockups, plan", "zagon", "main", [(-1, 300, 0), (0, 450, 0)]),
            ("ZAG-2", nil, "Zagon: static Swift spike", "zagon", "spike", [(-21, 80, 0)]),
            (nil, nil, nil, "web-app", "fix/login-redirect", [(-6, 120, 0)]),
            (nil, nil, nil, "scripts", "main", [(-2, 70, 0)]),
        ]
        func status(_ s: Spec, _ sec: Int, _ jsec: Int) -> String {
            if s.key == nil { return "no_task" }
            if s.jiraKey == nil { return "zagon_only" }
            return jsec == 0 ? "only_sessions" : sec == 0 ? "only_jira" : abs(sec - jsec) > tolerance * 60 ? "mismatch" : "match"
        }
        var days: [String: Day] = [:], tasks: [Row] = [], t = Totals(sessionSec: 0, jiraSec: 0, unloggedSec: 0, jiraOnlySec: 0,
                                                                   zagonOnlySec: 0, noTaskSec: 0, jiraBeforeCoverageSec: 0)
        for (i, s) in specs.enumerated() {
            var total = Row(taskId: s.key == nil ? nil : i + 1, key: s.key, jiraKey: s.jiraKey, title: s.title,
                            project: s.key == nil ? s.project : nil, branch: s.key == nil ? s.branch : nil, sessionSec: 0, jiraSec: 0, status: "")
            if !jira, s.jiraKey != nil, s.days.allSatisfy({ $0.1 == 0 }) { continue }  // worklogs only: nothing without Jira
            var statuses: [String] = []
            for (n, m, jm) in s.days where !(jira == false && m == 0) {
                let sec = m * 60, jsec = jira ? jm * 60 : 0, st = status(s, sec, jsec)
                var r = total
                r.sessionSec = sec; r.jiraSec = jsec; r.status = st
                r.sessions = sec > 0 ? [SessionRef(id: "s\(i)\(n)", title: s.project + " — " + (s.title ?? "work").lowercased(), project: s.project,
                                                   host: "build-box", tool: i % 4 == 1 ? "codex" : "claude", branch: s.branch, sec: sec)] : []
                r.worklogs = jsec > 0 ? [Log(id: "w\(i)\(n)", start: at(n, 10), end: at(n, 10) + Double(jsec), sec: jsec, comment: s.title)] : []
                r.done = sec > 0 ? s.title : nil
                days[day(n), default: Day(day: day(n), beforeCoverage: false, sessionSec: 0, jiraSec: 0, rows: [])].rows.append(r)
                days[day(n)]!.sessionSec += sec; days[day(n)]!.jiraSec += jsec
                total.sessionSec += sec; total.jiraSec += jsec
                t.sessionSec += sec; t.jiraSec += jsec
                if r.status == "zagon_only" { t.zagonOnlySec += sec } else if r.status == "no_task" { t.noTaskSec += sec }
                t.unloggedSec += max(0, sec - jsec); t.jiraOnlySec += max(0, jsec - sec)
                statuses.append(r.status)
            }
            total.status = statuses.contains("mismatch") ? "mismatch" : Set(statuses).count == 1 ? statuses[0]
                : statuses.allSatisfy({ $0 == "match" }) ? "match" : "mismatch"
            tasks.append(total)
        }
        // Worklogs before the sessions start: not reconciled.
        var n = -60
        while !empty, jira, n < cover {
            let wd = cal.component(.weekday, from: cal.date(byAdding: .day, value: n, to: today)!)
            if wd != 1 && wd != 7 {
                let sec = (6 + (n & 3) / 2) * 3600
                days[day(n)] = Day(day: day(n), beforeCoverage: true, sessionSec: 0, jiraSec: sec, rows: [])
                t.jiraBeforeCoverageSec += sec
            }
            n += 1
        }
        tasks.sort { ($0.sessionSec, $0.jiraSec) > ($1.sessionSec, $1.jiraSec) }
        return Reconciliation(from: day(-60), to: day(0), toRequested: day(27), coverageFrom: empty ? nil : day(cover), toleranceMin: tolerance,
                              jira: jira ? "connected" : "not_connected", jiraError: nil, totals: t, tasks: tasks,
                              days: days.values.sorted { $0.day < $1.day })
    }
}

extension ReconcileVM {
    /// What "Log" on a day writes: that day's whole plan, all its tasks (the existing write path), as the confirmation
    /// lists it; `key` is the row pressed. `title` nil: nothing can be written (no rows for Jira, Jira off or failing).
    public static func confirmation(_ p: WorklogPlan, key: String?, _ f: Fmt) -> (title: String?, detail: String) {
        // `TaskBackend.commit` refuses these: say why instead of offering the button.
        if let e = p.jiraError { return (nil, f.t("worklog.jiraFailed", Remote.scrubHomes(e))) }
        if p.plan.jiraSec == nil { return (nil, f.t("worklog.jiraOff")) }
        let rows = p.plan.rows.filter { $0.state == "planned" && $0.jiraKey != nil }
        let day = f.dayTitleShortWeekday(StoreDataProvider.start(p.plan.day, f.calendar.timeZone))
        guard !rows.isEmpty else { return (nil, f.t("rec.c.none", day)) }
        let missing = key.flatMap { k in rows.contains { $0.jiraKey == k } ? nil : "\n" + f.t("rec.c.notInPlan", k) } ?? ""
        let sec = rows.reduce(0) { $0 + $1.seconds }
        let lines = rows.map { r in
            "\(r.jiraKey ?? "") \(f.timeSpan(StoreDataProvider.date(r.start), StoreDataProvider.date(r.end))) · \(long(r.seconds, f)) — \(r.text)"
        }
        // The day summaries go too (under a row's text, or as a comment): said, as on the day screen.
        let summaries = WorklogVM.summaryNotes(p.worklog(f).rows, f).map { "\n" + $0 }.joined()
        return (f.t.plural("worklog.commit", rows.count, long(sec, f)) + "?",
                f.t("rec.c.detail", day, lines.joined(separator: "\n")) + missing + summaries)
    }
}
