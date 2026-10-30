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
        let r = ReportTools(store: store, exportDir: exportDir, refresh: refresh, now: now, log: log)
        return MCPServer(tools: r.tools + ServiceTools.tools(handoff: handoff, tasks: tasks) + (paths.map(SettingsTools.tools) ?? []),
                         prompts: [ServiceTools.resume(handoff)], log: log)
    }
}

extension ZagonMCP {
    /// The text of the `limits` tool (also printed by `zagon today`).
    public static func limitsText(store: Store, now: Timestamp = Time.now()) throws -> String {
        try ReportTools(store: store, exportDir: "", refresh: nil, now: { now }, log: { _ in }).limits(MCPArgs(.object([])))
    }
}

/// limits, sessions, day, week, range, search, export_day over `Store` / `Reports`.
final class ReportTools {
    let store: Store
    let reports: Reports
    let exportDir: String
    let refresh: (() throws -> Void)?
    let now: () -> Timestamp
    let log: (String) -> Void

    init(store: Store, exportDir: String, refresh: (() throws -> Void)?, now: @escaping () -> Timestamp,
         log: @escaping (String) -> Void) {
        self.store = store; reports = Reports(store: store); self.exportDir = exportDir; self.refresh = refresh
        self.now = now; self.log = log
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
            t("limits", "Subscription limits",
              "Claude Code and Codex subscription limits: % used of the 5-hour and weekly windows, reset time, and a "
              + "forecast at the current pace.", ReportTools.limits),
            t("sessions", "Sessions",
              "Recent sessions (Claude Code and Codex) with live status, how long each has waited for the user, tokens, "
              + "and the command to resume it. Waiting sessions come first. With `day`: sessions active that day.",
              schema: MCPSchema.object(["day": MCPSchema.day("Only sessions active on this day"),
                                "limit": MCPSchema.integer("How many (default 10)", min: 1, max: 50)]),
              ReportTools.sessions),
            t("day", "Day report",
              "One day: tokens by kind, requests, session time and the user's own time, models, projects, tools, busiest "
              + "hours, top sessions, and the day's summary if there is one.",
              schema: MCPSchema.object(["date": MCPSchema.day("The day (default today)")]), ReportTools.day),
            t("week", "Week report",
              "Seven days from `start` (default: the 7 days ending today): totals vs the previous 7 days, each day, top "
              + "projects.", schema: MCPSchema.object(["start": MCPSchema.day("First day of the week")]), ReportTools.week),
            t("range", "Range report",
              "Totals for the days from `from` to `to` (inclusive, at most 366 days): tokens, time, models, projects, days.",
              schema: MCPSchema.object(["from": MCPSchema.day("First day"), "to": MCPSchema.day("Last day (default today)")],
                               required: ["from"]), ReportTools.range),
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
        return try all.map { s in
            var line = "\(s.tool == .claude ? "Claude" : "Codex") \(Self.window(s.window, s.windowMinutes)): "
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
        guard let first = try store.db.one("""
            SELECT used_pct, ts FROM limit_snapshot WHERE tool=? AND window=? AND ts >= ? AND ts <= ? AND resets_at IS NOT NULL
              AND abs(resets_at - ?) < 120 ORDER BY ts LIMIT 1
            """, [.text(s.tool.rawValue), .text(s.window), .real(s.ts - 3600), .real(s.ts - 600), .real(r)],
            { ($0.real(0), $0.real(1)) }) else { return nil }
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

    /// Waiting for the user: a driven worker waiting for input waits for its driver.
    static func waiting(_ s: SessionLine) -> Bool {
        s.status == "waiting_permission" || (s.status == "waiting_input" && s.driver == nil)
    }

    func sessions(_ a: MCPArgs) throws -> String {
        let limit = min(max(try a.int("limit") ?? 10, 1), 50)
        var list: [SessionLine]
        if let d = try a.day("day"), let (s, e) = Time.dayBounds(d) {
            list = try reports.sessions(from: s, to: e, limit: limit)
            if list.isEmpty { return "No sessions on \(d)." }
        } else {
            list = try reports.sessions(limit: limit)
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
        let nWait = list.filter(Self.waiting).count, nWork = list.filter { $0.status == "working" }.count
        var out = ["\(list.count) sessions: \(nWait) waiting for the user, \(nWork) working"]
        for s in list {
            let x = extras[s.id] ?? SessionExtra()
            var parts = ["\(s.tool) \(Txt.shortId(s.id))", s.title.map { "\"\(Txt.oneLine($0, 60))\"" } ?? "(untitled)"]
            parts.append((s.project ?? "?") + (s.gitBranch.map { " (\($0))" } ?? ""))
            if let st = s.status {
                var label = ["waiting_input": "waiting for input", "waiting_permission": "waiting for permission"][st] ?? st
                if st == "waiting_input", let d = s.driver { label = d.isEmpty ? "waiting for another session" : "waiting for session \(d)" }
                parts.append(label + (x.statusAt.map { " \(Txt.dur(t - $0))" } ?? ""))
            }
            if let l = s.lastAt { parts.append("last active \(Txt.when(l, now: t))") }
            parts.append("\(Txt.tokens(s.tokens.total)) tokens, working \(Txt.dur(s.workingSec))")
            if let cmd = Self.resumeCommand(id: s.id, tool: s.tool, cwd: x.cwd) { parts.append("resume: " + cmd) }
            out.append("- " + parts.joined(separator: " · "))
        }
        return out.joined(separator: "\n")
    }

    static func resumeCommand(id: String, tool: String, cwd: String?) -> String? {
        let native = String(id.drop { $0 != ":" }.dropFirst())
        guard !native.isEmpty else { return nil }
        let id = Sys.shellQuote(native)
        let cmd = tool == "codex" ? "codex resume \(id)" : "claude --resume \(id)"
        return cwd.map { "cd \(Sys.shellQuote($0)) && \(cmd)" } ?? cmd
    }

    // MARK: day / week / range

    func day(_ a: MCPArgs) throws -> String {
        let d = try a.day("date") ?? Time.dayString(now())
        let r = try reports.day(d)
        if r.tokens.total == 0 && r.sessionSec == 0 && r.sessions.isEmpty { return "\(d): no activity recorded." }
        var out = ["\(d) (\(Txt.weekday(d))): " + Txt.tokenLine(r.tokens) + ", \(r.toolCalls) tool calls",
                   "time: sessions \(Txt.dur(r.sessionSec)), the user \(Txt.dur(r.userSec)); \(r.sessions.count) sessions"]
        if !r.models.isEmpty {
            out.append("models: " + r.models.prefix(5).map {
                "\($0.model) \(Txt.tokens($0.tokens.total)) (\(Txt.share($0.tokens.total, r.tokens.total)))"
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
                out.append("- \(s.tool) \(Txt.shortId(s.id)) \(s.title.map { "\"\(Txt.oneLine($0, 60))\"" } ?? "(untitled)") · "
                           + "\(s.project ?? "?") · \(Txt.tokens(s.tokens.total)) tokens, working \(Txt.dur(s.workingSec))")
            }
        }
        if let sum = try summary(d) { out.append("summary: " + Txt.oneLine(sum, 600)) }
        return out.joined(separator: "\n")
    }

    func summary(_ d: String) throws -> String? {
        try store.db.one("SELECT text FROM summary WHERE day=? ORDER BY created DESC LIMIT 1", [.text(d)]) { $0.text(0) } ?? nil
    }

    func week(_ a: MCPArgs) throws -> String {
        let end = try a.day("start").flatMap { Time.addDays($0, 6) } ?? Time.dayString(now())
        let w = try reports.week(ending: end)
        var out = ["\(w.from) … \(w.to): " + Txt.tokenLine(w.tokens)
                   + " (\(Txt.change(w.tokens.total, w.previous.total)) vs the 7 days before: \(Txt.tokens(w.previous.total)))",
                   "time: sessions \(Txt.dur(w.sessionSec)) (before \(Txt.dur(w.previousSessionSec))), the user "
                   + "\(Txt.dur(w.userSec)) (before \(Txt.dur(w.previousUserSec)))",
                   "days:"]
        for d in w.days {
            out.append("- \(d.day) \(Txt.weekday(d.day)): \(Txt.tokens(d.tokens.total)) tokens, sessions \(Txt.dur(d.sessionSec)), "
                       + "the user \(Txt.dur(d.userSec))")
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
        var tokens = TokenTotals(), ss = 0.0, us = 0.0, calls = 0
        var models: [String: TokenTotals] = [:], projects: [ProjectLine] = [], perDay: [(String, TokenTotals, Double)] = []
        for d in days {
            let r = try reports.day(d, withSessions: false)
            tokens.add(r.tokens); ss += r.sessionSec; us += r.userSec; calls += r.toolCalls
            for m in r.models { models[m.model, default: TokenTotals()].add(m.tokens) }
            for p in r.projects {
                if let i = projects.firstIndex(where: { $0.tool == p.tool && $0.project == p.project }) {
                    projects[i].tokens.add(p.tokens); projects[i].sessionSec += p.sessionSec; projects[i].toolCalls += p.toolCalls
                } else { projects.append(p) }
            }
            if r.tokens.total > 0 || r.sessionSec > 0 { perDay.append((d, r.tokens, r.sessionSec)) }
        }
        var out = ["\(from) … \(to) (\(days.count) days, \(perDay.count) active): " + Txt.tokenLine(tokens) + ", \(calls) tool calls",
                   "time: sessions \(Txt.dur(ss)), the user \(Txt.dur(us))"]
        if !models.isEmpty {
            out.append("models: " + models.sorted { $0.value.total > $1.value.total }.prefix(5).map {
                "\($0.key) \(Txt.tokens($0.value.total)) (\(Txt.share($0.value.total, tokens.total)))"
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

    // MARK: search

    func search(_ a: MCPArgs) throws -> String {
        let text = try a.required("text"), limit = min(max(try a.int("limit") ?? 10, 1), 50)
        let from = try a.day("from").flatMap { Time.dayBounds($0)?.start }, to = try a.day("to").flatMap { Time.dayBounds($0)?.end }
        let hits = try reports.search(text, from: from, to: to)
        guard !hits.isEmpty else { return "No sessions match \"\(text)\"." }
        var out = ["\(hits.count) sessions match \"\(text)\"" + (hits.count > limit ? ", showing \(limit)" : "") + ":"]
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
        let d = try a.day("date") ?? Time.dayString(now())
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
        if let s = try summary(r.day) { md += "\n## What was done\n\n\(s)\n" }
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
        ps.map { "\($0.project.isEmpty ? "?" : $0.project) (\($0.tool)) \(tokens($0.tokens.total)), \(dur($0.sessionSec))" }
            .joined(separator: "; ")
    }

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
