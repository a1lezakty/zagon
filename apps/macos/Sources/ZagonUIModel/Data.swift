import Foundation

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
}

extension ZagonDataProvider {
    public func limitHistory(_ kind: LimitKind) -> [LimitPoint] { [] }
}

public enum Tool: String, Sendable { case claude, codex }

public struct LimitWindow: Sendable {
    public var usedPct: Double
    public var resetsAt: Date
    /// Growth over the last 30–60 minutes in percent per hour; nil when there is not enough data.
    public var pctPerHour: Double?
    public init(usedPct: Double, resetsAt: Date, pctPerHour: Double? = nil) {
        self.usedPct = usedPct; self.resetsAt = resetsAt; self.pctPerHour = pctPerHour
    }
}

public struct Limits: Sendable {
    public var fiveHour: LimitWindow?
    public var week: LimitWindow?
    public init(fiveHour: LimitWindow?, week: LimitWindow?) { self.fiveHour = fiveHour; self.week = week }
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
    /// Its title, "" = untitled; nil = you typed it.
    public var driver: String?
    public init(id: String, title: String, host: String, tool: Tool = .claude, model: String, status: SessionStatus,
                since: Date, command: String, driver: String? = nil) {
        self.id = id; self.title = title; self.host = host; self.tool = tool; self.model = model
        self.status = status; self.since = since; self.command = command; self.driver = driver
    }
}

public struct Totals: Sendable, Equatable {
    public var sessionSec: Double
    public var userSec: Double
    public var tokens: Int
    public var cost: Double
    public init(sessionSec: Double, userSec: Double = 0, tokens: Int, cost: Double) {
        self.sessionSec = sessionSec; self.userSec = userSec; self.tokens = tokens; self.cost = cost
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

public struct DoneItem: Sendable {
    public var project: String
    public var text: String
    public init(_ project: String, _ text: String) { self.project = project; self.text = text }
}

public struct SummaryInfo: Sendable {
    public var engine: String
    public var at: Date
    /// Share of the weekly limit the summary cost; nil = unknown.
    public var weekPct: Double?
    public init(engine: String, at: Date, weekPct: Double?) { self.engine = engine; self.at = at; self.weekPct = weekPct }
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
    /// "What was done" from the AI summary and, alternatively, from session titles.
    public var summary: [DoneItem]
    public var titles: [DoneItem]
    public var summaryInfo: SummaryInfo?
    public init(day: Date, totals: Totals, limitHits: [Interval] = [], weekPctStart: Double? = nil,
                weekPctEnd: Double? = nil, lanes: [Lane] = [], usage: [UsageDimension: [UsageRow]] = [:],
                summary: [DoneItem] = [], titles: [DoneItem] = [], summaryInfo: SummaryInfo? = nil) {
        self.day = day; self.totals = totals; self.limitHits = limitHits; self.weekPctStart = weekPctStart
        self.weekPctEnd = weekPctEnd; self.lanes = lanes; self.usage = usage; self.summary = summary
        self.titles = titles; self.summaryInfo = summaryInfo
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
    public var id: String { key }
    public init(key: String, title: String, description: String = "", state: TaskState, jira: JiraInfo? = nil,
                userSec: Double, sessionSec: Double = 0, tokens: Int = 0, weekPct: Double = 0, todo: [TodoItem] = [],
                doneByDay: [(day: Date, text: String)] = [], sessions: [TaskSession] = [], sessionCount: Int? = nil,
                notes: [String] = [], jiraKey: String? = nil, jiraError: String? = nil) {
        self.key = key; self.title = title; self.description = description; self.state = state; self.jira = jira
        self.userSec = userSec; self.sessionSec = sessionSec; self.tokens = tokens; self.weekPct = weekPct
        self.todo = todo; self.doneByDay = doneByDay; self.sessions = sessions
        self.sessionCount = sessionCount ?? sessions.count; self.notes = notes; self.jiraKey = jiraKey; self.jiraError = jiraError
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
