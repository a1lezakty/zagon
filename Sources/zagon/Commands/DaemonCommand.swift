import ArgumentParser
import ZagonCore

struct DaemonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Follow transcripts, rollouts and the hook spool; keep the totals current; send notifications.")
    @OptionGroup var common: Common
    @Option(help: "Seconds to collect changes before applying them.") var debounce: Double = 0.5
    @Flag(help: "Do not send notifications or answer the bot.") var noNotify = false
    @Flag(help: "Do not keep compressed copies of transcripts.") var noArchive = false
    @Option(help: "Minutes between health lines in the log.") var healthMinutes: Double = 10
    @Flag(help: "Log every batch.") var verbose = false

    func run() throws {
        #if os(Linux)
        let log = LogFile(path: common.dataDir + "/logs/daemon.log")
        let paths = ZagonPaths(dir: common.dataDir)
        let config = NotifyConfig.load(paths)
        Settings.applyTimezone(paths)  // before any local-time call and before other threads start
        do {
            let store = try common.open()
            var o = Daemon.Options()
            o.debounce = debounce; o.verbose = verbose; o.healthEvery = healthMinutes * 60
            o.spoolDir = paths.spool; o.codexHome = common.codexDir; o.paths = paths
            try Daemon(ingest: common.ingest(store), options: o, log: { log.write($0) }).run {
                if !noArchive {
                    Daemon.startArchiver(dbPath: common.dataDir + "/zagon.db", dir: common.dataDir + "/archive", log: { log.write($0) })
                }
                Daemon.startWorklogTexts(dataDir: common.dataDir, claudeDir: common.claudeDir, log: { log.write($0) })
                Daemon.startClaudeAgents(dbPath: common.dataDir + "/zagon.db", home: paths.home, host: store.host, log: { log.write($0) })
                guard !noNotify else { return }
                let notifies = Daemon.startNotifier(dbPath: common.dataDir + "/zagon.db", paths: paths, config: config,
                                                    claudeRoot: common.claudeDir, log: { log.write($0) })
                if !notifies { log.write("notify: off (no channel configured)") }
                // The day summary is written at its time even when no message carries it.
                if !(notifies && config.enabled) {
                    Daemon.startSummaryWriter(dbPath: common.dataDir + "/zagon.db", paths: paths, config: config,
                                              claudeRoot: common.claudeDir, log: { log.write($0) })
                }
            }
        } catch {
            log.write("exit: \(error)")
            throw error
        }
        #else
        throw ValidationError("zagon daemon is not used on macOS: Zagon.app collects the data")
        #endif
    }
}
