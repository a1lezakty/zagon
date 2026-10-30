/// Telegram commands via long-poll `getUpdates`: `/limits /sessions /today /week /day <date> /tz [zone]` and inline
/// buttons.
/// Only the configured chat is answered; updates from anyone else are skipped (their offset is still confirmed).
/// The offset lives in `meta` (`telegram:offset`) so a restart does not answer twice.
public final class Bot {
    public let telegram: Telegram
    public let store: Store
    /// Buttons whose data is not built in (`resume:`, `day:`), e.g. the worklog plan's "Log / Edit / Later" from
    /// the tasks package. Returns the reply; nil = nothing to say.
    public var onCallback: ((_ data: String) throws -> Message?)?
    public var log: (String) -> Void = { print($0) }
    /// Where config.toml is (`/tz` writes it); nil = `/tz` only shows the zone.
    public var paths: ZagonPaths?
    /// Runs after `/tz <zone>` wrote config.toml: switch this process to the new zone (a service restarts itself).
    /// The reply "zone, local time" is sent once the zone is in effect, by this process or the restarted one.
    public var onTimezoneChange: () -> Void = {}
    /// Language of the replies (`[notify] lang`).
    public var lang: NotifyLang
    var w: Words { lang.words() }

    public init(telegram: Telegram, store: Store, paths: ZagonPaths? = nil, lang: NotifyLang = .auto) {
        self.telegram = telegram; self.store = store; self.paths = paths; self.lang = lang
    }

    var offset: Int {
        get { (try? store.db.one("SELECT value FROM meta WHERE key = 'telegram:offset'") { $0.int(0) }) ?? 0 }
        set { _ = try? store.db.run("INSERT INTO meta(key, value) VALUES('telegram:offset', ?1) ON CONFLICT(key) DO UPDATE SET value = ?1",
                                    [.int(Int64(newValue))]) }
    }

    /// One `getUpdates` call (waits up to `timeout` seconds for something new); returns how many updates came.
    @discardableResult
    public func pollOnce(timeout: Int = 50) -> Int {
        let body = JValue.object([.init("offset", .number(String(offset))), .init("timeout", .number(String(timeout))),
                                  .init("allowed_updates", .array([.string("message"), .string("callback_query")]))])
        sendTimezoneReply()
        guard let updates = telegram.call("getUpdates", body, timeout: Double(timeout + 10))?.array else { return 0 }
        for u in updates {
            if let id = u["update_id"]?.double { offset = max(offset, Int(id) + 1) }
            handle(u)
        }
        return updates.count
    }

    func handle(_ u: JValue, now: Double = Sys.now()) {
        if let m = u["message"], m["chat"]?["id"] == Telegram.chat(telegram.chatId), let text = m["text"]?.string, text.hasPrefix("/") {
            let parts = text.split(separator: " ").map(String.init)
            let cmd = String(parts[0].split(separator: "@").first ?? "")
            log("bot: \(cmd)")
            if cmd == "/tz", let zone = parts.dropFirst().first, let paths {
                if let m = setTimezone(zone, paths) { _ = telegram.send(m) } else { onTimezoneChange(); sendTimezoneReply(now: now) }
                return
            }
            _ = telegram.send(reply(cmd, Array(parts.dropFirst()), now: now))
        } else if let q = u["callback_query"], q["message"]?["chat"]?["id"] == Telegram.chat(telegram.chatId),
                  let id = q["id"]?.string, let data = q["data"]?.string {
            _ = telegram.call("answerCallbackQuery", .object([.init("callback_query_id", .string(id))]))
            log("bot: button \(data.split(separator: ":").first ?? "")")
            if let m = (try? callback(data, now: now)) ?? nil { _ = telegram.send(m) }
        }
    }

    func callback(_ data: String, now: Double) throws -> Message? {
        if data.hasPrefix("day:") { return reply("/day", [String(data.dropFirst(4))], now: now) }
        if data.hasPrefix("resume:") {
            let id = String(data.dropFirst(7))
            let native = id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? id
            let cwd = try store.db.one("SELECT cwd FROM session WHERE id = ?", [.text(id)]) { $0.text(0) } ?? nil
            let cmd = id.hasPrefix("codex:") ? "codex resume \(native)" : "claude --resume \(native)"
            return Message(title: "", text: (cwd.map { "cd \(Sys.shellQuote($0)) && " } ?? "") + cmd)
        }
        return try onCallback?(data)
    }

    // MARK: time zone

    /// `/tz <zone>` (`system` = the zone of the machine): writes config.toml and leaves a note for the reply.
    /// Returns the reply only when nothing changed (unknown zone, cannot write).
    func setTimezone(_ zone: String, _ paths: ZagonPaths) -> Message? {
        let z: String? = ["system", "системный"].contains(zone.lowercased()) ? nil : zone
        guard z.map(Settings.isZone) ?? true else {
            return Message(title: "", text: w.t("Нет такого пояса: \(zone).", "No such time zone: \(zone).") + w.t(" Пример", " Example")
                           + ": /tz Asia/Almaty, /tz system")
        }
        do { try Settings.setTimezone(paths, z) } catch { return Message(title: "", text: w.t("Ошибка: ", "Error: ") + "\(error)") }
        _ = try? store.db.run("INSERT INTO meta(key, value) VALUES('telegram:tz_reply', '1') ON CONFLICT(key) DO UPDATE SET value = '1'")
        return nil
    }

    /// The reply to `/tz <zone>`, once this process cuts time in that zone; then the note is dropped.
    func sendTimezoneReply(now: Double = Sys.now()) {
        guard let paths, Settings.timezoneApplied(paths),
              (try? store.db.one("SELECT 1 FROM meta WHERE key = 'telegram:tz_reply'") { $0.int(0) }) != nil else { return }
        _ = try? store.db.run("DELETE FROM meta WHERE key = 'telegram:tz_reply'")
        _ = telegram.send(Message(title: "", text: timezoneText(now: now)))
    }

    /// `Пояс Asia/Almaty, сейчас 19:20` (`системный` when config.toml sets none).
    func timezoneText(now: Double) -> String {
        let own = paths.flatMap(Settings.timezone) != nil
        return w.t("Пояс", "Time zone") + " \(Settings.zoneName())\(own ? "" : w.t(" (системный)", " (system)")), "
            + w.t("сейчас", "now") + " \(w.clock(now))"
    }

    // MARK: replies

    public func reply(_ cmd: String, _ args: [String], now: Double = Sys.now()) -> Message {
        do {
            switch cmd {
            case "/limits": return Message(title: w.t("Лимиты", "Limits"), text: try limits(now: now))
            case "/sessions": return Message(title: w.t("Сессии", "Sessions"), text: try sessions(now: now))
            case "/today": return try day(Time.dayString(now))
            case "/day":
                guard let d = args.first, Time.parseDay(d) != nil else { return Message(title: "", text: w.t("Формат", "Format") + ": /day 2026-10-29") }
                return try day(d)
            case "/week": return Message(title: w.t("Неделя", "Week"), text: try week(Time.dayString(now)))
            case "/tz": return Message(title: "", text: timezoneText(now: now))
            default:
                return Message(title: "Zagon", text: w.t("/limits — лимиты\n/sessions — сессии\n/today — сегодня\n/week — неделя\n"
                                                         + "/day 2026-10-29 — день\n/tz — часовой пояс, /tz Asia/Almaty — сменить",
                                                         "/limits — limits\n/sessions — sessions\n/today — today\n/week — week\n"
                                                         + "/day 2026-10-29 — a day\n/tz — time zone, /tz Asia/Almaty — change it"))
            }
        } catch {
            return Message(title: "", text: w.t("Ошибка: ", "Error: ") + "\(error)")
        }
    }

    func limits(now: Double) throws -> String {
        let n = Notifier(store: store, config: NotifyConfig(), channels: [])
        var lines: [String] = []
        var newest = 0.0
        for s in try store.latestLimits() {
            let over = s.resetsAt.map { $0 <= now } ?? false
            var l = "\(w.tool(s.tool)) \(w.window(s)): " + (over ? w.t("сброшен", "reset") : w.pct(s.usedPct))
            if let r = s.resetsAt, !over { l += w.t(" · сброс ", " · resets ") + w.when(r, now: now) }
            if !over, let eta = try n.forecast(s) { l += w.t("\n  кончится к \(w.clock(eta)) при таком темпе", "\n  runs out by \(w.clock(eta)) at this pace") }
            lines.append(l)
            newest = max(newest, s.ts)
        }
        guard !lines.isEmpty else {
            return w.t("Данных о лимитах ещё нет (их приносит строка состояния Claude Code и логи Codex).",
                       "No limit data yet (it comes from the Claude Code status line and the Codex logs).")
        }
        return lines.joined(separator: "\n") + w.t("\n(данные \(w.dur(now - newest)) назад)", "\n(data from \(w.dur(now - newest)) ago)")
    }

    func sessions(now: Double) throws -> String {
        var lines: [String] = []
        try store.db.query("""
            SELECT tool, title, project, status, status_at, last_at FROM session
            WHERE coalesce(archived, 0) = 0 AND coalesce(status, '') <> 'ended' AND max(coalesce(status_at, 0), coalesce(last_at, 0)) > ?
            ORDER BY CASE WHEN status LIKE 'waiting%' THEN 0 WHEN status = 'working' THEN 1 ELSE 2 END,
                     max(coalesce(status_at, 0), coalesce(last_at, 0)) DESC LIMIT 12
            """, [.real(now - 86400)]) { r in
            let since = r.optReal(4) ?? r.optReal(5) ?? now
            let state: String
            switch r.text(3) {
            case "waiting_permission": state = w.t("⏳ ждёт разрешения ", "⏳ waits for permission ") + w.dur(now - since)
            case "waiting_input": state = w.t("⏳ ждёт тебя ", "⏳ waits for you ") + w.dur(now - since)
            case "working": state = w.t("▶ работает", "▶ working")
            default: state = "· " + w.t("\(w.dur(now - (r.optReal(5) ?? since))) назад", "\(w.dur(now - (r.optReal(5) ?? since))) ago")
            }
            lines.append("\(state) · \(w.name(r.text(2), r.text(1)))")
        }
        return lines.isEmpty ? w.t("За сутки сессий не было.", "No sessions in the last 24 hours.") : lines.joined(separator: "\n")
    }

    func day(_ d: String) throws -> Message {
        let r = try Reports(store: store).day(d)
        var lines = [w.t("Сессии \(w.dur(r.sessionSec)) · ты \(w.dur(r.userSec))", "Sessions \(w.dur(r.sessionSec)) · you \(w.dur(r.userSec))"),
                     w.t("\(w.tokens(r.tokens.total)) токенов · \(r.tokens.requests) запросов",
                         "\(w.tokens(r.tokens.total)) tokens · \(r.tokens.requests) requests")]
        for p in r.projects.prefix(6) {
            lines.append("• \(p.project.isEmpty ? w.tool(p.tool) : p.project) — \(w.dur(p.sessionSec)) · \(w.tokens(p.tokens.total))")
        }
        let total = max(1, r.models.reduce(0) { $0 + $1.tokens.total })
        if !r.models.isEmpty {
            lines.append(w.t("Модели: ", "Models: ") + r.models.prefix(4).map { "\($0.model) \(w.pct(Double($0.tokens.total) / Double(total) * 100))" }
                .joined(separator: ", "))
        }
        if let s = try store.db.one("SELECT text FROM summary WHERE day = ? ORDER BY engine = 'none', created DESC LIMIT 1",
                                    [.text(d)], { $0.text(0) }),
           let s { lines.append("\n" + (SummaryDoc.decode(s)?.text() ?? s)) }
        return Message(title: w.date(d), text: lines.joined(separator: "\n"))
    }

    func week(_ end: String) throws -> String {
        let r = try Reports(store: store).week(ending: end)
        var head = w.t("Сессии \(w.dur(r.sessionSec)) · ты \(w.dur(r.userSec)) · \(w.tokens(r.tokens.total)) токенов",
                       "Sessions \(w.dur(r.sessionSec)) · you \(w.dur(r.userSec)) · \(w.tokens(r.tokens.total)) tokens")
        if r.previous.total > 0 {
            let d = (Double(r.tokens.total) / Double(r.previous.total) - 1) * 100
            head += " (\(d >= 0 ? "+" : "−")\(w.pct(abs(d))) " + w.t("к прошлой)", "vs last week)")
        }
        var lines = [head]
        for d in r.days {
            lines.append("\(w.weekday(d.day)) \(d.day.suffix(5)) · \(w.dur(d.sessionSec)) · \(w.tokens(d.tokens.total))")
        }
        let top = r.projects.prefix(4).map { "\($0.project.isEmpty ? w.tool($0.tool) : $0.project) \(w.tokens($0.tokens.total))" }
        if !top.isEmpty { lines.append(w.t("Проекты: ", "Projects: ") + top.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }
}
