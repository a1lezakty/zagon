import Foundation
import ZagonCore

// What the screens need from the core, already aggregated. A real provider maps ZagonCore's Store (local or
// `zagon export` from servers) onto these; `MockDataProvider` serves the design sample. Durations are seconds,
// costs are USD at API prices, an empty name means "everything else" (rendered as "other").

public protocol ZagonDataProvider {
    var now: Date { get }
    func limits() -> Limits
    func liveSessions() -> [LiveSession]
    func todayTotals() -> Totals
    func hosts() -> [Host]
    func day(_ day: Date) -> DayData
    func week(containing day: Date) -> WeekData
    func month(containing day: Date) -> MonthData
    func search(_ text: String) -> [SearchHit]
    func tasks() -> [TaskItem]
    func worklog(_ day: Date) -> WorklogData
    /// Readings of the current window and some before it, oldest first (the pace view).
    func limitHistory(_ kind: LimitKind) -> [LimitPoint]
    /// The kept summary of a day or a period (`SummaryDoc.key`); nil = none.
    func summary(_ key: String) -> KeptSummary?
    /// The name a database host is shown by (`SummaryDoc.hosts`): a server's ssh alias, else this Mac.
    func hostName(_ host: String) -> String
}

extension ZagonDataProvider {
    public func limitHistory(_ kind: LimitKind) -> [LimitPoint] { [] }
    public func summary(_ key: String) -> KeptSummary? { nil }
    public func hostName(_ host: String) -> String { host }
}

public enum Tool: String, Sendable, CaseIterable {
    case claude, codex
    public var name: String { self == .codex ? "Codex" : "Claude" }
}

public struct LimitWindow: Sendable {
    public var usedPct: Double
    public var resetsAt: Date
    /// Growth over the last 30–60 minutes in percent per hour; nil when there is not enough data.
    public var pctPerHour: Double?
    /// Whose window this is and when it was read; nil in samples that do not say.
    public var tool: Tool?
    public var readAt: Date?
    public init(usedPct: Double, resetsAt: Date, pctPerHour: Double? = nil, tool: Tool? = nil, readAt: Date? = nil) {
        self.usedPct = usedPct; self.resetsAt = resetsAt; self.pctPerHour = pctPerHour; self.tool = tool; self.readAt = readAt
    }

    /// Used percent as the rings show it; nil when the reading is older than its reset (the window started over).
    public func pct(at now: Date) -> Int? { resetsAt > now ? Int(usedPct.rounded()) : nil }
}

/// One AI's two windows.
public struct AILimits: Sendable {
    public var fiveHour: LimitWindow?
    public var week: LimitWindow?
    public init(fiveHour: LimitWindow? = nil, week: LimitWindow? = nil) { self.fiveHour = fiveHour; self.week = week }

    /// A window was read since its last reset. An older reading is stale: the window started over, usage is unknown
    /// (`RingVM.pct` is nil then).
    public func current(at now: Date) -> Bool { [fiveHour, week].contains { $0?.pct(at: now) != nil } }
}

/// The limits of Claude and Codex, each AI on its own.
public struct Limits: Sendable {
    public var claude: AILimits
    public var codex: AILimits
    public init(claude: AILimits = AILimits(), codex: AILimits = AILimits()) { self.claude = claude; self.codex = codex }

    /// One AI's windows (the samples): Codex's when the windows say so, else Claude's.
    public init(fiveHour: LimitWindow?, week: LimitWindow?) {
        let w = AILimits(fiveHour: fiveHour, week: week)
        self.init(claude: (fiveHour ?? week)?.tool == .codex ? AILimits() : w,
                  codex: (fiveHour ?? week)?.tool == .codex ? w : AILimits())
    }

    public subscript(_ tool: Tool) -> AILimits { tool == .codex ? codex : claude }

    /// The AIs with a current reading, Claude first. Two: both are shown, a ring-in-ring each; one: its pair of rings.
    public func tools(at now: Date) -> [Tool] { Tool.allCases.filter { self[$0].current(at: now) } }
    public func both(at now: Date) -> Bool { tools(at: now).count == 2 }

    /// The windows shown when one AI is shown: the one with a current reading; with none, as `fiveHour` / `week`.
    public func shown(at now: Date) -> AILimits {
        let t = tools(at: now)
        return t.count == 1 ? self[t[0]] : AILimits(fiveHour: fiveHour, week: week)
    }

    /// Claude's window, Codex's where Claude has none (the week screen, the pace view).
    public var fiveHour: LimitWindow? { claude.fiveHour ?? codex.fiveHour }
    public var week: LimitWindow? { claude.week ?? codex.week }
}

/// The two ring colours of one AI: 5 hours and the week (in a ring-in-ring the inner and the outer ring, in a pair the
/// left and the right one). Saved in UserDefaults next to `monoIcon`.
public struct RingColors: Sendable, Equatable {
    public var five: UInt32
    public var week: UInt32
    public init(five: UInt32, week: UInt32) { self.five = five; self.week = week }

    /// Claude as before (orange, blue); Codex its own pair, so the two are not mixed up.
    public static func standard(_ tool: Tool) -> RingColors {
        tool == .codex ? RingColors(five: Palette.violet, week: Palette.working) : RingColors(five: Palette.fiveHour, week: Palette.week)
    }

    /// The swatches settings offer: the palette's accents without red (red is the warning).
    public static let swatches: [UInt32] = [Palette.fiveHour, Palette.week, Palette.working, Palette.violet, Palette.good,
                                            Palette.link, Palette.muted]

    static func key(_ tool: Tool, _ kind: LimitKind) -> String { "ringColor.\(tool.rawValue).\(kind.rawValue)" }

    /// The saved colours; a missing or broken value is the default.
    public static func load(_ tool: Tool, _ d: UserDefaults = .standard) -> RingColors {
        let standard = Self.standard(tool)
        func color(_ kind: LimitKind, _ fallback: UInt32) -> UInt32 {
            guard let v = d.object(forKey: key(tool, kind)) as? Int, (0...0xFFFFFF).contains(v) else { return fallback }
            return UInt32(v)
        }
        return RingColors(five: color(.fiveHour, standard.five), week: color(.week, standard.week))
    }

    public func save(_ tool: Tool, _ d: UserDefaults = .standard) {
        d.set(Int(five & 0xFFFFFF), forKey: Self.key(tool, .fiveHour))
        d.set(Int(week & 0xFFFFFF), forKey: Self.key(tool, .week))
    }
}

public enum SessionStatus: Sendable { case working, waitingPermission, waitingInput, idle }

public struct LiveSession: Sendable, Identifiable {
    public var id: String
    public var title: String
    public var host: String
    public var tool: Tool
    public var model: String
    public var status: SessionStatus
    /// When the current status began.
    public var since: Date
    /// Command that brings the session back (`ssh … -t tmux attach -t …`, `claude --resume …`).
    public var command: String
    /// Another session typed its last message (a worker driven over tmux): waiting for input, it waits for that session.
    /// Its title or project, "" = neither; nil = you typed it.
    public var drivenBy: String?
    public init(id: String, title: String, host: String, tool: Tool = .claude, model: String, status: SessionStatus,
                since: Date, command: String, drivenBy: String? = nil) {
        self.id = id; self.title = title; self.host = host; self.tool = tool; self.model = model
        self.status = status; self.since = since; self.command = command; self.drivenBy = drivenBy
    }
}

public struct Totals: Sendable, Equatable {
    public var sessionSec: Double
    public var userSec: Double
    public var tokens: Int
    public var cost: Double
    /// The cost per AI; empty where nobody split it.
    public var costByTool: [Tool: Double]
    public init(sessionSec: Double, userSec: Double = 0, tokens: Int, cost: Double, costByTool: [Tool: Double] = [:]) {
        self.sessionSec = sessionSec; self.userSec = userSec; self.tokens = tokens; self.cost = cost; self.costByTool = costByTool
    }
}

public struct Host: Sendable {
    public var name: String
    public var online: Bool
    public init(name: String, online: Bool) { self.name = name; self.online = online }
}

public struct Interval: Sendable {
    public var start: Date
    public var end: Date
    public var waiting: Bool
    public init(_ start: Date, _ end: Date, waiting: Bool = false) {
        self.start = start; self.end = end; self.waiting = waiting
    }
}

public struct Lane: Sendable {
    public var title: String
    public var host: String
    public var intervals: [Interval]
    public init(title: String, host: String, intervals: [Interval]) {
        self.title = title; self.host = host; self.intervals = intervals
    }
}

public enum UsageDimension: String, CaseIterable, Sendable { case project, model, agent, tool, host }

public struct UsageRow: Sendable {
    public var name: String
    public var tokens: Int
    public var cost: Double
    public init(_ name: String, tokens: Int, cost: Double) { self.name = name; self.tokens = tokens; self.cost = cost }
}

/// A session of the day as the fallback "what was done" lists it (no written summary).
public struct DoneSession: Sendable, Equatable {
    public var title: String
    public var branch: String?
    public var sec: Double
    public init(_ title: String, branch: String? = nil, sec: Double) { self.title = title; self.branch = branch; self.sec = sec }
}

/// A project of the day without a written summary: its sessions, time and price.
public struct DoneProject: Sendable, Equatable {
    public var name: String
    public var sec: Double
    public var cost: Double
    public var sessions: [DoneSession]
    public init(_ name: String, sec: Double, cost: Double, sessions: [DoneSession]) {
        self.name = name; self.sec = sec; self.cost = cost; self.sessions = sessions
    }
}

/// A written summary of a day or a period as kept (`summary` table) or just answered by a CLI.
public struct KeptSummary: Sendable, Equatable {
    public var doc: SummaryDoc
    public var engine: String
    public var at: Date
    /// The AI engine whose CLI the source does not have (written without AI); only in a CLI's answer.
    public var noCli: String?
    /// Why the AI did not answer this time (written without AI, or the earlier AI summary is shown); only in a CLI's answer.
    public var aiError: String?
    public init(doc: SummaryDoc, engine: String, at: Date, noCli: String? = nil, aiError: String? = nil) {
        self.doc = doc; self.engine = engine; self.at = at; self.noCli = noCli; self.aiError = aiError
    }
}

public struct SummaryInfo: Sendable {
    public var engine: String
    public var at: Date
    /// Share of the weekly limit the summary cost; nil = unknown.
    public var weekPct: Double?
    /// The machines whose sessions it is made from, as shown; empty = it does not say (written before).
    public var sources: [String]
    public init(engine: String, at: Date, weekPct: Double?, sources: [String] = []) {
        self.engine = engine; self.at = at; self.weekPct = weekPct; self.sources = sources
    }
}

public struct DayData: Sendable {
    public var day: Date
    public var totals: Totals
    /// Times the 5-hour limit was at 100 %.
    public var limitHits: [Interval]
    public var weekPctStart: Double?
    public var weekPctEnd: Double?
    public var lanes: [Lane]
    public var usage: [UsageDimension: [UsageRow]]
    /// "What was done": the written summary (nil: none yet, or free text from before) and, without it, the day's
    /// projects from this Mac's data.
    public var doc: SummaryDoc?
    public var projects: [DoneProject]
    public var summaryInfo: SummaryInfo?
    /// `projects` by machine (as shown), for the sessions a summary from other machines leaves out.
    public var hostProjects: [String: [DoneProject]]
    public init(day: Date, totals: Totals, limitHits: [Interval] = [], weekPctStart: Double? = nil,
                weekPctEnd: Double? = nil, lanes: [Lane] = [], usage: [UsageDimension: [UsageRow]] = [:],
                doc: SummaryDoc? = nil, projects: [DoneProject] = [], summaryInfo: SummaryInfo? = nil,
                hostProjects: [String: [DoneProject]] = [:]) {
        self.day = day; self.totals = totals; self.limitHits = limitHits; self.weekPctStart = weekPctStart
        self.weekPctEnd = weekPctEnd; self.lanes = lanes; self.usage = usage; self.doc = doc
        self.projects = projects; self.summaryInfo = summaryInfo; self.hostProjects = hostProjects
    }
}

public struct ProjectWeek: Sendable {
    public var name: String
    public var sec: Double
    public var cost: Double
    /// Last week's seconds; nil = the project is new this week.
    public var prevSec: Double?
    public init(_ name: String, sec: Double, cost: Double, prevSec: Double?) {
        self.name = name; self.sec = sec; self.cost = cost; self.prevSec = prevSec
    }
}

public struct WeekData: Sendable {
    /// Monday 00:00 of the week.
    public var start: Date
    /// Projects in display order (colour index = position).
    public var projects: [String]
    /// 7 days × projects; empty inner array = no data (future day).
    public var days: [[Totals]]
    public var totals: Totals
    public var previous: Totals
    public var projectRows: [ProjectWeek]
    /// Weekly limit at the end of each day; nil = no reading (future).
    public var limitByDay: [Double?]
    public init(start: Date, projects: [String], days: [[Totals]], totals: Totals, previous: Totals,
                projectRows: [ProjectWeek], limitByDay: [Double?]) {
        self.start = start; self.projects = projects; self.days = days; self.totals = totals
        self.previous = previous; self.projectRows = projectRows; self.limitByDay = limitByDay
    }
}

public struct MonthData: Sendable {
    /// First day of the month, 00:00.
    public var month: Date
    /// Hours the sessions worked, per day of month; nil = no data yet (future).
    public var hours: [Double?]
    /// Oldest archived transcript; days after it can be recounted.
    public var archiveSince: Date?
    public init(month: Date, hours: [Double?], archiveSince: Date?) {
        self.month = month; self.hours = hours; self.archiveSince = archiveSince
    }
}

public struct SearchHit: Sendable {
    public var title: String
    public var host: String
    public var start: Date
    public var end: Date
    public var model: String
    public var command: String
    public init(title: String, host: String, start: Date, end: Date, model: String, command: String) {
        self.title = title; self.host = host; self.start = start; self.end = end; self.model = model
        self.command = command
    }
}

public enum TaskState: Sendable { case planned, active, review, done }

public struct JiraInfo: Sendable {
    public var status: String
    public var statusMatches: Bool
    public var loggedSec: Double
    public init(status: String, statusMatches: Bool, loggedSec: Double) {
        self.status = status; self.statusMatches = statusMatches; self.loggedSec = loggedSec
    }
}

public struct TodoItem: Sendable {
    public var text: String
    public var done: Bool
    public init(_ text: String, done: Bool) { self.text = text; self.done = done }
}

public struct TaskSession: Sendable {
    public var tool: Tool
    public var title: String
    public var host: String
    public var model: String
    public var first: Date
    public var last: Date
    public var sec: Double
    public init(tool: Tool, title: String, host: String, model: String, first: Date, last: Date, sec: Double) {
        self.tool = tool; self.title = title; self.host = host; self.model = model; self.first = first
        self.last = last; self.sec = sec
    }
}

public struct TaskItem: Sendable, Identifiable {
    public var key: String
    public var title: String
    public var description: String
    public var state: TaskState
    public var jira: JiraInfo?
    public var userSec: Double
    public var sessionSec: Double
    public var tokens: Int
    public var weekPct: Double
    public var todo: [TodoItem]
    public var doneByDay: [(day: Date, text: String)]
    public var sessions: [TaskSession]
    public var sessionCount: Int
    public var notes: [String]
    /// The Jira issue when Jira itself was not asked (`jira` nil), and why it could not be.
    public var jiraKey: String?
    public var jiraError: String?
    /// Worked on in the last 7 days (the main list); false: in Jira with no work here then ("More in Jira").
    public var worked: Bool
    /// The Jira status as last read where the task lives.
    public var jiraStatus: String?
    public var id: String { key }
    public init(key: String, title: String, description: String = "", state: TaskState, jira: JiraInfo? = nil,
                userSec: Double, sessionSec: Double = 0, tokens: Int = 0, weekPct: Double = 0, todo: [TodoItem] = [],
                doneByDay: [(day: Date, text: String)] = [], sessions: [TaskSession] = [], sessionCount: Int? = nil,
                notes: [String] = [], jiraKey: String? = nil, jiraError: String? = nil, worked: Bool = true, jiraStatus: String? = nil) {
        self.key = key; self.title = title; self.description = description; self.state = state; self.jira = jira
        self.userSec = userSec; self.sessionSec = sessionSec; self.tokens = tokens; self.weekPct = weekPct
        self.todo = todo; self.doneByDay = doneByDay; self.sessions = sessions
        self.sessionCount = sessionCount ?? sessions.count; self.notes = notes; self.jiraKey = jiraKey; self.jiraError = jiraError
        self.worked = worked; self.jiraStatus = jiraStatus
    }
}

public enum WorklogDestination: Sendable { case alreadyLogged, jira, zagonOnly }

public struct WorklogRow: Sendable {
    public var key: String
    public var start: Date
    public var end: Date
    public var text: String
    public var destination: WorklogDestination
    public var sec: Double { end.timeIntervalSince(start) }
    public init(key: String, start: Date, end: Date, text: String, destination: WorklogDestination) {
        self.key = key; self.start = start; self.end = end; self.text = text; self.destination = destination
    }
}

/// A stretch where sessions of several tasks ran at once and the time was split by their activity.
public struct WorklogSplit: Sendable {
    public var start: Date
    public var end: Date
    public var parts: [(label: String, sec: Double)]
    public init(start: Date, end: Date, parts: [(label: String, sec: Double)]) {
        self.start = start; self.end = end; self.parts = parts
    }
}

public struct WorklogData: Sendable {
    public var day: Date
    public var workStart: Date?
    public var workEnd: Date?
    public var userSec: Double
    public var sessionSec: Double
    public var rows: [WorklogRow]
    public var splits: [WorklogSplit]
    /// What the planner points out (differences against Jira, unknown keys, time that found no place).
    public var notes: [String]
    /// Your worklogs in Jira that day, by hand ones too (nil: only the rows above are known).
    public var jiraSec: Double?
    /// Why nothing can be written to Jira (not connected, did not answer); nil = it can.
    public var jiraBlocked: String?
    public init(day: Date, workStart: Date?, workEnd: Date?, userSec: Double, sessionSec: Double,
                rows: [WorklogRow], splits: [WorklogSplit], notes: [String] = [], jiraSec: Double? = nil, jiraBlocked: String? = nil) {
        self.day = day; self.workStart = workStart; self.workEnd = workEnd; self.userSec = userSec
        self.sessionSec = sessionSec; self.rows = rows; self.splits = splits; self.notes = notes
        self.jiraSec = jiraSec; self.jiraBlocked = jiraBlocked
    }
}
