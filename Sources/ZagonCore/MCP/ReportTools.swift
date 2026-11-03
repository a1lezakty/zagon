#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// `zagon mcp` tools: everything wired into one server.
public enum ZagonMCP {
    /// `refresh` runs before each data tool (an incremental scan); its failure is logged and the answer uses what is
    /// already in the database. `handoff` / `tasks` stay nil until those packages are part of the build.
    public static func server(store: Store, exportDir: String, refresh: (() throws -> Void)? = nil,
                              handoff: HandoffService? = nil, tasks: TaskService? = nil, paths: ZagonPaths? = nil,
                              now: @escaping () -> Timestamp = Time.now,
                              log: @escaping (String) -> Void = { _ in }) -> MCPServer {
        let r = ReportTools(store: store, exportDir: exportDir, refresh: refresh, tasks: tasks, now: now, log: log)
        r.localAccount = paths.flatMap(Settings.limitsAccount)
        return MCPServer(tools: r.tools + ServiceTools.tools(handoff: handoff, tasks: tasks) + (paths.map { SettingsTools.tools($0, store: store) } ?? []),
                         prompts: [ServiceTools.resume(handoff)], log: log)
    }
}

extension ZagonMCP {
    /// The text of the `limits` tool (also printed by `zagon today`). `localAccount`: `[limits] account`.
    public static func limitsText(store: Store, now: Timestamp = Time.now(), localAccount: String? = nil) throws -> String {
        let r = ReportTools(store: store, exportDir: "", refresh: nil, tasks: nil, now: { now }, log: { _ in })
        r.localAccount = localAccount
        return try r.limits(MCPArgs(.object([])))
    }
}

/// status, limits, sessions, day, week, range, summary, search, export_day over `Store` / `Reports`.
final class ReportTools {
    let store: Store
    let reports: Reports
    let exportDir: String
    let refresh: (() throws -> Void)?
    /// What is left to log, in `status`.
    let tasks: TaskService?
    let now: () -> Timestamp
    let log: (String) -> Void
    /// `[limits] account`: the default account's label beside another account's limits.
    var localAccount: String?

    init(store: Store, exportDir: String, refresh: (() throws -> Void)?, tasks: TaskService?, now: @escaping () -> Timestamp,
         log: @escaping (String) -> Void) {
        self.store = store; reports = Reports(store: store); self.exportDir = exportDir; self.refresh = refresh
        self.tasks = tasks; self.now = now; self.log = log
    }

    var tools: [MCPTool] {
        // The closures keep this object alive (nothing else does).
        func t(_ name: String, _ title: String, _ d: String, schema: JValue = MCPSchema.object([:]),
               readOnly: Bool = true, _ f: @escaping (ReportTools) -> (MCPArgs) throws -> String) -> MCPTool {
            MCPTool(name: name, title: title, description: d, inputSchema: schema, readOnly: readOnly) { a in
                self.fresh()
                return try f(self)(a)
            }
        }
        return [
            t("status", "Status now",
              "One call for \"where do I stand\": subscription limits, sessions waiting for the user, and what is left to log "
              + "to Jira today (worklog_plan shows the rows).", ReportTools.status),
            t("limits", "Subscription limits",
              "Claude Code and Codex subscription limits: % used of the 5-hour and weekly windows, reset time, and a "
              + "forecast at the current pace.", ReportTools.limits),
            t("sessions", "Sessions",
              "Recent sessions (Claude Code and Codex) with live status, how long each has waited for the user, tokens, "
              + "and the command to resume it. Waiting sessions come first. With `date`: sessions active that day.",
              schema: MCPSchema.object(["date": MCPSchema.day("Only sessions active on this day"),
                                "limit": MCPSchema.integer("How many (default 10)", min: 1, max: 50)]),
              ReportTools.sessions),
            t("day", "Day report",
              "One day: tokens by kind, requests, cost at API list prices, session time and the user's own time, models, "
              + "projects, tools, busiest hours, top sessions, and the day's summary in full if there is one.",
              schema: MCPSchema.object(["date": MCPSchema.day("The day (default today)")]), ReportTools.day),
            t("week", "Week report",
              "Seven days from `from`, or ending at `to` (default: the 7 days ending today): totals and cost vs the "
              + "previous 7 days, each day, top projects.",
              schema: MCPSchema.object(["from": MCPSchema.day("First day of the seven"), "to": MCPSchema.day("Last day of the seven")]),
              ReportTools.week),
            t("range", "Range report",
              "Totals for the days from `from` to `to` (inclusive, at most 366 days): tokens, cost, time, models, projects, days.",
              schema: MCPSchema.object(["from": MCPSchema.day("First day"), "to": MCPSchema.day("Last day (default today)")],
                               required: ["from"]), ReportTools.range),
            t("summary", "Week or month summary",
              "What was done over a week (Monday to Sunday) or a calendar month: the period's summary if one was made "
              + "(zagon summary --week / --month, the Mac app), else the day summaries of the period merged. Makes no AI "
              + "call. A day's summary is in `day`.",
              schema: MCPSchema.object(["period": MCPSchema.string("week (default) or month", enum: ["week", "month"]),
                                        "date": MCPSchema.day("A day in it (default today); for a month YYYY-MM works too")]),
              ReportTools.periodSummary),
            t("search", "Search sessions",
              "Find sessions by topic: words in session titles and in the user's typed messages (prefix match, all words "
              + "must match). Returns sessions with the number of matching messages and the command to resume each.",
              schema: MCPSchema.object(["text": MCPSchema.string("Words to look for"),
                                "from": MCPSchema.day("Only from this day"), "to": MCPSchema.day("Only up to this day"),
                                "limit": MCPSchema.integer("How many sessions (default 10)", min: 1, max: 50)],
                               required: ["text"]), ReportTools.search),
            t("export_day", "Export a day",
              "Writes the day as Markdown (totals, sessions, projects, models, tools; text for a worklog) to a file under "
              + "~/.zagon/exports and returns its path with a one-line summary.",
              schema: MCPSchema.object(["date": MCPSchema.day("The day (default today)")]), readOnly: false, ReportTools.exportDay),
        ]
    }

    func fresh() {
        guard let refresh else { return }
        do { try refresh() } catch { log("mcp: scan failed: \(error)") }
    }

    // MARK: limits

    func limits(_ a: MCPArgs) throws -> String {
        let all = try store.latestLimits()
        guard !all.isEmpty else {
            return "No limit readings yet. Claude Code limits come from its status line (zagon install wraps it; "
                + "Claude Code 2.1.80+ on Pro/Max), Codex limits from its session files."
        }
        let t = now()
        return try Accounts.labeled(all, now: t, localAccount: localAccount).map { s, label in
            var line = "\(Ru.tool(s.tool))\(label.map { " (\($0))" } ?? "") \(Self.window(s.window, s.windowMinutes)): "
            guard let r = s.resetsAt else { return line + "\(Txt.pct(s.usedPct)) used (reading \(Txt.ago(t - s.ts)))" }
            if r <= t {
                return line + "window reset at \(Txt.when(r, now: t)); last reading before it \(Txt.pct(s.usedPct)), "
                    + "none since"
            }
            line += "\(Txt.pct(s.usedPct)) used, resets \(Txt.when(r, now: t)) (in \(Txt.dur(r - t)))"
            if let f = try forecast(s) { line += "; " + f }
            return line + " · reading \(Txt.ago(t - s.ts))"
        }.joined(separator: "\n")
    }

    static func window(_ w: String, _ minutes: Int?) -> String {
        let parts = w.split(separator: ":", maxSplits: 1).map(String.init)
        let base = parts.last ?? w, prefix = parts.count == 2 ? parts[0] + " " : ""
        let m = minutes ?? ["five_hour": 300, "seven_day": 10080, "primary": 300, "secondary": 10080][base]
        switch m {
        case 300?: return prefix + "5h"
        case 10080?: return prefix + "week"
        case let m? where m % 1440 == 0: return prefix + "\(m / 1440)d"
        case let m? where m % 60 == 0: return prefix + "\(m / 60)h"
        case let m?: return prefix + "\(m)m"
        default: return w
        }
    }

    /// Pace over the last 10–60 minutes of readings in the same window period → when it reaches 100 %.
    func forecast(_ s: LimitSnapshot) throws -> String? {
        guard let r = s.resetsAt else { return nil }
        guard s.usedPct < 100 else { return "limit reached" }
        guard let first = try Store.paceBase(store.db, s, from: s.ts - 3600, to: s.ts - 600) else { return nil }
        let (u0, t0) = first
        let rate = (s.usedPct - u0) / (s.ts - t0)
        let span = Txt.dur(s.ts - t0)
        guard rate > 0 else { return "flat over the last \(span)" }
        let eta = s.ts + (100 - s.usedPct) / rate
        if eta >= r { return "at the pace of the last \(span) it lasts until the reset" }
        return "at the pace of the last \(span) it runs out at \(Txt.when(eta, now: now())), before the reset"
    }

    // MARK: sessions

    struct SessionExtra { var statusAt: Timestamp?; var cwd: String?; var host: String? }

    func extra(_ id: String) throws -> SessionExtra {
        try store.db.one("SELECT status_at, cwd, host FROM session WHERE id=?", [.text(id)]) {
            SessionExtra(statusAt: $0.optReal(0), cwd: $0.text(1), host: $0.text(2))
        } ?? SessionExtra()
    }

    /// Waiting for the user: a driven worker waiting for input waits for its driver, one with background tasks works.
    static func waiting(_ s: SessionLine) -> Bool {
        s.status == "waiting_permission" || (s.status == "waiting_input" && s.drivenBy == nil && s.background == nil)
    }

    func sessions(_ a: MCPArgs) throws -> String {
        let limit = min(max(try a.int("limit") ?? 10, 1), 50)
        var list: [SessionLine]
        if let d = try a.day("date", old: "day"), let (s, e) = Time.dayBounds(d) {
            list = try reports.sessions(from: s, to: e, limit: limit, now: now())
            if list.isEmpty { return "No sessions on \(d)." }
        } else {
            list = try reports.sessions(limit: limit, now: now())
            if list.isEmpty { return "No sessions yet." }
        }
        let extras = try Dictionary(uniqueKeysWithValues: list.map { ($0.id, try extra($0.id)) })
        // Waiting for the user first, longest wait on top; then the rest in the order Reports gave.
        let order = Dictionary(uniqueKeysWithValues: list.enumerated().map { ($1.id, $0) })
        list.sort { x, y in
            let wx = Self.waiting(x), wy = Self.waiting(y)
            if wx != wy { return wx }
            if wx { return (extras[x.id]?.statusAt ?? 0) < (extras[y.id]?.statusAt ?? 0) }
            return order[x.id]! < order[y.id]!
        }
        let t = now()
        let nWait = list.filter(Self.waiting).count, nWork = list.filter { $0.status == "working" || $0.background != nil }.count
        return (["\(Txt.count(list.count, "session")): \(nWait) waiting for the user, \(nWork) working"]
                + list.map { line($0, extras[$0.id] ?? SessionExtra(), t) }).joined(separator: "\n")
    }

    func line(_ s: SessionLine, _ x: SessionExtra, _ t: Timestamp) -> String {
        var parts = ["\(s.tool)\(Accounts.tag(s.account)) \(Txt.shortId(s.id))", s.title.map { "\"\(Txt.oneLine($0, 60))\"" } ?? "(untitled)"]
        parts.append((s.project ?? "?") + (s.gitBranch.map { " (\($0))" } ?? ""))
        if let st = s.status {
            let label = ["waiting_input": "waiting for input", "waiting_permission": "waiting for permission"][st] ?? st
            if let state = s.turnState(now: t) {
                parts.append(state)
            } else {
                parts.append(label + (x.statusAt.map { " \(Txt.dur(t - $0))" } ?? ""))
            }
        }
        if let l = s.lastAt { parts.append("last active \(Txt.when(l, now: t))") }
        parts.append("\(Txt.tokens(s.tokens.total)) tokens, working \(Txt.dur(s.workingSec))")
        if let cmd = Self.resumeCommand(id: s.id, tool: s.tool, cwd: x.cwd) { parts.append("resume: " + cmd) }
        return "- " + parts.joined(separator: " · ")
    }

    // MARK: status

    func status(_ a: MCPArgs) throws -> String {
        var out = ["limits:"] + (try limits(a)).split(separator: "\n").map { "- " + $0 }
        let t = now()
        let live = try reports.sessions(limit: 50, now: t)
        let wait = try live.filter(Self.waiting).map { ($0, try extra($0.id)) }.sorted { ($0.1.statusAt ?? 0) < ($1.1.statusAt ?? 0) }
        out.append("sessions: \(wait.count) waiting for the user, \(live.filter { $0.status == "working" || $0.background != nil }.count) working"
                   + (wait.isEmpty ? "" : ":"))
        out += wait.map { line($0.0, $0.1, t) }
        if let tasks {
            // The plan is a part: its failure (Jira, config) must not hide the rest.
            do { out.append("to log today: " + (try tasks.worklogBrief())) }
            catch let e as MCPToolError { out.append("to log today: " + e.message) }
            catch { out.append("to log today: not known (\(error))") }
        }
        return out.joined(separator: "\n")
    }

    static func resumeCommand(id: String, tool: String, cwd: String?) -> String? {
        let native = String(id.drop { $0 != ":" }.dropFirst())
        guard !native.isEmpty, tool != "cursor" else { return nil }  // Cursor's conversations open in Cursor
        let id = Sys.shellQuote(native)
        let cmd = tool == "codex" ? "codex resume \(id)" : "claude --resume \(id)"
        return cwd.map { "cd \(Sys.shellQuote($0)) && \(cmd)" } ?? cmd
    }

    // MARK: day / week / range

    func day(_ a: MCPArgs) throws -> String {
        let d = try a.day("date", old: "day") ?? Time.dayString(now())
        let r = try reports.day(d)
        if r.tokens.total == 0 && r.sessionSec == 0 && r.sessions.isEmpty { return "\(d): no activity recorded." }
        var out: [String] = ["\(d) (\(Txt.weekday(d))): " + Txt.tokenLine(r.tokens) + ", \(r.toolCalls) tool calls",
                   "cost: \(Txt.usd(r.cost, unpriced: r.unpriced)) \(Txt.apiNote)",
                   "time: sessions \(Txt.dur(r.sessionSec)), the user \(Txt.dur(r.userSec)); \(Txt.count(r.sessions.count, "session"))"]
        if !r.models.isEmpty {
            out.append("models: " + r.models.prefix(5).map {
                "\($0.model) \(Txt.tokens($0.tokens.total)) (\(Txt.share($0.tokens.total, r.tokens.total)), \(Txt.usd($0.cost, unpriced: $0.unpriced)))"
            }.joined(separator: ", "))
        }
        if !r.projects.isEmpty { out.append("projects: " + Txt.projects(r.projects.prefix(6))) }
        if !r.tools.isEmpty { out.append("tools: " + r.tools.prefix(8).map { "\($0.name) \($0.count)" }.joined(separator: ", ")) }
        // hours[i] = the i-th hour after local midnight (on DST days not the clock hour i).
        let busy = r.hours.enumerated().filter { $0.element > 0 }.sorted { $0.element > $1.element }.prefix(3)
        if let start = Time.dayBounds(d)?.start, !busy.isEmpty {
            out.append("busiest hours: " + busy.map {
                "\(Txt.when(start + Double($0.offset) * 3600, now: start)) \(Txt.tokens($0.element))"
            }.joined(separator: ", "))
        }
        if !r.sessions.isEmpty {
            out.append("top sessions:")
            for s in r.sessions.prefix(8) {
                out.append("- \(s.tool)\(Accounts.tag(s.account)) \(Txt.shortId(s.id)) \(s.title.map { "\"\(Txt.oneLine($0, 60))\"" } ?? "(untitled)") · "
                           + "\(s.project ?? "?") · \(Txt.tokens(s.tokens.total)) tokens, working \(Txt.dur(s.workingSec))")
            }
        }
        if let k = try kept(d) { out.append("summary\(k.mark):\n" + k.text(markdown: false)) }
        return out.joined(separator: "\n")
    }

    struct Kept {
        let doc: SummaryDoc?
        let raw: String
        let created: Timestamp
        /// Made without AI though one is set up: why.
        let whyNoAI: String?
        /// A stored doc as text or Markdown, free text from before as it is.
        func text(markdown: Bool) -> String { doc?.text(markdown: markdown) ?? raw }
        var mark: String { whyNoAI.map { " (without AI: \($0))" } ?? "" }
    }

    /// The kept summary of a day or a range key (`SummaryDoc.key`): one written by an AI over one made without.
    func kept(_ key: String) throws -> Kept? {
        guard let (engine, raw, created) = try store.db.one(
            "SELECT engine, text, created FROM summary WHERE day=? ORDER BY engine = 'none', created DESC LIMIT 1", [.text(key)],
            { ($0.text(0) ?? "", $0.text(1) ?? "", $0.real(2)) }) else { return nil }
        return Kept(doc: SummaryDoc.decode(raw), raw: raw, created: created,
                    whyNoAI: engine == "none" ? try DaySummary.whyNoAI(store, key) : nil)
    }

    func week(_ a: MCPArgs) throws -> String {
        let from = try a.day("from", old: "start"), to = try a.day("to")
        if from != nil && to != nil { throw MCPToolError("from or to, not both: a week is seven days") }
        var end = Time.dayString(now())
        if let from, let e = Time.addDays(from, 6) { end = e } else if let to { end = to }
        let w = try reports.week(ending: end)
        var out: [String] = ["\(w.from) … \(w.to): " + Txt.tokenLine(w.tokens)
                   + " (\(Txt.change(w.tokens.total, w.previous.total)) vs the 7 days before: \(Txt.tokens(w.previous.total)))",
                   "cost: \(Txt.usd(w.cost, unpriced: w.unpriced)) (the 7 days before: \(Txt.usd(w.previousCost, unpriced: w.previousUnpriced))) "
                   + Txt.apiNote,
                   "time: sessions \(Txt.dur(w.sessionSec)) (before \(Txt.dur(w.previousSessionSec))), the user "
                   + "\(Txt.dur(w.userSec)) (before \(Txt.dur(w.previousUserSec)))",
                   "days:"]
        for d in w.days {
            out.append("- \(d.day) \(Txt.weekday(d.day)): \(Txt.tokens(d.tokens.total)) tokens, \(Txt.usd(d.cost, unpriced: d.unpriced)), "
                       + "sessions \(Txt.dur(d.sessionSec)), the user \(Txt.dur(d.userSec))")
        }
        if !w.projects.isEmpty { out.append("top projects: " + Txt.projects(w.projects.prefix(5))) }
        return out.joined(separator: "\n")
    }

    func range(_ a: MCPArgs) throws -> String {
        guard let from = try a.day("from") else { throw MCPToolError("from is required") }
        let to = try a.day("to") ?? Time.dayString(now())
        guard from <= to else { throw MCPToolError("from must not be after to") }
        var days = [from]
        while let last = days.last, last < to {
            guard days.count < 366, let n = Time.addDays(last, 1) else { throw MCPToolError("at most 366 days") }
            days.append(n)
        }
        var tokens = TokenTotals(), ss = 0.0, us = 0.0, calls = 0, cost = 0.0, unpriced = 0
        var models: [String: ModelLine] = [:], projects: [ProjectLine] = [], perDay: [(String, TokenTotals, Double)] = []
        for d in days {
            let r = try reports.day(d, withSessions: false)
            tokens.add(r.tokens); ss += r.sessionSec; us += r.userSec; calls += r.toolCalls; cost += r.cost; unpriced += r.unpriced
            for m in r.models {
                models[m.model, default: ModelLine(model: m.model, tokens: TokenTotals())].tokens.add(m.tokens)
                models[m.model]!.cost += m.cost; models[m.model]!.unpriced += m.unpriced
            }
            for p in r.projects {
                if let i = projects.firstIndex(where: { $0.tool == p.tool && $0.project == p.project }) {
                    projects[i].tokens.add(p.tokens); projects[i].sessionSec += p.sessionSec; projects[i].toolCalls += p.toolCalls
                    projects[i].cost += p.cost; projects[i].unpriced += p.unpriced
                } else { projects.append(p) }
            }
            if r.tokens.total > 0 || r.sessionSec > 0 { perDay.append((d, r.tokens, r.sessionSec)) }
        }
        var out: [String] = ["\(from) … \(to) (\(days.count) days, \(perDay.count) active): " + Txt.tokenLine(tokens) + ", \(calls) tool calls",
                   "cost: \(Txt.usd(cost, unpriced: unpriced)) \(Txt.apiNote)",
                   "time: sessions \(Txt.dur(ss)), the user \(Txt.dur(us))"]
        if !models.isEmpty {
            out.append("models: " + models.values.sorted { $0.tokens.total > $1.tokens.total }.prefix(5).map {
                "\($0.model) \(Txt.tokens($0.tokens.total)) (\(Txt.share($0.tokens.total, tokens.total)), \(Txt.usd($0.cost, unpriced: $0.unpriced)))"
            }.joined(separator: ", "))
        }
        projects.sort { ($0.tokens.total, $0.sessionSec) > ($1.tokens.total, $1.sessionSec) }
        if !projects.isEmpty { out.append("top projects: " + Txt.projects(projects.prefix(6))) }
        if perDay.count <= 14 {
            if !perDay.isEmpty { out.append("days: " + perDay.map { "\($0.0) \(Txt.tokens($0.1.total))" }.joined(separator: ", ")) }
        } else {
            out.append("busiest days: " + perDay.sorted { $0.1.total > $1.1.total }.prefix(5)
                .map { "\($0.0) \(Txt.tokens($0.1.total))" }.joined(separator: ", "))
        }
        return out.joined(separator: "\n")
    }

    // MARK: summary of a week or a month

    func periodSummary(_ a: MCPArgs) throws -> String {
        let period = try a.string("period") ?? "week"
        guard ["week", "month"].contains(period) else { throw MCPToolError("period must be week or month") }
        let raw = try a.string("date") ?? a.string("day")
        let month = period == "month" && raw?.count == 7 ? raw : nil
        let d = month == nil ? try a.day("date", old: "day") ?? Time.dayString(now()) : ""
        guard let (from, to) = period == "week" ? DaySummary.week(of: d) : DaySummary.month(month ?? String(d.prefix(7))) else {
            throw MCPToolError("date must be a date YYYY-MM-DD" + (period == "month" ? " or a month YYYY-MM" : ""))
        }
        let head = "\(period) \(from) … \(to)"
        if let k = try kept(SummaryDoc.key(from, to)) {
            return "\(head), summary written \(Txt.when(k.created, now: now()))\(k.mark):\n" + k.text(markdown: false)
        }
        var docs: [SummaryDoc] = [], noAI: [String] = []
        for day in DaySummary.range(from, to) {
            guard let k = try kept(day), let doc = k.doc else { continue }
            docs.append(doc)
            if k.whyNoAI != nil { noAI.append(day) }
        }
        guard !docs.isEmpty else {
            return "\(head): no summaries kept. The service writes a day's summary each evening ([summary] time); "
                + "zagon summary --\(period) writes this one (AI calls)."
        }
        let doc = DaySummary.merge(docs, from: from, to: to, Words(en: docs[0].lang != "ru"))
        // ponytail: the days' cards joined without AI; zagon summary --week / --month writes a real one.
        let made = noAI.isEmpty ? "" : " (made without AI: \(noAI.joined(separator: ", ")))"
        return "\(head): no summary of the period kept; the \(Txt.count(docs.count, "day summary", "day summaries")) of it merged "
            + "without AI\(made):\n" + doc.text(markdown: false)
    }

    // MARK: search

    func search(_ a: MCPArgs) throws -> String {
        let text = try a.required("text"), limit = min(max(try a.int("limit") ?? 10, 1), 50)
        let from = try a.day("from").flatMap { Time.dayBounds($0)?.start }, to = try a.day("to").flatMap { Time.dayBounds($0)?.end }
        let hits = try reports.search(text, from: from, to: to)
        guard !hits.isEmpty else { return "No sessions match \"\(text)\"." }
        let head = hits.count == 1 ? "1 session matches" : "\(hits.count) sessions match"
        var out: [String] = ["\(head) \"\(text)\"" + (hits.count > limit ? ", showing \(limit)" : "") + ":"]
        let t = now()
        for h in hits.prefix(limit) {
            guard let s = try store.db.one("""
                SELECT tool, title, \(Projects.sessionSQL("session")), git_branch, last_at, cwd FROM session WHERE id=?
                """, [.text(h.sessionId)], { r in
                (tool: r.text(0) ?? "", title: r.text(1), project: r.text(2), branch: r.text(3), last: r.optReal(4), cwd: r.text(5))
            }) else { continue }
            var parts = ["\(s.tool) \(Txt.shortId(h.sessionId))", s.title.map { "\"\(Txt.oneLine($0, 60))\"" } ?? "(untitled)",
                         (s.project ?? "?") + (s.branch.map { " (\($0))" } ?? "")]
            var why: [String] = []
            if h.inTitle { why.append("title") }
            if h.messages > 0 { why.append("\(h.messages) message\(h.messages == 1 ? "" : "s")") }
            parts.append("matches: " + why.joined(separator: " + "))
            if let l = h.lastMatch ?? s.last { parts.append("last \(Txt.when(l, now: t))") }
            if let cmd = Self.resumeCommand(id: h.sessionId, tool: s.tool, cwd: s.cwd) { parts.append("resume: " + cmd) }
            out.append("- " + parts.joined(separator: " · "))
        }
        return out.joined(separator: "\n")
    }

    // MARK: export_day

    func exportDay(_ a: MCPArgs) throws -> String {
        let d = try a.day("date", old: "day") ?? Time.dayString(now())
        let r = try reports.day(d)
        let md = try markdown(r)
        guard Sys.mkdirs(exportDir), Sys.writeFile(exportDir + "/\(d).md", Array(md.utf8), mode: 0o600) else {
            throw MCPToolError("could not write \(exportDir)/\(d).md")
        }
        return "Wrote \(exportDir)/\(d).md (\(md.utf8.count) bytes): \(Txt.tokens(r.tokens.total)) tokens, sessions "
            + "\(Txt.dur(r.sessionSec)), the user \(Txt.dur(r.userSec)), \(r.sessions.count) sessions."
    }

    func markdown(_ r: DayReport) throws -> String {
        func cell(_ s: String) -> String { Txt.oneLine(s, 120).split(separator: "|", omittingEmptySubsequences: false).joined(separator: "\\|") }
        var md = "# \(r.day) (\(Txt.weekday(r.day)))\n\n"
        md += "- Tokens: \(Txt.tokenLine(r.tokens)), \(r.toolCalls) tool calls\n"
        md += "- Time: sessions \(Txt.dur(r.sessionSec)), you \(Txt.dur(r.userSec))\n"
        if let k = try kept(r.day) {
            md += "\n## What was done\n\n"
            if let why = k.whyNoAI { md += "_Made without AI: \(why)._\n\n" }
            md += k.text(markdown: true) + "\n"
        }
        if !r.sessions.isEmpty {
            md += "\n## Sessions\n\n| Session | Tool | Project | Branch | Tokens | Working |\n|---|---|---|---|---:|---:|\n"
            for s in r.sessions {
                md += "| \(cell(s.title ?? Txt.shortId(s.id))) | \(s.tool) | \(cell(s.project ?? "")) | \(cell(s.gitBranch ?? "")) | "
                    + "\(Txt.tokens(s.tokens.total)) | \(Txt.dur(s.workingSec)) |\n"
            }
        }
        if !r.projects.isEmpty {
            md += "\n## Projects\n\n| Project | Tool | Tokens | Time |\n|---|---|---:|---:|\n"
            for p in r.projects {
                md += "| \(cell(p.project.isEmpty ? "?" : p.project)) | \(p.tool) | \(Txt.tokens(p.tokens.total)) | \(Txt.dur(p.sessionSec)) |\n"
            }
        }
        if !r.models.isEmpty {
            md += "\n## Models\n\n| Model | Tokens | Share |\n|---|---:|---:|\n"
            for m in r.models { md += "| \(cell(m.model)) | \(Txt.tokens(m.tokens.total)) | \(Txt.share(m.tokens.total, r.tokens.total)) |\n" }
        }
        if !r.tools.isEmpty { md += "\n## Tools\n\n" + r.tools.map { "\($0.name) \($0.count)" }.joined(separator: " · ") + "\n" }
        return md
    }
}

/// Short text pieces for answers.
enum Txt {
    static func tokens(_ n: Int) -> String {
        func one(_ d: Double) -> String { let v = (d * 10).rounded() / 10; return v >= 100 ? "\(Int(v))" : "\(v)" }
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return one(Double(n) / 1e3) + "k"
        case ..<1_000_000_000: return one(Double(n) / 1e6) + "M"
        default: return one(Double(n) / 1e9) + "B"
        }
    }

    static func tokenLine(_ t: TokenTotals) -> String {
        "\(tokens(t.total)) tokens (input \(tokens(t.input)), output \(tokens(t.output)), cache read \(tokens(t.cacheRead)), "
            + "cache write \(tokens(t.cacheWrite))), \(t.requests) requests"
    }

    static func projects<S: Sequence>(_ ps: S) -> String where S.Element == ProjectLine {
        ps.map { "\($0.project.isEmpty ? "?" : $0.project) (\($0.tool)) \(tokens($0.tokens.total)), \(usd($0.cost, unpriced: $0.unpriced)), \(dur($0.sessionSec))" }
            .joined(separator: "; ")
    }

    /// USD at API list prices (as `zagon today`); tokens of models with no known price add "?": "$ ?" when nothing
    /// was priced, "$12+?" when part was.
    static func usd(_ x: Double, unpriced: Int = 0) -> String {
        let s = x > 0 && x < 1 ? "<$1" : "$\(Int(min(max(x, 0), 1e12).rounded()))"
        return unpriced == 0 ? s : x == 0 ? "$ ?" : s + "+?"
    }
    static let apiNote = "at API list prices (for comparison; a subscription is billed differently)"

    /// "1 session", "2 sessions".
    static func count(_ n: Int, _ one: String, _ many: String? = nil) -> String { "\(n) " + (n == 1 ? one : many ?? one + "s") }

    // Clamps below: values come from local files, and an absurd one must not trap an Int / time_t conversion.
    static func pct(_ p: Double) -> String { "\(Int(min(max(p, -1e6), 1e6).rounded()))%" }
    static func share(_ a: Int, _ b: Int) -> String { b == 0 ? "0%" : "\(Int((Double(a) / Double(b) * 100).rounded()))%" }
    static func change(_ a: Int, _ b: Int) -> String {
        guard b > 0 else { return a > 0 ? "new" : "same" }
        let c = Int((Double(a - b) / Double(b) * 100).rounded())
        return c >= 0 ? "+\(c)%" : "\(c)%"
    }

    static func dur(_ s: Double) -> String {
        let m = Int((min(max(s, 0), 1e12) / 60).rounded())
        if m < 60 { return "\(m)m" }
        if m < 48 * 60 { return "\(m / 60)h \(m % 60 < 10 ? "0" : "")\(m % 60)m" }
        return "\(m / 1440)d \(m % 1440 / 60)h"
    }

    static func ago(_ s: Double) -> String { s < 90 ? "just now" : dur(s) + " ago" }

    /// `HH:MM` today, `YYYY-MM-DD HH:MM` on other days (local time).
    static func when(_ ts0: Timestamp, now: Timestamp) -> String {
        let ts = min(max(ts0, -1e11), 1e11)
        var t = time_t(ts.rounded(.down)), tmv = tm()
        localtime_r(&t, &tmv)
        func p2(_ v: Int32) -> String { v < 10 ? "0\(v)" : "\(v)" }
        let clock = "\(p2(tmv.tm_hour)):\(p2(tmv.tm_min))"
        let d = Time.dayString(ts)
        return d == Time.dayString(now) ? clock : "\(d) \(clock)"
    }

    static func weekday(_ day: String) -> String {
        guard let (y, m, d) = Time.parseDay(day) else { return "" }
        let n = Time.daysFromCivil(y, m, d)   // 1970-01-01 was a Thursday
        return ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"][((n % 7) + 7) % 7]
    }

    static func shortId(_ id: String) -> String {
        String(id.drop { $0 != ":" }.dropFirst().prefix(8))
    }

    static func oneLine(_ s: String, _ max: Int) -> String {
        let flat = String(s.map { $0.isNewline || $0 == "\t" ? " " : $0 })
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }
}
