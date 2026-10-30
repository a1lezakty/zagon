import CSys
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

extension Ingest {
    /// Ingests changed files (e.g. from a watcher) in one transaction, then refreshes the derived tables.
    /// Paths outside every source root, or not accepted by it, are ignored.
    public func update(paths: Set<String>) throws {
        try db.transaction {
            for p in paths.sorted() {
                guard let src = sources.first(where: { p.hasPrefix($0.root + "/") }) else { continue }
                let rel = String(p.dropFirst(src.root.count + 1))
                if src.accepts(rel) { try ingest(path: p, relative: rel, source: src) }
            }
        }
        try finish()
    }
}

/// `zagon daemon`: one full pass, then follows transcripts, rollouts, the hook spool and Codex's thread index
/// through inotify and keeps totals current. Changes are applied in batches after `debounce` seconds.
public final class Daemon {
    public struct Options: Sendable {
        public var debounce = 0.5
        /// Batches with nothing but hook / status-line lines wait longer (fewer wake-ups; statuses still < 2 s).
        public var spoolDebounce = 1.5
        public var spoolDir: String?
        /// Codex home: `state_*.sqlite` there is re-read when it changes.
        public var codexHome: String?
        public var verbose = false
        /// Seconds between health lines in the log.
        public var healthEvery = 600.0
        /// config.toml: when its time zone changes (`zagon tz`, MCP, the bot) the service restarts in the new zone.
        public var paths: ZagonPaths?
        public init() {}
    }

    public let ingest: Ingest
    public let options: Options
    let log: (String) -> Void
    var store: Store { ingest.store }

    /// Counters since the last health line.
    var batches = 0, files = 0, errors = 0, fullPasses = 0

    public init(ingest: Ingest, options: Options, log: @escaping (String) -> Void = { _ = Sys.writeAll(fd: 2, Array("zagon daemon: \($0)\n".utf8)) }) {
        self.ingest = ingest; self.options = options; self.log = log
    }

    /// Everything once: rollouts and transcripts, threads, spool. `reason` goes to the log.
    public func fullPass(reason: String) throws {
        let s = try ingest.scan()
        try syncThreads()
        try spool()
        fullPasses += 1
        log("full pass (\(reason)): \(s.filesSeen) files, \(s.filesRead) read, \(s.bytes >> 10) KB, \(s.badLines) bad lines, "
            + "\(s.resets) resets, \(s.moves) moves, \(Int(s.seconds * 1000)) ms")
    }

    func syncThreads() throws {
        if let c = options.codexHome { try CodexThreads.sync(store: store, codexHome: c, host: ingest.host) }
    }

    func spool() throws {
        if let d = options.spoolDir { try SpoolIngest.run(store: store, spoolDir: d) }
    }

    /// Applies a batch of changed paths; `lost` = why events were lost (then everything is rescanned).
    public func apply(_ paths: Set<String>, lost: String? = nil) throws {
        if let lost { try fullPass(reason: lost); return }
        var changed = Set<String>(), spoolChanged = false, threadsChanged = false
        for p in paths {
            if let d = options.spoolDir, p.hasPrefix(d + "/") { spoolChanged = true }
            else if let c = options.codexHome, Sys.dirname(p) == c { threadsChanged = threadsChanged || Sys.basename(p).hasPrefix("state_") }
            else { changed.insert(p) }
        }
        let t0 = Time.monotonic()
        if !changed.isEmpty { try ingest.update(paths: changed) }
        // ponytail: every change of Codex's state db re-reads its threads (a few ms); rate-limit if it ever shows up.
        if threadsChanged { try syncThreads() }
        if spoolChanged { try spool() }
        batches += 1; files += changed.count
        if options.verbose {
            log("batch: \(changed.count) files, spool \(spoolChanged), threads \(threadsChanged), \(Int((Time.monotonic() - t0) * 1000)) ms")
        }
    }

    #if os(Linux)
    /// Runs until SIGTERM / SIGINT. Each batch is its own transaction, so stopping at any point loses nothing.
    /// `ready` runs once after the first full pass.
    public func run(ready: () -> Void = {}) throws -> Never {
        var stops = sigset_t()
        sigemptyset(&stops)
        for s in [SIGTERM, SIGINT] { signal(s) { stopSignal = $0 }; sigaddset(&stops, s) }
        pthread_sigmask(SIG_UNBLOCK, &stops, nil)  // a parent may have started us with them blocked
        log("start: pid \(getpid()), schema v\(store.userVersion), host \(ingest.host), "
            + "roots \(ingest.sources.map(\.root).joined(separator: ", "))")
        if let d = options.spoolDir { Sys.mkdirs(d) }  // hooks write here; watch it from the start
        try fullPass(reason: "start")
        try? store.db.exec("PRAGMA cache_size=-512")  // the first pass had the default 2 MB; batches are small
        releaseMemory()
        ready()
        guard let w = DirWatcher() else { throw SQLiteError(code: -1, message: "inotify_init1 failed: errno \(errno)") }
        var dirty = Set<String>(), lost: String?
        var due: Double?  // when the pending batch is applied
        var release: Double?  // when memory of the last batches is given back (a few seconds after them)
        var failures = 0
        func watchRoots() {
            // Roots that do not exist yet (no Codex, no spool) are retried on every idle wake-up.
            var found: [String] = []
            func add(_ dir: String, recursive: Bool) {
                guard !w.isWatched(dir) else { return }
                let f = w.add(dir, recursive: recursive)
                if w.isWatched(dir) { log("watching \(dir)"); found += f }
            }
            for s in ingest.sources { add(s.root, recursive: true) }
            if let d = options.spoolDir { add(d, recursive: false) }
            if let c = options.codexHome { add(c, recursive: false) }
            if !found.isEmpty { dirty.formUnion(found); due = due ?? Time.monotonic() + options.debounce }
        }
        watchRoots()
        var health = Health(store: store)
        log("watching \(w.watched.count) directories")
        var zoneCheck = 0.0
        while true {
            // config.toml is not watched (the database next to it changes all the time): a zone set by the CLI or MCP
            // is seen at the next wake-up, at most 10 s away.
            var idle = min(options.paths == nil ? 60 : 10, max(0, options.healthEvery - (Time.monotonic() - health.at)))
            if let r = release { idle = min(idle, max(0, r - Time.monotonic())) }
            let timeout = Int32(max(0, (due.map { $0 - Time.monotonic() } ?? idle) * 1000))
            let ev = w.wait(timeoutMs: timeout)
            if stopSignal != 0 {
                if !dirty.isEmpty { try? apply(dirty, lost: lost) }
                log("stop: signal \(stopSignal)")
                exit(0)
            }
            if !ev.paths.isEmpty || ev.lost != nil {
                dirty.formUnion(ev.paths); lost = lost ?? ev.lost
                let onlySpool = lost == nil && options.spoolDir.map { d in dirty.allSatisfy { $0.hasPrefix(d + "/") } } == true
                let at = Time.monotonic() + (onlySpool ? options.spoolDebounce : options.debounce)
                due = min(due ?? at, at)
            }
            if let d = due, Time.monotonic() >= d {
                do {
                    try apply(dirty, lost: lost)
                    dirty = []; lost = nil; due = nil; failures = 0
                    release = release ?? Time.monotonic() + 5
                } catch {
                    // e.g. the database is locked by a long scan; the batch is kept and retried
                    errors += 1; failures += 1
                    log("error (attempt \(failures), \(dirty.count) files pending): \(error); retrying in 5 s")
                    due = Time.monotonic() + 5
                }
            }
            if due == nil { watchRoots() }
            if due == nil, let r = release, Time.monotonic() >= r { releaseMemory(); release = nil }
            if let p = options.paths, Time.monotonic() >= zoneCheck {
                zoneCheck = Time.monotonic() + 2
                if !Settings.timezoneApplied(p) {
                    if !dirty.isEmpty { try? apply(dirty, lost: lost) }
                    Daemon.restart(p, log: log)
                    zoneCheck = Time.monotonic() + 600  // only reached when the restart failed
                }
            }
            if health.due(every: options.healthEvery) {
                log(health.line(watched: w.watched.count, batches: batches, files: files, errors: errors, fullPasses: fullPasses))
                batches = 0; files = 0; errors = 0; fullPasses = 0
            }
        }
    }
    #endif

    /// Hands the unused page cache and freed heap of this thread back to the system.
    func releaseMemory() {
        store.db.releaseMemory()
        z_release_memory()
    }
}

extension Daemon {
    /// Restarts the service in the zone config.toml now names (days are rebuilt by the first pass: `meta.tz`).
    /// From any thread: a batch cut short is redone by that pass, each batch being one transaction.
    static func restart(_ paths: ZagonPaths, log: (String) -> Void) {
        log("timezone: \(Settings.zoneName()) -> \(Settings.timezone(paths) ?? "system zone"), restarting")
        Settings.restart()
        log("timezone: restart failed (errno \(errno)); the new zone applies after a manual restart")
    }
}

#if os(Linux)
/// Set by the SIGTERM / SIGINT handler; the loop (woken by EINTR or its timeout) stops cleanly.
nonisolated(unsafe) var stopSignal: Int32 = 0
#endif

/// The periodic health line: memory, CPU over the interval, database size, activity counters.
struct Health {
    let store: Store
    var at = Time.monotonic()
    var cpu = Health.cpuSeconds()

    init(store: Store) { self.store = store }

    func due(every: Double) -> Bool { Time.monotonic() - at >= every }

    mutating func line(watched: Int, batches: Int, files: Int, errors: Int, fullPasses: Int) -> String {
        let now = Time.monotonic(), c = Health.cpuSeconds()
        let interval = now - at, used = c - cpu
        at = now; cpu = c
        let pages = (try? store.db.one("SELECT page_count * page_size FROM pragma_page_count(), pragma_page_size()") { $0.int(0) }) ?? 0
        func mb(_ b: Int) -> String { "\(Double(b / 1024 * 10 / 1024) / 10) MB" }
        let m = Health.memory()
        return "health: rss \(mb(m.rss)) (anon \(mb(m.anon)), file \(mb(m.file))), cpu \(Double(Int(used * 100)) / 100) s in \(Int(interval)) s "
            + "(\(Double(Int(used / max(interval, 1) * 10_000)) / 100) %), db \(mb(pages)), watched \(watched) dirs, "
            + "batches \(batches), files \(files), errors \(errors), full passes \(fullPasses)"
    }

    static func cpuSeconds() -> Double {
        var ru = rusage()
        #if canImport(Glibc)
        getrusage(__rusage_who_t(RUSAGE_SELF.rawValue), &ru)
        #else
        getrusage(RUSAGE_SELF, &ru)
        #endif
        return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6 + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
    }

    /// Resident memory (`VmRSS`), of it the process's own (`RssAnon`) and the mapped binary's pages (`RssFile`,
    /// clean, the kernel can drop them); zeros where /proc is missing.
    static func memory() -> (rss: Int, anon: Int, file: Int) {
        guard let b = Sys.readFile("/proc/self/status") else { return (0, 0, 0) }
        var v: [Substring: Int] = [:]
        for l in String(decoding: b, as: UTF8.self).split(separator: "\n") {
            let p = l.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if p.count >= 2, ["VmRSS:", "RssAnon:", "RssFile:"].contains(p[0]) { v[p[0]] = (Int(p[1]) ?? 0) * 1024 }
        }
        return (v["VmRSS:"] ?? 0, v["RssAnon:"] ?? 0, v["RssFile:"] ?? 0)
    }
}

#if os(Linux)
extension Daemon {
    /// Notifications and the Telegram bot on their own thread with their own connection (one SQLite connection per
    /// thread), so a bot long-poll or a day summary (`claude -p`, up to its timeout) never holds up the watcher.
    /// Returns false (and starts nothing) when no channel is configured.
    @discardableResult
    public static func startNotifier(dbPath: String, paths: ZagonPaths, config: NotifyConfig, claudeRoot: String,
                                     log: @escaping @Sendable (String) -> Void) -> Bool {
        guard config.enabled || config.telegramCommands, !config.channels(paths).isEmpty else { return false }
        startThread {
            let channels = config.channels(paths)
            let store: Store
            do { store = try Store(path: dbPath) } catch { log("notify: cannot open the database: \(error)"); return }
            try? store.db.exec("PRAGMA cache_size=-256")  // reads a few rows per tick
            let n = Notifier(store: store, config: config, channels: channels)
            n.log = log
            var summary = DaySummary(store: store, config: config, paths: paths, claudeRoot: claudeRoot)
            summary.log = log
            n.summary = { [summary] in try summary.message($0) }
            let bot = config.telegramCommands ? channels.compactMap { $0 as? Telegram }.first.map { Bot(telegram: $0, store: store, paths: paths, lang: config.lang) } : nil
            bot?.log = log
            bot?.onTimezoneChange = { if !Settings.timezoneApplied(paths) { Daemon.restart(paths, log: log) } }
            // The evening worklog message: tasks suggested for the day's work without a key, Yes / No per suggestion.
            do {
                let s = try TaskSuggester.load(store: store, paths: paths, config: config, claudeRoot: claudeRoot, log: log)
                n.worklogPlan = { [bot] in try s.message($0, buttons: bot != nil) }
                let other = bot?.onCallback
                bot?.onCallback = { try s.callback($0) ?? other?($0) }
            } catch { log("notify: task suggestions off: \(error)") }
            log("notify: channels \(channels.map(\.name).joined(separator: ",")), bot \(bot == nil ? "off" : "on")")
            while true {
                n.config.summaryAt = NotifyConfig.load(paths).summaryAt  // `zagon summary --at` changes it in place
                do { try n.tick() } catch { log("notify: error: \(error)") }
                store.db.releaseMemory(); z_release_memory()
                if let bot { bot.pollOnce(timeout: 25) } else { sleep(30) }
            }
        }
        return true
    }
}

extension Daemon {
    /// The day summary at `[summary] time` when no notifier writes it (no channel, or `[notify] enabled = false`): a
    /// check a minute on its own thread and connection, the time read from config.toml each time.
    public static func startSummaryWriter(dbPath: String, paths: ZagonPaths, config: NotifyConfig, claudeRoot: String,
                                          log: @escaping @Sendable (String) -> Void) {
        startThread {
            let store: Store
            do { store = try Store(path: dbPath) } catch { log("summary: cannot open the database: \(error)"); return }
            var s = DaySummary(store: store, config: config, paths: paths, claudeRoot: claudeRoot)
            s.log = log
            while true {
                s.config.summaryAt = NotifyConfig.load(paths).summaryAt
                do { if try s.autoTick() { log("summary: written") } } catch { log("summary: error: \(error)") }
                store.db.releaseMemory(); z_release_memory()
                sleep(60)
            }
        }
    }
}

extension Daemon {
    /// The transcript archive (`Archive.tick`) every `every` seconds on a background-priority thread with its own
    /// connection: the first pass compresses gigabytes, the watcher must not wait for it.
    public static func startArchiver(dbPath: String, dir: String, every: Double = 600, log: @escaping @Sendable (String) -> Void) {
        startThread {
            z_background_thread()
            let store: Store
            do { store = try Store(path: dbPath) } catch { log("archive: cannot open the database: \(error)"); return }
            try? store.db.exec("PRAGMA cache_size=-256")  // walks source_file once per pass
            let archive = Archive(store: store, dir: dir)
            while true {
                let t0 = Time.monotonic()
                do {
                    let s = try archive.tick()
                    if s.written > 0 {
                        log("archive: \(s.written) files written, \(s.rawBytes >> 20) MB -> \(s.packedBytes >> 20) MB, "
                            + "\(Int((Time.monotonic() - t0) * 1000)) ms")
                    }
                } catch { log("archive: error: \(error)") }
                // zstd contexts and buffers of the pass are freed, but the allocator keeps them for this thread.
                store.db.releaseMemory(); z_release_memory()
                sleep(UInt32(every))
            }
        }
    }
}

final class ThreadBody: Sendable {
    let run: @Sendable () -> Void
    init(_ run: @escaping @Sendable () -> Void) { self.run = run }
}

/// A detached POSIX thread (no Foundation `Thread` in the static build).
func startThread(_ body: @escaping @Sendable () -> Void) {
    let box = Unmanaged.passRetained(ThreadBody(body)).toOpaque()
    let entry: @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? = { p in
        Unmanaged<ThreadBody>.fromOpaque(p!).takeRetainedValue().run()
        return nil
    }
    #if canImport(Musl)
    var t: pthread_t? = nil
    pthread_create(&t, nil, entry, box)
    if let t { pthread_detach(t) }
    #else
    var t = pthread_t()
    pthread_create(&t, nil, entry, box)
    pthread_detach(t)
    #endif
}
#endif
