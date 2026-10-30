import ArgumentParser
import ZagonCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Notifications and the Telegram bot (`[notify]`, `[telegram]`, `[ntfy]` in config.toml).
struct NotifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notify", abstract: "Notifications (Telegram, ntfy) and the Telegram bot.",
        subcommands: [Run.self, Test.self])

    /// Store, config and channels for one run.
    struct Setup {
        let paths: ZagonPaths, config: NotifyConfig, store: Store, channels: [any Channel]
        init(_ common: Common) throws {
            paths = ZagonPaths(dir: common.dataDir)
            config = NotifyConfig.load(paths)
            Settings.applyTimezone(paths)
            store = try common.open()
            channels = config.channels(paths)
        }
        func summary(_ common: Common, engine: String? = nil) -> DaySummary {
            var s = DaySummary(store: store, config: config, paths: paths, claudeRoot: common.claudeDir)
            if let engine { s.config.summaryEngine = engine }
            s.log = { print($0) }
            return s
        }
    }

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Collect hook events and transcripts, send due notifications, answer bot commands (loop).")
        @OptionGroup var common: Common
        @Flag(help: "One pass, then exit.") var once = false
        @Option(help: "Text put before every title, e.g. for a trial run.") var titlePrefix = ""

        func run() throws {
            let s = try Setup(common)
            guard !s.channels.isEmpty else { throw ValidationError("no channel configured: [telegram] token_file + chat_id, or [ntfy] topic") }
            let n = Notifier(store: s.store, config: s.config, channels: s.channels)
            n.titlePrefix = titlePrefix
            let summary = s.summary(common)
            n.summary = { try summary.message($0) }
            let bot = s.config.telegramCommands ? s.channels.compactMap { $0 as? Telegram }.first.map { Bot(telegram: $0, store: s.store, paths: s.paths, lang: s.config.lang) } : nil
            bot?.onTimezoneChange = { Settings.applyTimezone(s.paths) }  // one thread here: switch in place
            do {
                let suggest = try common.suggester(s.store)
                n.worklogPlan = { [bot] in try suggest.message($0, buttons: bot != nil) }
                bot?.onCallback = { try suggest.callback($0) }
            } catch { print("task suggestions off: \(error)") }
            repeat {
                Settings.applyTimezone(s.paths)  // follows `zagon tz` / MCP; the scan rebuilds days on a change
                do { try SpoolIngest.run(store: s.store, spoolDir: s.paths.spool) } catch { print("spool: \(error)") }
                do { try common.ingest(s.store).scan() } catch { print("scan: \(error)") }
                do { try n.tick() } catch { print("notify: \(error)") }
                if let bot { bot.pollOnce(timeout: once ? 0 : 25) } else if !once { sleep(30) }
            } while !once
        }
    }

    struct Test: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Send a test message to every configured channel.")
        @OptionGroup var common: Common
        @Option(help: "Message text (default: a check message in the [notify] lang).") var text: String?

        func run() throws {
            let s = try Setup(common)
            guard !s.channels.isEmpty else { throw ValidationError("no channel configured") }
            var failed = false
            let w = s.config.lang.words()
            let m = Message(title: w.t("[тест Zagon]", "[Zagon test]"),
                            text: text ?? w.t("Проверка связи: уведомления Zagon работают.", "Connection check: Zagon notifications work."))
            for c in s.channels {
                let ok = c.send(m)
                print("\(c.name): \(ok ? "sent" : "FAILED")")
                failed = failed || !ok
            }
            if failed { throw ExitCode(1) }
        }
    }
}

struct SummaryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summary",
        abstract: "What was done on a day, a week, a month or any range: an overview and a card per task or theme.",
        discussion: """
            A day's summary is written once (one AI call, [summary] engine) and kept: shown again without a call until \
            --refresh. A period is made from its days' summaries; days without one are written first only with --yes \
            (--plan shows how many AI calls that takes). --at sets when the service writes the day summary.
            """)
    @Argument(help: "YYYY-MM-DD (default: today), the week of it with --week, YYYY-MM with --month.") var date: String?
    @OptionGroup var common: Common
    @Flag(help: "The week (Monday to Sunday) of the date.") var week = false
    @Flag(help: "The month YYYY-MM (default: this one).") var month = false
    @Option(help: "First day of a range (with --to).") var from: String?
    @Option(help: "Last day of a range (with --from).") var to: String?
    @Flag(help: "Write it again (another AI call) instead of showing the kept one.") var refresh = false
    @Flag(help: "Period: list the days without a summary and the AI calls it would take, write nothing.") var plan = false
    @Flag(help: "Period: write the missing days' summaries first (one AI call each).") var yes = false
    @Flag(help: "Print JSON.") var json = false
    @Option(help: "claude | codex | none (default: [summary] engine).") var engine: String?
    @Option(help: "Day: write the ribbon PNG here.") var png: String?
    @Flag(help: "Day: also send it to the configured channels.") var send = false
    @Option(help: "Text put before the title when sending.") var titlePrefix = ""
    @Option(help: "HH:MM or off: when the service writes the day summary ([summary] time in config.toml).") var at: String?

    struct Kept: Encodable { var key: String, engine: String, created: Double, doc: SummaryDoc }
    struct Plan: Encodable { var key: String, from: String, to: String, worked: [String], missing: [String], calls: Int }

    var isPeriod: Bool { week || month || from != nil || to != nil }

    func validate() throws {
        if let at, at != "off", at.split(separator: ":").count != 2 { throw ValidationError("--at takes HH:MM or off") }
        if month {
            if let date, DaySummary.month(date) == nil { throw ValidationError("with --month the date is YYYY-MM") }
        } else if let date, Time.parseDay(date) == nil { throw ValidationError("date must be YYYY-MM-DD") }
        if (from == nil) != (to == nil) { throw ValidationError("--from and --to go together") }
        if let from, let to {
            guard Time.parseDay(from) != nil, Time.parseDay(to) != nil, from <= to else { throw ValidationError("--from and --to: YYYY-MM-DD, from <= to") }
            guard DaySummary.range(from, to).last == to else { throw ValidationError("a range is at most \(DaySummary.maxDays) days") }
        }
        if [week, month, from != nil].filter({ $0 }).count > 1 { throw ValidationError("one of --week, --month, --from/--to") }
        if isPeriod && (png != nil || send) { throw ValidationError("--png and --send are for a day") }
    }

    func run() throws {
        let s = try NotifyCommand.Setup(common)
        if let at {
            do { try Settings.setSummaryTime(s.paths, at == "off" ? nil : at) } catch { throw ValidationError("\(error)") }
            if json { try emit(["at": at]) } else { print("day summary: " + (at == "off" ? "off" : "at \(at)")) }
            return
        }
        let summary = s.summary(common, engine: engine)
        let today = Time.dayString(Time.now())
        if !isPeriod {
            let day = date ?? today
            if !refresh, png == nil, !send, let k = try summary.kept(day) { return try show(day, k) }
            let t0 = Time.monotonic()
            var m = try summary.message(day)
            if json { return try show(day, try summary.kept(day)) }
            print(m.text)
            let used = try summary.kept(day)?.engine ?? "?"
            print("\n(\(used), \(Int((Time.monotonic() - t0) * 1000)) ms, picture \(m.photo?.count ?? 0) bytes)")
            if let png, let p = m.photo, !Sys.writeFile(png, p) { throw ValidationError("cannot write \(png)") }
            guard send else { return }
            m.title = titlePrefix + m.title
            for c in s.channels { print("\(c.name): \(c.send(m) ? "sent" : "FAILED")") }
            return
        }
        let range = from.flatMap { f in to.map { (from: f, to: $0) } }
            ?? (month ? DaySummary.month(date ?? String(today.prefix(7))) : DaySummary.week(of: date ?? today))
        guard let (a, b) = range else { throw ValidationError("cannot read the period") }
        let key = SummaryDoc.key(a, b)
        let (worked, missing) = try summary.days(a, b)
        let calls = summary.calls(missing: missing.count)
        if plan {
            if json { return try emit(Plan(key: key, from: a, to: b, worked: worked, missing: missing, calls: calls)) }
            print("\(a) to \(b): \(worked.count) days with sessions, \(missing.count) without a summary; \(calls) AI calls to write it")
            return
        }
        if !refresh, let k = try summary.kept(key) { return try show(key, k) }
        if !missing.isEmpty && calls > 0 && !yes {
            warn("\(missing.count) days have no summary yet: \(calls) AI calls in all. Run again with --yes, or see them with --plan.")
            throw ExitCode(3)
        }
        try summary.period(a, b, make: yes, progress: { n, of, day in
            warn("day \(n)/\(of): \(day)")
        })
        try show(key, try summary.kept(key))
    }

    func show(_ key: String, _ k: DaySummary.Kept?) throws {
        guard let k else { throw ValidationError("nothing kept for \(key)") }
        if json { return try emit(Kept(key: key, engine: k.engine, created: k.created, doc: k.doc)) }
        print(k.doc.text())
        var t = time_t(k.created.rounded(.down)), v = tm()
        localtime_r(&t, &v)
        let at = "\(v.tm_hour < 10 ? "0" : "")\(v.tm_hour):\(v.tm_min < 10 ? "0" : "")\(v.tm_min)"
        print("\n(\(k.engine), written \(Time.dayString(k.created)) \(at); --refresh writes it again)")
    }
}
