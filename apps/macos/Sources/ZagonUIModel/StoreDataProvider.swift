import Foundation
import ZagonCore

/// `ZagonDataProvider` over a ZagonCore store. SQLite connections are one per thread: reads run on one serial queue,
/// `refresh` (new transcript bytes, Codex threads, hook / status-line spool lines) on another with its own connection,
/// so a long scan or a CLI holding the write lock never stalls the screens (WAL readers do not wait for writers).
/// Until the first refresh has finished, screens get empty data instead of half-scanned numbers.
public final class StoreDataProvider: ZagonDataProvider, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.zagon.store")
    let writeQueue = DispatchQueue(label: "dev.zagon.store.write")
    let query: Query
    let reader: Store
    /// The writing connection (refresh, server imports); nil = read-only provider.
    let writer: Store?
    let update: () throws -> Bool
    let fixedNow: Date?
    /// Sessions of this host resume locally, others over ssh.
    let localHost: String
    private let readyLock = NSLock()
    private var isReady = false
    private var remote: [String] = []
    private var remoteErrors: [String: String] = [:]
    /// Advice per server by its zagon version (a strings key, `Remote.hint`).
    private var remoteHints: [String: String] = [:]
    /// Servers pulled at least once since start (a grey dot until then).
    private var pulled: Set<String> = []
    private var scanErrors = 0
    /// Server host name → ssh alias (servers are shown and resumed by their alias).
    private var aliases: [String: String] = [:]
    /// Notifications (write queue only).
    private var notifyHook: NotifyHook?
    private var notifier: Notifier?
    /// The database file (diagnostics); nil in memory.
    public var dbPath: String?
    private var zone = TimeZone.autoupdatingCurrent

    /// The zone days are cut in, for this Mac's data and the servers' alike (the Mac's own unless one is chosen).
    public var timeZone: TimeZone {
        get { readyLock.withLock { zone } }
        set { readyLock.withLock { zone = newValue } }
    }

    /// `update` returns whether anything new was read; it must use its own connection, not `store`.
    public init(store: Store, writer: Store? = nil, now: Date? = nil, host: String = Ingest.hostName(),
                update: @escaping () throws -> Bool = { false }) {
        query = Query(store: store); reader = store; self.writer = writer; fixedNow = now; localHost = host; self.update = update
    }

    public var now: Date { fixedNow ?? Date() }

    public var ready: Bool { readyLock.withLock { isReady } }

    /// Reads what is new; `done(changed)` runs on the main actor.
    public func refresh(_ done: @escaping @MainActor @Sendable (Bool) -> Void) {
        writeQueue.async {
            let started = Date()
            var changed = false
            do {
                changed = try self.update()
            } catch {
                self.readyLock.withLock { self.scanErrors += 1 }
                Log.shared.write("scan failed: \(error)")
            }
            let took = Date().timeIntervalSince(started)
            if took > 5 { Log.shared.write("slow scan: \(Int(took)) s") }
            self.notify()
            self.readyLock.withLock { self.isReady = true }
            Task { @MainActor in done(changed) }
        }
    }

    /// Turns on notifications by the core's rules (`NotifyConfig` from `hook.configPath`, read on every pass), sent
    /// after every scan and server pull; what was sent is remembered in this database (`meta` `notify:<key>`).
    public func notifications(_ hook: NotifyHook) {
        writeQueue.async { self.notifyHook = hook }
    }

    /// One notifier pass (write queue).
    func notify() {
        guard let hook = notifyHook, let writer else { return }
        let text = Sys.readFile(hook.configPath).map { String(decoding: $0, as: UTF8.self) } ?? ""
        var config = NotifyConfig.parse(text, home: NSHomeDirectory())
        config.enabled = hook.enabled()
        // The servers write the day summary and the worklog plan (an AI call); this Mac leaves them out.
        config.summaryAt = nil; config.worklogAt = nil
        let remote = hook.remote() ? config.channels(ZagonPaths()).map { Background($0) as any Channel } : []
        let channels: [any Channel] = [Deliver(hook.deliver)] + remote
        if let n = notifier {
            n.config = config; n.channels = channels
        } else {
            let n = Notifier(store: writer, config: config, channels: channels)
            n.log = { Log.shared.write($0) }
            notifier = n
        }
        do { try notifier?.tick(now: now.timeIntervalSince1970) } catch { Log.shared.write("notify: " + Remote.brief(error)) }
    }

    /// Scan failures since the last call (the health line).
    public func takeScanErrors() -> Int { readyLock.withLock { defer { scanErrors = 0 }; return scanErrors } }

    /// Row counts of the main tables (diagnostics; no text).
    public func counters() -> [(String, Int)] {
        read([]) {
            try ["session", "day_agg", "usage_hour", "activity", "limit_snapshot", "fts_doc", "task", "summary"].map { t in
                (t, try query.db.one("SELECT count(*) FROM \(t)") { $0.int(0) } ?? 0)
            }
        }
    }

    /// The database file with its WAL, in bytes.
    public var dbBytes: Int {
        [dbPath, dbPath.map { $0 + "-wal" }].compactMap { $0 }.reduce(0) { sum, p in
            sum + ((try? FileManager.default.attributesOfItem(atPath: p)[.size] as? NSNumber)?.intValue ?? 0)
        }
    }

    /// Last ssh / import error per server.
    public var hostErrors: [String: String] { readyLock.withLock { remoteErrors } }
    public var hostHints: [String: String] { readyLock.withLock { remoteHints } }

    /// Pulled since start, and the last pull worked.
    public func serverOnline(_ alias: String) -> Bool { readyLock.withLock { pulled.contains(alias) && remoteErrors[alias] == nil } }

    /// A server unchecked: its imported rows leave the numbers (`Remote.drop`); `done` on the main actor.
    public func dropServer(_ alias: String, done: @escaping @MainActor @Sendable () -> Void) {
        writeQueue.async {
            guard let writer = self.writer else { return }
            do { try Remote.drop(alias, db: writer.db) } catch { Log.shared.write("server \(alias) not dropped: \(error)") }
            self.readyLock.withLock {
                self.remote.removeAll { $0 == alias }
                self.aliases = self.aliases.filter { $0.value != alias }
                self.pulled.remove(alias)
                self.remoteErrors[alias] = nil
                self.remoteHints[alias] = nil
            }
            Task { @MainActor in done() }
        }
    }

    /// Pulls each server's `zagon export` over ssh, one after another off the store queues, and imports it through
    /// the writing connection. `done(changed)` runs on the main actor: new data, or a server went on/offline.
    public func pull(_ hosts: [String], done: @escaping @MainActor @Sendable (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var changed = self.readyLock.withLock {
                defer {
                    self.remote = hosts
                    self.remoteErrors = self.remoteErrors.filter { hosts.contains($0.key) }
                    self.remoteHints = self.remoteHints.filter { hosts.contains($0.key) }
                }
                return self.remote != hosts
            }
            let controlDir = Remote.controlDir()
            for h in hosts where self.writer != nil {
                var error: String?
                do {
                    let since = try self.writeQueue.sync { try Remote.cursor(h, db: self.writer!.db) }
                    let data = try Remote.pull(host: h, since: since, controlDir: controlDir)
                    // Unchecked while its ssh ran (`dropServer`): what came back is not imported.
                    guard let n = try self.writeQueue.sync(execute: { () -> Remote.Imported? in
                        guard self.readyLock.withLock({ self.remote.contains(h) }) else { return nil }
                        return try Remote.apply(data, alias: h, store: self.writer!, localHost: self.localHost, checked: hosts)
                    }) else { continue }
                    let hint = Remote.hint(server: n.version, app: Remote.appVersion)
                    let hintChanged = self.readyLock.withLock {
                        for x in n.hosts { self.aliases[x] = h }
                        defer { self.remoteHints[h] = hint }
                        return self.remoteHints[h] != hint
                    }
                    changed = changed || hintChanged || n.sessions + n.days > 0
                    if n.old { error = Remote.oldZagon }
                } catch let e {
                    error = Remote.brief(e)
                }
                let was = self.readyLock.withLock { () -> String? in
                    defer { self.remoteErrors[h] = error; self.pulled.insert(h) }
                    return self.remoteErrors[h]
                }
                if (was == nil) != (error == nil) {
                    changed = true
                    Log.shared.write("server \(h): " + (error ?? "online"))
                }
            }
            if !hosts.isEmpty { self.writeQueue.sync { self.notify() } }
            let result = changed
            Task { @MainActor in done(result) }
        }
    }

    /// This Mac: `~/.zagon/zagon.db` fed by `~/.claude/projects`, the Codex home and `~/.zagon/spool`.
    ///
    /// The database's days are cut in `timezone` of config.toml when set (`zagon tz`), as the CLI does: a scan in
    /// another zone would rebuild every day, and the app and the CLI would take turns at it. The zone chosen in the
    /// app only cuts what is shown.
    public static func local() throws -> StoreDataProvider {
        let paths = ZagonPaths()
        baseZone(paths)
        try FileManager.default.createDirectory(atPath: paths.dir, withIntermediateDirectories: true)
        let writer = try Store(path: paths.dir + "/zagon.db")
        let codex = CodexSource.defaultHome()
        let ingest = Ingest(store: writer, sources: [ClaudeSource.spec(root: paths.home + "/.claude/projects")]
                            + CodexSource.specs(codexHome: codex))
        let p = StoreDataProvider(store: try Store(path: paths.dir + "/zagon.db"), writer: writer, host: ingest.host) {
            if baseZone(paths) {
                Task { @MainActor in NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil) }
            }
            let s = try ingest.scan()
            let threads = try CodexThreads.sync(store: writer, codexHome: codex, host: ingest.host)
            let spool = try SpoolIngest.run(store: writer, spoolDir: paths.spool)
            return s.lines > 0 || threads > 0 || spool.lines > 0
        }
        p.dbPath = paths.dir + "/zagon.db"
        p.aliases = (try? Remote.aliases(db: writer.db)) ?? [:]
        return p
    }

    /// No data at all (the local store did not open).
    public static func empty() -> StoreDataProvider {
        let p = StoreDataProvider(store: try! Store(path: ":memory:"))
        p.isReady = true
        return p
    }

    /// A store scanned from the synthetic fixtures (`Tests/ZagonCoreTests/Fixtures/scenario`), "now" = 2026-10-30
    /// 11:42 UTC, host "laptop". Days are UTC: the caller's time zone must be UTC too (`TZ=UTC`).
    public static func fixture(_ root: String) throws -> StoreDataProvider {
        let p = StoreDataProvider(store: try fixtureStore(root), now: fixtureNow, host: "laptop")
        p.isReady = true
        return p
    }

    static let fixtureNow = Date(timeIntervalSince1970: 1_793_360_520)

    static func fixtureStore(_ root: String) throws -> Store {
        setenv("TZ", "UTC", 1)
        tzset()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zagon-fixture-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.copyItem(atPath: root, toPath: dir + "/claude")
        let store = try Store(path: ":memory:")
        var o = IngestOptions()
        o.host = "laptop"
        try Ingest(store: store, sources: [ClaudeSource.spec(root: dir + "/claude/projects")], options: o).scan()
        try SpoolIngest.run(store: store, spoolDir: dir + "/claude/spool", now: fixtureNow.timeIntervalSince1970)
        return store
    }

    func read<T>(_ empty: T, _ body: () throws -> T) -> T {
        guard ready else { return empty }
        return queue.sync { (try? body()) ?? empty }
    }

    static func date(_ ts: Timestamp) -> Date { Date(timeIntervalSince1970: ts) }

    /// Applies `timezone` of config.toml to this process (libc and Foundation); true when it changed.
    @discardableResult
    static func baseZone(_ paths: ZagonPaths) -> Bool {
        guard !Settings.timezoneApplied(paths) else { return false }
        Settings.applyTimezone(paths)
        NSTimeZone.resetSystemTimeZone()
        return true
    }

    static func calendar(_ zone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    /// "YYYY-MM-DD" of a moment in `zone`.
    public static func day(_ d: Date, _ zone: TimeZone) -> String {
        let c = calendar(zone).dateComponents([.year, .month, .day], from: d)
        let (y, m, dd) = (c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return "\(y)-" + (m < 10 ? "0" : "") + "\(m)-" + (dd < 10 ? "0" : "") + "\(dd)"
    }

    /// The start of a day in `zone` to the start of the next (23 or 25 hours on a DST day). Each start is the first
    /// moment of its own day: where a DST change skips midnight the day starts at 01:00, and the day before ends there.
    public static func bounds(_ day: String, _ zone: TimeZone) -> (Timestamp, Timestamp)? {
        guard let (y, m, d) = Time.parseDay(day) else { return nil }
        let c = calendar(zone)
        guard let noon = c.date(from: DateComponents(year: y, month: m, day: d, hour: 12)),
              let next = c.date(from: DateComponents(year: y, month: m, day: d + 1, hour: 12)) else { return nil }
        return (c.startOfDay(for: noon).timeIntervalSince1970, c.startOfDay(for: next).timeIntervalSince1970)
    }

    public static func start(_ day: String, _ zone: TimeZone) -> Date { date(bounds(day, zone)?.0 ?? 0) }

    // MARK: menu bar

    public func limits() -> Limits {
        read(Limits()) {
            let all = try query.limits(now: now.timeIntervalSince1970)
            func window(_ tool: ToolKind, _ name: String) -> LimitWindow? {
                guard let r = all.first(where: { $0.tool == tool && $0.window == name }) else { return nil }
                let reset = r.resetsAt ?? r.ts + Double((r.windowMinutes ?? 0) * 60)
                return LimitWindow(usedPct: r.usedPct, resetsAt: Self.date(reset), pctPerHour: r.pctPerHour,
                                   tool: tool == .codex ? .codex : .claude, readAt: Self.date(r.ts))
            }
            return Limits(claude: AILimits(fiveHour: window(.claude, "five_hour"), week: window(.claude, "seven_day")),
                          codex: AILimits(fiveHour: window(.codex, "primary"), week: window(.codex, "secondary")))
        }
    }

    public func limitHistory(_ kind: LimitKind) -> [LimitPoint] {
        read([]) {
            let windows: [(ToolKind, String)] = kind == .fiveHour ? [(.claude, "five_hour"), (.codex, "primary")]
                : [(.claude, "seven_day"), (.codex, "secondary")]
            for (tool, name) in windows {
                let points = try query.limitHistory(tool: tool, window: name, since: now.timeIntervalSince1970 - 8 * 86400)
                if !points.isEmpty { return points.map { LimitPoint(Self.date($0.ts), $0.pct) } }
            }
            return []
        }
    }

    public func liveSessions() -> [LiveSession] {
        read([]) {
            try query.liveSessions(now: now.timeIntervalSince1970).map { s in
                let status: SessionStatus
                switch s.state {
                case .working: status = .working
                case .waitingPermission: status = .waitingPermission
                case .waitingInput: status = .waitingInput
                case .idle: status = .idle
                }
                return LiveSession(id: s.id, title: Self.title(s.title, s.project, s.id), host: shown(s.host),
                                   tool: s.tool == "codex" ? .codex : .claude, model: Self.modelName(s.model), status: status,
                                   since: Self.date(s.since), command: command(tool: s.tool, id: s.nativeId, cwd: s.cwd, host: shown(s.host)),
                                   drivenBy: s.drivenBy)
            }
        }
    }

    public func todayTotals() -> Totals {
        read(Totals(sessionSec: 0, tokens: 0, cost: 0)) {
            let z = timeZone
            let d = try query.day(Self.day(now, z), detail: false) { Self.bounds($0, z) }
            return Totals(sessionSec: d.sessionSec, userSec: d.userSec, tokens: d.tokens.total, cost: d.cost)
        }
    }

    /// The name a host is shown and resumed by: a server's ssh alias; any other host is this Mac (its database's host,
    /// pinned at the first open: older sessions may carry a name the Mac had on another network).
    func shown(_ host: String?) -> String {
        guard let host else { return localHost }
        return readyLock.withLock { aliases[host] } ?? localHost
    }

    public func hosts() -> [Host] {
        var names: [String] = []
        for h in read([], { try query.hosts() }).map(shown) where !names.contains(h) { names.append(h) }
        if names.isEmpty { names = [localHost] }
        let (servers, errors) = readyLock.withLock { (remote, remoteErrors) }
        names += servers.filter { !names.contains($0) }
        let ok = readyLock.withLock { pulled }
        return names.map { Host(name: $0, online: $0 == localHost || (ok.contains($0) && errors[$0] == nil)) }
    }

    // MARK: day

    public func day(_ date: Date) -> DayData {
        let z = timeZone, key = Self.day(date, z), start = Self.start(key, z)
        return read(DayData(day: start, totals: Totals(sessionSec: 0, tokens: 0, cost: 0))) {
            let d = try query.day(key) { Self.bounds($0, z) }
            func rows(_ xs: [UsageLine], name: (String) -> String = { $0 }) -> [UsageRow] {
                xs.map { UsageRow(name($0.name), tokens: $0.tokens, cost: $0.cost) }
            }
            let lanes = d.lanes.map { l in
                Lane(title: Self.title(l.title, l.project, l.id), host: shown(l.host),
                     intervals: l.intervals.map { Interval(Self.date($0.start), Self.date($0.end), waiting: $0.waiting) })
            }
            let kept = try kept(key), branches = try branches(d.lanes.map(\.id))
            var hostProjects: [String: [DoneProject]] = [:]
            for h in Set(d.lanes.map { shown($0.host) }) {
                var part = d
                part.lanes = d.lanes.filter { shown($0.host) == h }
                // The day's price of a project is not split by machine: none for one worked on several.
                let elsewhere = Set(d.lanes.filter { shown($0.host) != h }.map { $0.project ?? "" })
                part.byProject = d.byProject.filter { !elsewhere.contains($0.name) }
                hostProjects[h] = Self.projects(part, branches: branches)
            }
            return DayData(
                day: start, totals: Totals(sessionSec: d.sessionSec, userSec: d.userSec, tokens: d.tokens.total, cost: d.cost),
                limitHits: d.limitHits.map { Interval(Self.date($0.start), Self.date($0.end)) },
                weekPctStart: d.weekPctStart, weekPctEnd: d.weekPctEnd, lanes: lanes,
                usage: [.project: rows(d.byProject), .model: rows(d.byModel, name: Self.modelName), .agent: rows(d.byAgent),
                        .tool: d.byTool.map { UsageRow($0.name, tokens: $0.count, cost: 0) }, .host: rows(d.byHost) { shown($0.isEmpty ? nil : $0) }],
                doc: kept?.doc, projects: Self.projects(d, branches: branches),
                summaryInfo: kept.map { SummaryInfo(engine: $0.engine, at: $0.at, weekPct: nil, sources: ($0.doc.hosts ?? []).map(shown)) },
                hostProjects: hostProjects)
        }
    }

    /// The day by project without a written summary: its sessions with their working time and branch, most time first;
    /// the price is the project's (tokens count for the directory they were spent in).
    static func projects(_ d: DayDetail, branches: [String: String]) -> [DoneProject] {
        var out: [String: DoneProject] = [:]
        for l in d.lanes {
            let sec = l.intervals.filter { !$0.waiting }.reduce(0) { $0 + $1.end - $1.start }
            let p = l.project ?? ""
            out[p, default: DoneProject(p, sec: 0, cost: 0, sessions: [])].sec += sec
            out[p]?.sessions.append(DoneSession(l.title ?? String(l.id.split(separator: ":").last?.prefix(8) ?? ""),
                                                branch: branches[l.id], sec: sec))
        }
        for u in d.byProject { out[u.name]?.cost = u.cost }
        return out.values.map { p in
            var p = p
            p.sessions.sort { ($0.sec, $1.title) > ($1.sec, $0.title) }
            return p
        }.sorted { ($0.name.isEmpty ? 1 : 0, -$0.sec, $0.name) < ($1.name.isEmpty ? 1 : 0, -$1.sec, $1.name) }
    }

    /// `session.git_branch` of these sessions (none for a detached HEAD or outside git).
    func branches(_ ids: [String]) throws -> [String: String] {
        var out: [String: String] = [:]
        guard !ids.isEmpty else { return out }
        // ponytail: one bound value per session of the day; chunks if a day ever nears SQLite's 32766 variables.
        try query.db.query("SELECT id, git_branch FROM session WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
                           ids.map { .text($0) }) { r in
            if let id = r.text(0), let b = r.text(1), !b.isEmpty, b != "HEAD" { out[id] = b }
        }
        return out
    }

    // MARK: summaries

    /// The kept summary of a day or a period: one written by an AI over one made without, the newest of each.
    public func summary(_ key: String) -> KeptSummary? { read(nil) { try kept(key) } }

    public func hostName(_ host: String) -> String { shown(host) }

    /// Free text from before counts as none, and so does a summary without cards: a server that had no sessions that
    /// day says nothing about this Mac's (read queue).
    func kept(_ key: String) throws -> KeptSummary? {
        var out: KeptSummary?
        try query.db.query("SELECT engine, text, created FROM summary WHERE day = ? ORDER BY engine = 'none', created DESC",
                           [.text(key)]) { r in
            if out == nil, let d = SummaryDoc.decode(r.text(1) ?? ""), !d.items.isEmpty {
                out = KeptSummary(doc: d, engine: r.text(0) ?? "", at: Self.date(r.real(2)))
            }
        }
        return out
    }

    /// Keeps a summary a CLI just answered, so it shows before the next pull brings it (the pull replaces it then).
    public func keep(_ s: KeptSummary) {
        guard let writer else { return }
        writeQueue.sync {
            do {
                // As the import does: a newer row of the same day and engine stays.
                try writer.db.run("""
                    INSERT INTO summary(day, engine, text, created) VALUES(?1, ?2, ?3, ?4)
                    ON CONFLICT(day, engine) DO UPDATE SET text = ?3, created = ?4 WHERE ?4 >= created
                    """, [.text(s.doc.key), .text(s.engine), .text(s.doc.json), .real(s.at.timeIntervalSince1970)])
            } catch { Log.shared.write("summary not kept: " + Remote.brief(error)) }
        }
    }

    // MARK: week

    public func week(containing date: Date) -> WeekData {
        let z = timeZone
        var cal = Self.calendar(z)
        cal.firstWeekday = 2
        cal.minimumDaysInFirstWeek = 4
        let monday = cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        let empty = WeekData(start: monday, projects: [], days: Array(repeating: [], count: 7),
                             totals: Totals(sessionSec: 0, tokens: 0, cost: 0), previous: Totals(sessionSec: 0, tokens: 0, cost: 0),
                             projectRows: [], limitByDay: Array(repeating: nil, count: 7))
        return read(empty) {
            let w = try query.week(from: Self.day(monday, z)) { Self.bounds($0, z) }
            // Top four projects of the week by session time, the rest as "other" ("").
            var sec: [String: Double] = [:]
            for p in w.projects.joined() { sec[p.project, default: 0] += p.sessionSec }
            let top = Array(sec.filter { !$0.key.isEmpty }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(4).map(\.key))
            let hasOther = sec.keys.contains { !top.contains($0) }
            let names = top + (hasOther ? [""] : [])
            func slot(_ p: String) -> Int { top.firstIndex(of: p) ?? top.count }
            let today = Self.day(now, z)
            let days: [[Totals]] = zip(w.days, w.projects).map { day, ps in
                guard day <= today else { return [] }
                var t = names.map { _ in Totals(sessionSec: 0, tokens: 0, cost: 0) }
                for p in ps where !names.isEmpty {
                    t[slot(p.project)].sessionSec += p.sessionSec; t[slot(p.project)].tokens += p.tokens
                    t[slot(p.project)].cost += p.cost
                }
                return t
            }
            var cost: [String: Double] = [:]
            for p in w.projects.joined() { cost[top.contains(p.project) ? p.project : "", default: 0] += p.cost }
            let rows = names.map { n -> ProjectWeek in
                let prev = n.isEmpty ? w.previousSec.filter { !top.contains($0.key) }.values.reduce(0, +) : w.previousSec[n] ?? 0
                let cur = n.isEmpty ? sec.filter { !top.contains($0.key) }.values.reduce(0, +) : sec[n] ?? 0
                return ProjectWeek(n, sec: cur, cost: cost[n] ?? 0, prevSec: prev > 0 ? prev : nil)
            }
            func totals(_ p: PeriodTotals) -> Totals { Totals(sessionSec: p.sessionSec, userSec: p.userSec, tokens: p.tokens, cost: p.cost) }
            return WeekData(start: monday, projects: names, days: days, totals: totals(w.totals), previous: totals(w.previous),
                            projectRows: rows, limitByDay: w.limitByDay)
        }
    }

    // MARK: calendar

    public func month(containing date: Date) -> MonthData {
        let z = timeZone, cal = Self.calendar(z)
        let first = cal.dateInterval(of: .month, for: date)?.start ?? date
        let count = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        let today = Self.day(now, z), firstDay = Self.day(first, z)
        let hours = read([Double](repeating: 0, count: count)) { try query.hours(from: firstDay, count: count) { Self.bounds($0, z) } }
        return MonthData(month: first, hours: hours.enumerated().map { i, h in
            (Time.addDays(firstDay, i) ?? today) > today ? nil : h
        }, archiveSince: nil)
    }

    public func search(_ text: String) -> [SearchHit] {
        read([]) {
            try query.search(text).map { h in
                SearchHit(title: Self.title(h.title, h.project, h.id), host: shown(h.host),
                          start: Self.date(h.startedAt ?? 0), end: Self.date(h.lastAt ?? h.startedAt ?? 0),
                          model: Self.modelName(h.model),
                          command: command(tool: h.tool, id: h.nativeId, cwd: h.cwd, host: shown(h.host)))
            }
        }
    }

    // MARK: tasks and worklog

    /// Tasks and the worklog plan come from the CLI of the chosen source (`TaskBackend`); the store gives none.
    public func tasks() -> [TaskItem] { [] }

    /// Your work stretches and the sessions' time of a day on this Mac (the plan rows come from `TaskBackend`).
    public func worklog(_ date: Date) -> WorklogData {
        let z = timeZone, key = Self.day(date, z), start = Self.start(key, z)
        return read(WorklogData(day: start, workStart: nil, workEnd: nil, userSec: 0, sessionSec: 0, rows: [], splits: [])) {
            let w = try query.workDay(key) { Self.bounds($0, z) }
            return WorklogData(
                day: start, workStart: w.work.first.map { Self.date($0.start) }, workEnd: w.work.last.map { Self.date($0.end) },
                userSec: w.work.reduce(0) { $0 + $1.length }, sessionSec: w.sessionSec, rows: [], splits: [])
        }
    }

    /// A session's own numbers, for task cards (sessions of servers are here too, imported).
    public func sessionWork(_ id: String) -> SessionWork? { read(nil) { try query.sessionWork(id) } }

    /// A task's sessions as this Mac knows them; one not imported yet shows what the task's source said.
    public func taskSessions(_ links: [TaskLink], source: TaskBackend.Source) -> [TaskSession] {
        links.map { l in
            let w = sessionWork(l.sessionId)
            let host: String
            if let w { host = shown(w.host) } else if case .server(let h) = source { host = h } else { host = localHost }
            let last = w?.lastAt ?? l.lastAt ?? 0
            return TaskSession(tool: w?.tool == "codex" ? .codex : .claude, title: Self.title(w?.title ?? l.title, w?.project, l.sessionId),
                               host: host, model: Self.modelName(w?.model), first: Self.date(w?.startedAt ?? last),
                               last: Self.date(last), sec: w?.workingSec ?? 0)
        }
    }

    /// The samples' tasks, answered as the CLI would (`TaskBackend.inProcess`).
    public func fixtureTasks() throws -> TaskBackend {
        guard dbPath == nil, writer == nil else { throw TaskBackend.Failure(description: "samples go only into a sample store") }
        let store = reader, now = self.now
        try queue.sync {
            let tasks = Tasks(store: store), at = now.timeIntervalSince1970 - 9 * 86400
            let main = try tasks.add(title: "Check the payment webhook retries", key: "PROJ-12",
                                     description: "Retries after a timeout must not charge twice.", status: .inProgress, at: at)
            for (i, t) in ["Reproduce the double charge", "Idempotency key on retries", "Load test with 3 retries"].enumerated() {
                _ = try tasks.addTodo(main.id, t, at: at + Double(i))
            }
            try tasks.checkTodo(main.id, number: 1)
            try tasks.addNote(main.id, "Staging webhook secret rotates on Mondays.", at: at)
            try tasks.setDone(main.id, day: Self.day(now.addingTimeInterval(-86400), timeZone), text: "Found the retry path that skips the key check.")
            try tasks.add(title: "Release notes for 2.4", key: "PROJ-14", status: .planned, at: at)
            let own = try tasks.add(title: "Clean up the demo video script", status: .done, at: at)
            try tasks.addNote(own.id, "Not in Jira: stays in Zagon.", at: at)
        }
        return TaskBackend.inProcess(store, queue: queue, now: now)
    }

    // MARK: naming

    /// "api-server — PROJ-12": project first unless the title already names it.
    static func title(_ title: String?, _ project: String?, _ id: String) -> String {
        switch (title, project) {
        case let (t?, p?) where !p.isEmpty && !t.lowercased().contains(p.lowercased()): return p + " — " + t
        case let (t?, _): return t
        case let (nil, p?) where !p.isEmpty: return p
        default: return String(id.split(separator: ":").last?.prefix(8) ?? "")
        }
    }

    /// claude-opus-4-1-20250805 → Opus 4.1, claude-3-5-sonnet-20241022 → Sonnet 3.5, gpt-5-codex → GPT-5-codex.
    public static func modelName(_ model: String?) -> String {
        guard let m = model, !m.isEmpty else { return "" }
        if m.hasPrefix("gpt-") { return "GPT-" + m.dropFirst(4) }
        guard m.hasPrefix("claude-") else { return m }
        let parts: [Substring] = m.dropFirst(7).split(separator: "-").filter { !($0.count == 8 && $0.allSatisfy(\.isNumber)) }
        guard let family = parts.first(where: { !$0.allSatisfy(\.isNumber) }) else { return m }
        let version: String = parts.filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
    }

    /// Command that brings the session back on this machine (or over ssh when it ran elsewhere).
    func command(tool: String, id: String, cwd: String?, host: String?) -> String {
        let resume = (tool == "codex" ? "codex resume " : "claude --resume ") + Self.word(id)
        let local = cwd.map { "cd " + Self.quote($0) + " && " + resume } ?? resume
        // A host read from the database must not turn into an ssh option.
        guard let host, host != localHost, !host.hasPrefix("-") else { return local }
        return "ssh \(Self.word(host)) -t " + Self.quote(local)
    }

    /// One shell word: as is when it has only plain characters, else quoted.
    static func word(_ s: String) -> String {
        !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.@".contains($0)) } ? s : quote(s)
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
