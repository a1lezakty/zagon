#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Turns the store's state (limits, hook statuses, working intervals, the clock) into notifications.
/// Every event has a key and an anchor (when this occurrence began); the last sent anchor per key lives in `meta`
/// (`notify:<key>`), so one occurrence gives one notification across restarts. Events older than an hour (the
/// service was down) and events inside quiet hours are marked as handled without being sent.
public final class Notifier {
    public struct Event {
        public var key: String
        /// Identifies this occurrence of `key` (session status time, limit reset time, local midnight…).
        public var anchor: Double
        /// Anchors closer than this count as the same occurrence (limit reset times drift for Codex).
        public var tolerance: Double = 0.5
        /// When the event became due.
        public var at: Double
        /// Not sent when older than this (seconds after `at`).
        public var staleAfter: Double = 3600
        /// Lower thresholds marked together with this one.
        public var alsoMark: [String] = []
        /// Other events handled by this one, with their own anchors (a done covers the wait of the same stop).
        public var covers: [String: Double] = [:]
        public var make: () throws -> Message?
    }

    public let store: Store
    public var config: NotifyConfig
    public var channels: [any Channel]
    /// Day summary message for a local day (`DaySummary`); nil = nothing to send.
    public var summary: ((String) throws -> Message?)?
    /// Worklog plan for a local day, provided by the tasks package; nil = not available.
    public var worklogPlan: ((String) throws -> Message?)?
    public var log: (String) -> Void = { print($0) }
    /// Put before every title (e.g. "[test] " for a trial run).
    public var titlePrefix = ""
    /// The wording of `config.lang`.
    var w: Words { config.lang.words() }
    /// Built messages that no channel accepted yet, with the anchor they were built for: retried next tick without
    /// rebuilding (the summary may call an AI), but only for the same occurrence.
    var pending: [String: (anchor: Double, message: Message)] = [:]
    /// Background tool calls per Claude Code transcript, read incrementally.
    var background: [String: BackgroundCalls] = [:]

    public init(store: Store, config: NotifyConfig, channels: [any Channel]) {
        self.store = store; self.config = config; self.channels = channels
    }

    // MARK: tick

    /// One pass: sends what became due. Returns the keys that were sent.
    @discardableResult
    public func tick(now: Double = Sys.now()) throws -> [String] {
        guard config.enabled else { return [] }
        var sent: [String] = []
        for e in try events(now: now).sorted(by: { $0.at < $1.at }) {
            if let prev = try state(e.key), abs(prev - e.anchor) <= e.tolerance { continue }
            if now - e.at > e.staleAfter { pending[e.key] = nil; try mark(e); continue }
            if let q = config.quiet, q.contains(Notifier.localMinute(now)) {
                // The day summary is still written (it is kept and shown in the app), only not sent.
                if e.key == "summary", pending[e.key] == nil {
                    do { _ = try e.make() } catch { log("notify: the day summary was not written: \(error)") }
                }
                log("notify: quiet hours, skipped \(e.key)"); pending[e.key] = nil; try mark(e); continue
            }
            let built = pending[e.key].flatMap { abs($0.anchor - e.anchor) <= e.tolerance ? $0.message : nil }
            guard var m = try built ?? e.make() else { pending[e.key] = nil; try mark(e); continue }
            if !m.title.hasPrefix(titlePrefix) { m.title = titlePrefix + m.title }
            let ok = channels.filter { $0.send(m) }.map(\.name)
            if ok.isEmpty && !channels.isEmpty {
                pending[e.key] = (e.anchor, m)
                log("notify: no channel accepted \(e.key), will retry")
                continue
            }
            pending[e.key] = nil
            try mark(e)
            log("notify: sent \(e.key) via \(ok.joined(separator: ","))")
            sent.append(e.key)
        }
        return sent
    }

    func state(_ key: String) throws -> Double? {
        try store.db.one("SELECT value FROM meta WHERE key = ?", [.text("notify:" + key)]) { $0.isNull(0) ? nil : $0.real(0) } ?? nil
    }

    func mark(_ e: Event) throws {
        try store.db.transaction {
            for (k, a) in ([e.key] + e.alsoMark).map({ ($0, e.anchor) }) + e.covers.map({ ($0.key, $0.value) }) {
                try store.db.run("INSERT INTO meta(key, value) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET value = ?2",
                                 [.text("notify:" + k), .real(a)])
            }
        }
    }

    public func events(now: Double) throws -> [Event] {
        try limitEvents(now: now) + resetEvents(now: now) + waitingEvents(now: now) + longWorkEvents(now: now)
            + clockEvents(now: now)
    }

    // MARK: limits

    func limitEvents(now: Double) throws -> [Event] {
        let w = self.w
        var out: [Event] = []
        for (s, label) in Accounts.labeled(try store.latestLimits(), now: now, localAccount: config.limitsAccount) {
            if let r = s.resetsAt, r <= now { continue }  // that window is over
            let crossed = config.thresholds(NotifyConfig.limitCategory(s.tool, s.window), account: s.account).filter { s.usedPct >= $0 }
            guard let top = crossed.last else { continue }
            let window = Double(s.windowMinutes ?? Notifier.defaultMinutes(s.window)) * 60
            let key = { (t: Double) in "limit:\(Store.limitKey(s)):\(Int(t))" }
            let who = w.tool(s.tool, account: label)
            let eta = try forecast(s)
            out.append(Event(key: key(top), anchor: s.resetsAt ?? s.ts, tolerance: s.resetsAt == nil ? window : window / 2,
                             at: s.ts, alsoMark: crossed.dropLast().map(key)) {
                var text = w.t("Сейчас \(w.pct(s.usedPct)).", "Now \(w.pct(s.usedPct)).")
                if let eta { text += w.t(" Кончится к \(w.clock(eta)) при таком темпе.", " Runs out by \(w.clock(eta)) at this pace.") }
                if let r = s.resetsAt { text += w.t(" Сброс \(w.when(r, now: now)).", " Resets \(w.when(r, now: now)).") }
                return Message(title: w.t("\(who): лимит \(w.window(s)) — \(w.pct(top))",
                                          "\(who): \(w.window(s)) limit — \(w.pct(top))"), text: text,
                               priority: top >= 95 ? 5 : 4, tags: ["warning"])
            })
        }
        return out
    }

    /// When the window runs out at the pace of the last hour, if before its reset.
    public func forecast(_ s: LimitSnapshot) throws -> Double? {
        guard let resets = s.resetsAt else { return nil }
        let first = try Store.paceBase(store.db, s, from: s.ts - 3600, to: s.ts)
        guard let (p0, t0) = first, s.ts - t0 >= 300, s.usedPct > p0 else { return nil }
        let eta = s.ts + (100 - s.usedPct) / ((s.usedPct - p0) / (s.ts - t0))
        return eta < resets ? eta : nil
    }

    func resetEvents(now: Double) throws -> [Event] {
        let w = self.w
        guard config.limitReset else { return [] }
        var out: [Event] = []
        // Named like the limit notifications: another account by its name, the default one only beside another's.
        let others = Set(Accounts.labeled(try store.latestLimits(), now: now, localAccount: nil).compactMap { $0.1 == nil ? nil : $0.0.tool })
        try store.db.query("""
            SELECT tool, window, resets_at, max(used_pct), max(window_minutes), account FROM limit_snapshot
            WHERE resets_at <= ? AND resets_at > ? GROUP BY tool, account, window, resets_at
            """, [.real(now), .real(now - 6 * 3600)]) { r in
            let account = r.text(5) ?? Accounts.defaultName
            guard let tool = ToolKind(rawValue: r.text(0) ?? ""),
                  let low = config.thresholds(NotifyConfig.limitCategory(tool, r.text(1) ?? ""), account: account).first,
                  r.real(3) >= low else { return }
            let s = LimitSnapshot(tool: tool, window: r.text(1) ?? "", usedPct: r.real(3), resetsAt: r.real(2),
                                  windowMinutes: r.optInt(4), ts: r.real(2), account: account)
            let window = Double(s.windowMinutes ?? Notifier.defaultMinutes(s.window)) * 60
            let who = w.tool(tool, account: account != Accounts.defaultName || others.contains(tool)
                                ? Accounts.label(account, localAccount: config.limitsAccount) : nil)
            out.append(Event(key: "reset:\(Store.limitKey(s))", anchor: r.real(2), tolerance: window / 2, at: r.real(2)) {
                Message(title: w.t("\(who): лимит \(w.window(s)) сбросился", "\(who): \(w.window(s)) limit reset"),
                        text: w.t("Было \(w.pct(s.usedPct)).", "Was \(w.pct(s.usedPct))."),
                        tags: ["white_check_mark"])
            })
        }
        return out
    }

    static func defaultMinutes(_ window: String) -> Int { ["five_hour": 300, "primary": 300, "seven_day": 10080, "secondary": 10080][window] ?? 300 }

    // MARK: sessions

    struct SessionRow {
        var id, tool: String; var title, project: String?; var status: String?; var statusAt, lastAt: Double?
        /// The session that drives it over tmux (`UserTime.driverSQL`); nil = you.
        var drivenBy: String? = nil
        /// The Claude Code account (`Accounts.tag` after the name).
        var account: String? = nil
        var shownProject: String? { project.map { $0 + Accounts.tag(account) } ?? (Accounts.tag(account).isEmpty ? nil : account) }
    }

    func session(_ id: String, now: Double) throws -> SessionRow? {
        try store.db.one("""
            SELECT id, tool, title, \(Projects.sessionSQL("session")), status, status_at, last_at, \(UserTime.driverSQL("session", now: now)),
                   account
            FROM session WHERE id = ?
            """, [.text(id)]) {
            SessionRow(id: $0.text(0) ?? "", tool: $0.text(1) ?? "", title: $0.text(2), project: $0.text(3), status: $0.text(4),
                       statusAt: $0.optReal(5), lastAt: $0.optReal(6), drivenBy: $0.text(7), account: $0.text(8))
        }
    }

    func waitingEvents(now: Double) throws -> [Event] {
        let w = self.w
        guard config.waitingMinutes > 0 else { return [] }
        let wait = config.waitingMinutes * 60
        var rows: [SessionRow] = []
        // The agent must have done something just before (a fresh or resumed session waiting for the first prompt is not news).
        try store.db.query("""
            SELECT id, tool, title, \(Projects.sessionSQL("session")), status, status_at, last_at, account FROM session
            WHERE status IN ('waiting_input', 'waiting_permission') AND status_at <= ? AND status_at > ?
              AND last_at >= status_at - 600 AND coalesce(archived, 0) = 0
              AND NOT (status = 'waiting_input' AND \(UserTime.driverSQL("session", now: now)) IS NOT NULL)  -- waits for its driver, not you
            """, [.real(now - wait), .real(now - wait - 86400)]) {
            rows.append(SessionRow(id: $0.text(0) ?? "", tool: $0.text(1) ?? "", title: $0.text(2), project: $0.text(3),
                                   status: $0.text(4), statusAt: $0.optReal(5), lastAt: $0.optReal(6), account: $0.text(7)))
        }
        return rows.map { s in
            let since = s.statusAt ?? now
            return Event(key: "wait:\(s.id)", anchor: since, at: since + wait) {
                let what = s.status == "waiting_permission" ? w.t("Просит разрешение.", "Asks for permission.")
                    : w.t("Ждёт ответа.", "Waits for your reply.")
                return Message(title: w.t("Ждёт тебя \(w.dur(now - since))", "Waiting for you \(w.dur(now - since))"),
                               text: "\(w.name(s.shownProject, s.title)). \(what)", priority: 4, tags: ["hourglass"],
                               buttons: Self.resume(s.id, w))
            }
        }
    }

    func longWorkEvents(now: Double) throws -> [Event] {
        let w = self.w
        guard config.longWorkMinutes > 0 else { return [] }
        var ids: [String] = []
        try store.db.query("SELECT DISTINCT session_id FROM activity WHERE kind = 'working' AND \"end\" > ?",
                           [.real(now - 3600)]) { if let id = $0.text(0) { ids.append(id) } }
        var out: [Event] = []
        for id in ids {
            var xs: [Interval] = []
            try store.db.query("SELECT start, \"end\" FROM activity WHERE kind = 'working' AND session_id = ? AND \"end\" > ?",
                               [.text(id), .real(now - 12 * 3600)]) { xs.append(Interval($0.real(0), $0.real(1))) }
            guard let last = Intervals.merge(xs).last, last.length >= config.longWorkMinutes * 60,
                  let s = try session(id, now: now), s.drivenBy == nil else { continue }  // a driven worker: its driver watches it
            let hookAt = s.statusAt.flatMap { $0 >= last.start ? $0 : nil }
            let doneAt: Double
            if let h = hookAt {
                guard s.status == "waiting_input" || s.status == "ended", h >= last.end - 120 else { continue }
                doneAt = h
            } else {
                guard now - last.end >= 600 else { continue }  // no hooks: 10 min of silence
                doneAt = last.end + 600
            }
            let anchor = last.start.rounded()
            if let prev = try state("done:\(id)"), abs(prev - anchor) <= 0.5 { continue }  // sent: skip the checks below
            // The turn ended but the session's own work goes on: it will continue by itself. Checked again next tick.
            if s.status != "ended", try busy(id, since: last.start, now: now) { continue }
            // The wait of this same stop is covered by the done (one message, not "done" and 10 min later "waiting").
            out.append(Event(key: "done:\(id)", anchor: anchor, at: doneAt, covers: hookAt.map { ["wait:\(id)": $0] } ?? [:]) {
                Message(title: w.t("Готово: ", "Done: ") + (s.project ?? w.tool(s.tool)),
                        text: "\(w.name(s.shownProject, s.title)) — " + w.t("работала \(w.dur(last.length)).", "worked \(w.dur(last.length))."),
                        tags: ["white_check_mark"], buttons: Self.resume(id, w))
            })
        }
        return out
    }

    /// The "resume command" button; none for Cursor (its conversations are opened in Cursor).
    static func resume(_ id: String, _ w: Words) -> [[Message.Button]] {
        id.hasPrefix("cursor:") ? [] : [[.init(w.t("Команда подключения", "Resume command"), "resume:\(id)")]]
    }

    /// The session's own work still running: a sub-agent log written in the last minute, or a `run_in_background`
    /// call of this stretch of work (since `since`) whose task-notification has not come yet (Claude Code).
    func busy(_ id: String, since: Double, now: Double) throws -> Bool {
        let subAgent = try store.db.one("""
            SELECT 1 FROM activity a JOIN source_file f ON f.id = a.file_id
            WHERE a.session_id = ? AND a.kind = 'working' AND f.agent <> '' AND a."end" >= ? AND a.start <= ? LIMIT 1
            """, [.text(id), .real(now - 60), .real(now)]) { _ in true } ?? false
        if subAgent { return true }
        guard id.hasPrefix("claude:"), let path = try store.db.one(
            "SELECT path FROM source_file WHERE session_id = ? AND agent = '' ORDER BY id DESC LIMIT 1", [.text(id)], { $0.text(0) }) ?? nil
        else { return false }
        background[path, default: BackgroundCalls()].update(path)
        return !(background[path]?.pending(since: since, now: now).isEmpty ?? true)
    }

    // MARK: clock

    func clockEvents(now: Double) throws -> [Event] {
        let day = Time.dayString(now)
        guard let (midnight, next) = Time.dayBounds(day) else { return [] }
        var out: [Event] = []
        for (key, at, make) in [("summary", config.summaryAt, summary), ("worklog", config.worklogAt, worklogPlan)] {
            guard let at, Notifier.localMinute(now) >= at else { continue }
            out.append(Event(key: key, anchor: midnight, at: midnight + Double(at) * 60, staleAfter: next - midnight) {
                try make?(day)
            })
        }
        return out
    }

    static func localMinute(_ t: Double) -> Int {
        var s = time_t(t.rounded(.down)), tmv = tm()
        localtime_r(&s, &tmv)
        return Int(tmv.tm_hour) * 60 + Int(tmv.tm_min)
    }
}
