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
        commandName: "summary", abstract: "What was done on a day (AI or plain), with the day ribbon picture.")
    @Argument(help: "YYYY-MM-DD (default: today).") var date: String?
    @OptionGroup var common: Common
    @Option(help: "claude | codex | none (default: [summary] engine).") var engine: String?
    @Option(help: "Write the ribbon PNG here.") var png: String?
    @Flag(help: "Also send it to the configured channels.") var send = false
    @Option(help: "Text put before the title when sending.") var titlePrefix = ""

    func validate() throws { if let date, Time.parseDay(date) == nil { throw ValidationError("date must be YYYY-MM-DD") } }

    func run() throws {
        let s = try NotifyCommand.Setup(common)
        let day = date ?? Time.dayString(Time.now())
        let t0 = Time.monotonic()
        var m = try s.summary(common, engine: engine).message(day)
        let engineUsed = try s.store.db.one("SELECT engine FROM summary WHERE day = ? ORDER BY created DESC LIMIT 1", [.text(day)]) { $0.text(0) } ?? nil
        print(m.text)
        print("\n(\(engineUsed ?? "?"), \(Int((Time.monotonic() - t0) * 1000)) ms, picture \(m.photo?.count ?? 0) bytes)")
        if let png, let p = m.photo, !Sys.writeFile(png, p) { throw ValidationError("cannot write \(png)") }
        guard send else { return }
        m.title = titlePrefix + m.title
        for c in s.channels { print("\(c.name): \(c.send(m) ? "sent" : "FAILED")") }
    }
}
