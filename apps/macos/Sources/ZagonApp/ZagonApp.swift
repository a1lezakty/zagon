import AppKit
import ServiceManagement
import Sparkle
import SwiftUI
import ZagonUIModel

enum Screen: String, CaseIterable, Identifiable {
    case day, week, calendar, tasks, worklog, sessions, settings
    var id: String { rawValue }
}

@MainActor
final class AppState: ObservableObject {
    let provider: any ZagonDataProvider
    let lang: Lang
    @Published var screen: Screen = .day
    /// Day shown by the Day screen (and preselected in the calendar).
    @Published var day: Date
    /// "Day summary" opens this many days before today (the samples' detailed day is yesterday).
    let homeBack: Double
    /// Why the local store did not open; the screens are empty then.
    var problem: String?
    /// Initial text of the session search (snapshots); typing lives in the screen's own state.
    var initialQuery = ""
    /// Bumped when new data arrived (or a minute passed), so the screens read the store again.
    @Published private(set) var revision = 0
    /// The main window is on screen: refresh every 5 s instead of every 60 s.
    var windowOpen = false
    /// Servers pulled over ssh (aliases from ~/.ssh/config), kept in UserDefaults.
    @Published private(set) var remoteHosts: [String] = []
    /// Menu bar settings; saved to UserDefaults only for the real app (the samples set them directly).
    @Published var pace = false { didSet { save(pace, "limitsPace") } }
    @Published var paceWeekdays = false { didSet { save(paceWeekdays, "paceWeekdays") } }
    @Published var monoIcon = false { didSet { save(monoIcon, "monoIcon") } }
    @Published var showLeft = false { didSet { save(showLeft, "limitsShowLeft") } }
    /// System notifications on this Mac (on by default) and the same through Telegram / ntfy (off: servers send those).
    @Published var macNotify = true { didSet { save(macNotify, "macNotify") } }
    @Published var macNotifyRemote = false { didSet { save(macNotifyRemote, "macNotifyRemote") } }
    /// Claude Code / Codex connection by the CLI inside Zagon.app (nil = not checked, or not running from the app).
    @Published var cli: Connect.Status?
    @Published private(set) var cliBusy = false
    /// What runs while `cliBusy`: `install`, `uninstall`, nil = `doctor`.
    private(set) var cliCommand: String?
    @Published private(set) var cliError: String?
    /// Tasks and the worklog plan: whose `zagon` answers (nil = the provider's own, the design sample) and what came
    /// back per source (`TaskSource.swift`).
    var taskBackend: ((TaskBackend.Source) -> TaskBackend)?
    @Published var taskSource: TaskBackend.Source? {
        didSet { if persist { UserDefaults.standard.set(taskSource?.saved, forKey: "taskSource") } }
    }
    @Published var taskCache: [TaskBackend.Source: TaskCache] = [:]
    /// Summaries being written through the same source, by key, and the last answers (`SummaryViews.swift`).
    @Published var summaries = SummaryState()
    /// "This Mac" is a source: the CLI inside Zagon.app.
    var hasLocalCLI = AppState.cliPath != nil
    /// PATH the CLI runs with (the login shell's, found by `runCLI`).
    var cliEnvPath: String?
    /// Limit notifications in ~/.zagon/config.toml.
    @Published private(set) var notify = NotifySettings()
    /// Why the last read or write of config.toml failed (shown in settings; the controls then show the file's state).
    @Published private(set) var notifyError: String?
    private var persist = false
    /// `~/.ssh/config` text for the settings list; nil = read the file.
    var sshConfig: String?
    private(set) var store: StoreDataProvider?
    private var pulling = false, pullAgain = false, lastPull = Date.distantPast
    private var lastCPU = (wall: Date(), cpu: ProcessStats.cpuSeconds())
    private var timer: Timer?, health: Timer?
    private var busy = false
    private var lastRefresh = Date.distantPast, lastBump = Date.distantPast

    init(provider: any ZagonDataProvider, lang: Lang, homeBack: Double = 0) {
        self.provider = provider; self.lang = lang; self.homeBack = homeBack
        day = Fmt(lang: lang, now: provider.now).startOfDay(provider.now.addingTimeInterval(-homeBack * 86400))
    }

    /// The zone days are cut and times shown in, for this Mac and the servers alike; nil = the Mac's own (it follows
    /// the system when that changes).
    @Published var zoneID: String? {
        didSet {
            guard zoneID != oldValue else { return }
            if persist { UserDefaults.standard.set(zoneID, forKey: "timeZone") }
            rezone()
            if persist { say(f.t("zone.changed", zone.identifier)) }
        }
    }
    var zone: TimeZone { zoneID.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent }
    /// The first scan has not finished: the screens are still empty.
    var scanning: Bool { store.map { !$0.ready } ?? false }
    /// Open at login (macOS keeps it: `SMAppService`).
    @Published var launchAtLogin = false

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.shared.write("open at login \(on ? "on" : "off") failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Sparkle in the built Zagon.app (its Info.plist has the feed); nil under `swift run` and in the samples.
    var updater: SPUStandardUpdaterController?
    private var reminders: UpdateReminders?
    /// The version Sparkle's daily check found; the panel offers it until the alert gets attention.
    @Published var updateFound: String?
    /// Look for an update once a day (Sparkle keeps the setting).
    var autoUpdate: Bool {
        get { updater?.updater.automaticallyChecksForUpdates ?? false }
        set { objectWillChange.send(); updater?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// A check the user asked for: its result comes back as a toast (`UpdateReminders`), and Sparkle's window opens in
    /// front of the other apps.
    private var checkingUpdates = false
    func checkForUpdates() {
        guard let updater else { return }
        checkingUpdates = true
        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates(nil)
    }

    /// `quiet`: the session ended without a result; only forget the check.
    func updateChecked(found: String?, error: String?, quiet: Bool = false) {
        guard checkingUpdates else { return }
        checkingUpdates = false
        if quiet { return }
        if let error { say(f.t("update.failed", error), error: true) }
        else if let found { say(f.t("update.found", found)) }
        else { say(f.t("update.latest", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")) }
    }

    @Published var toast: Toast?

    /// The one place results are shown (a VoiceOver announcement belongs here too).
    func say(_ text: String, error: Bool = false, reveal: URL? = nil, revealTitle: String? = nil, seconds: Double = 4) {
        let t = Toast(text: text, error: error, reveal: reveal, revealTitle: revealTitle)
        toast = t
        guard !error else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if self?.toast?.id == t.id { self?.toast = nil }
        }
    }

    /// Until "Got it": the window says where Zagon lives.
    @Published var welcome = false
    func welcomeDone() {
        welcome = false
        UserDefaults.standard.set(true, forKey: "welcomeDone")
    }

    /// The last pull of a checked server worked (grey until the first one did); the samples have no store.
    func serverOnline(_ alias: String) -> Bool { store?.serverOnline(alias) ?? true }
    /// The zone the dates kept on screens were made in; screens drop their own dates when it changes.
    @Published private(set) var zoneShown = TimeZone.current.identifier

    /// After the chosen zone or the system's changed: the same date in the new zone, task cards (their days are
    /// dates) read again, every screen redrawn.
    func rezone() {
        let now = zone.identifier
        (provider as? StoreDataProvider)?.timeZone = zone
        guard now != zoneShown, let old = TimeZone(identifier: zoneShown) else { zoneShown = now; return }
        day = StoreDataProvider.start(StoreDataProvider.day(day, old), zone)
        for s in taskCache.keys { taskCache[s]?.cards = [:] }
        zoneShown = now
        revision += 1
    }

    /// Formatting at the provider's current time.
    var f: Fmt { Fmt(lang: lang, timeZone: zone, now: provider.now) }

    /// Day that "Day summary" opens.
    var homeDay: Date { f.startOfDay(provider.now.addingTimeInterval(-homeBack * 86400)) }

    /// The local store (`ZAGON_MOCK=1`: the design sample). A store that does not open leaves the screens empty, not
    /// filled with the sample: made-up limits would read as real ones.
    static func local(_ lang: Lang = .preferred()) -> AppState {
        if ProcessInfo.processInfo.environment["ZAGON_MOCK"] != nil { return mock(lang) }
        Log.shared.start(dir: NSHomeDirectory() + "/Library/Logs/Zagon")
        Log.shared.write("start Zagon \(version) on \(system)")
        do {
            let p = try StoreDataProvider.local()
            let state = AppState(provider: p, lang: lang)
            state.remoteHosts = UserDefaults.standard.stringArray(forKey: "remoteHosts") ?? []
            let d = UserDefaults.standard
            state.pace = d.bool(forKey: "limitsPace"); state.paceWeekdays = d.bool(forKey: "paceWeekdays")
            state.monoIcon = d.bool(forKey: "monoIcon"); state.showLeft = d.bool(forKey: "limitsShowLeft")
            state.macNotify = d.object(forKey: "macNotify") as? Bool ?? true
            state.macNotifyRemote = d.bool(forKey: "macNotifyRemote")
            state.zoneID = d.string(forKey: "timeZone").flatMap { TimeZone(identifier: $0) == nil ? nil : $0 }
            // Open at login: on by default the first time Zagon runs from Applications (it can be turned off in settings).
            if cliPath != nil, Bundle.main.bundlePath.hasPrefix("/Applications/"), !d.bool(forKey: "launchAtLoginSet") {
                d.set(true, forKey: "launchAtLoginSet")
                state.setLaunchAtLogin(true)
            }
            state.launchAtLogin = SMAppService.mainApp.status == .enabled
            if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
                let reminders = UpdateReminders()
                reminders.app = state
                state.reminders = reminders
                state.updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: reminders,
                                                             userDriverDelegate: reminders)
            }
            // The Mac moved to another zone while running: "System" follows it.
            NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak state] _ in
                NSTimeZone.resetSystemTimeZone()
                Task { @MainActor in state?.rezone() }
            }
            state.taskSource = d.string(forKey: "taskSource").map(TaskBackend.Source.init(saved:))
            state.taskBackend = { [weak state] s in
                guard case .server(let host) = s else {
                    return TaskBackend.local(cli: AppState.cliPath ?? "zagon",
                                             path: state?.cliEnvPath ?? Connect.path(loginShell: nil, home: NSHomeDirectory()))
                }
                return TaskBackend.server(host)
            }
            // Outside Zagon.app (swift run) there is no notification center: events are left for the real app.
            if MacNotifications.available {
                p.notifications(NotifyHook(
                    deliver: { MacNotifications.deliver(title: $0, text: $1, loud: $2) },
                    enabled: { UserDefaults.standard.object(forKey: "macNotify") as? Bool ?? true },
                    remote: { UserDefaults.standard.bool(forKey: "macNotifyRemote") }))
                if state.macNotify { MacNotifications.start() }
            }
            let home = NSHomeDirectory()
            state.localTools = [home + "/.claude", home + "/.codex"].contains { FileManager.default.fileExists(atPath: $0) }
            state.runCLI(nil, quiet: true)
            state.welcome = !d.bool(forKey: "welcomeDone")
            do { state.notify = try NotifySettings.load(NotifySettings.configPath) } catch {
                state.notifyError = Log.scrub(String(describing: error))
            }
            state.persist = true
            state.keepFresh(p)
            return state
        } catch {
            Log.shared.write("store did not open: \(error)")
            let state = AppState(provider: StoreDataProvider.empty(), lang: lang)
            state.problem = String(describing: error)
            return state
        }
    }

    /// The design sample; its detailed day is yesterday.
    static func mock(_ lang: Lang = .preferred()) -> AppState {
        let state = AppState(provider: MockDataProvider(lang: lang), lang: lang, homeBack: 1)
        state.cli = Connect.Status(ok: ["hooks: ~/.claude/settings.json", "status line: ~/.claude/settings.json",
                                        "MCP: claude", "hooks: ~/.codex/hooks.json"])
        state.sshConfig = "Host build-box\nHost gpu-box\nHost ci-runner\n"
        state.remoteHosts = ["build-box", "gpu-box"]
        return state
    }

    /// A store scanned from the test fixtures (snapshots); its detailed day is yesterday too.
    static func fixture(_ root: String, _ lang: Lang) throws -> AppState {
        let p = try StoreDataProvider.fixture(root)
        let state = AppState(provider: p, lang: lang, homeBack: 1)
        let tasks = try p.fixtureTasks()
        state.taskBackend = { _ in tasks }
        state.hasLocalCLI = true
        state.taskSource = .local
        state.loadTasksNow(day: TaskBackend.day(p.now))
        return state
    }

    /// Host aliases for the settings list: `~/.ssh/config`, plus checked ones that left it.
    var sshHosts: [String] {
        // ponytail: `Include`d files are not read; add when someone keeps hosts there.
        let text = sshConfig ?? (try? String(contentsOfFile: NSHomeDirectory() + "/.ssh/config", encoding: .utf8)) ?? ""
        let hosts = Remote.sshHosts(text)
        return hosts + remoteHosts.filter { !hosts.contains($0) }
    }

    var hostErrors: [String: String] { store?.hostErrors ?? [:] }
    var hostHints: [String: String] { store?.hostHints ?? [:] }

    private func save(_ value: Bool, _ key: String) {
        if persist { UserDefaults.standard.set(value, forKey: key) }
    }

    /// Applies a change to the file as it is now (hand edits are kept); on failure nothing changes and the reason shows.
    func editNotify(_ change: (inout NotifySettings) -> Void) {
        guard persist else { return change(&notify) }
        let path = NotifySettings.configPath
        do {
            var next = try NotifySettings.load(path)
            change(&next)
            try next.save(path)
            notify = next
            notifyError = nil
        } catch {
            notifyError = Log.scrub(String(describing: error))
            Log.shared.write("config.toml not saved: \(notifyError ?? "")")
            say(f.t("settings.notify.failed", notifyError ?? ""), error: true)
        }
    }

    /// Servers just checked: the pull that includes one says whether it answered.
    private var awaitingHosts: Set<String> = []

    func setRemote(_ host: String, on: Bool) {
        remoteHosts = on ? remoteHosts + [host] : remoteHosts.filter { $0 != host }
        UserDefaults.standard.set(remoteHosts, forKey: "remoteHosts")
        if on { awaitingHosts.insert(host) } else { awaitingHosts.remove(host) }
        guard let store else { return }
        // Unchecked: its sessions and days leave the numbers now, not only stop updating.
        if !on { store.dropServer(host) { [weak self] in self?.revision += 1 } }
        pullServers(store, force: true)
    }

    /// A scan every 5 s while the window is open, every 60 s otherwise (FSEvents only if this proves too slow);
    /// servers every 30 s / 3 min.
    func keepFresh(_ p: StoreDataProvider) {
        store = p
        tick(p, force: true)
        pullServers(p, force: true)
        health = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.writeHealth(p) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick(p, force: false)
                self?.pullServers(p, force: false)
            }
        }
    }

    static var version: String {
        let b = Bundle.main.infoDictionary
        return "\(b?["CFBundleShortVersionString"] as? String ?? "dev") (\(b?["CFBundleVersion"] as? String ?? "-"))"
    }

    static var system: String {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(arch)"
    }

    /// Every 10 minutes: memory, CPU since the last line, database size, scan failures, servers online.
    private func writeHealth(_ p: StoreDataProvider) {
        let now = Date(), cpu = ProcessStats.cpuSeconds()
        let pct = (cpu - lastCPU.cpu) / max(1, now.timeIntervalSince(lastCPU.wall)) * 100
        lastCPU = (now, cpu)
        let errors = p.hostErrors
        Log.shared.write(Diagnostics.health(rss: ProcessStats.rss(), cpuPct: pct, dbBytes: p.dbBytes,
                                            scanErrors: p.takeScanErrors(), servers: remoteHosts.count,
                                            offline: remoteHosts.filter { errors[$0] != nil }.count))
    }

    /// Logs, versions and database counters zipped to the Desktop (no conversation text, home as `~`).
    func collectDiagnostics() throws -> URL {
        if let store { writeHealth(store) }
        let info = Diagnostics.info(version: Self.version, system: Self.system, counters: store?.counters() ?? [],
                                    dbBytes: store?.dbBytes ?? 0, hostErrors: hostErrors, servers: remoteHosts, at: Date(),
                                    zone: zoneID)
        let dir = try Diagnostics.folder(logs: Log.shared.directory, info: info,
                                         in: FileManager.default.temporaryDirectory.path, at: Date())
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let zip = desktop.appendingPathComponent(URL(fileURLWithPath: dir).lastPathComponent + ".zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", dir, zip.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        Log.shared.write("diagnostics saved")
        return zip
    }

    /// `Contents/Helpers/zagon` when running from Zagon.app.
    static var cliPath: String? {
        let p = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/zagon").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    /// Claude Code or Codex is used on this Mac (~/.claude or ~/.codex): only then the menu asks to connect them; a Mac
    /// that only follows servers is left alone.
    var localTools = true

    /// The user closed the banner or disconnected on purpose: no banner until they connect.
    @Published var connectDismissed = UserDefaults.standard.bool(forKey: "connectDismissed") {
        didSet { save(connectDismissed, "connectDismissed") }
    }

    /// `install` / `uninstall`, then `doctor`; nil = only `doctor`. Off the main thread (the login shell and the CLI).
    /// The result shows as a toast unless `quiet` (the check at launch).
    func runCLI(_ command: String?, quiet: Bool = false) {
        guard let bin = Self.cliPath, !cliBusy else { return }
        if command == "install", Connect.temporaryLocation(Bundle.main.bundlePath) {
            cliError = f.t("connect.moveFirst")
            // From the DMG, Finder shows where to drag it from; a translocated copy is a hidden folder, not worth showing.
            let dmg = Bundle.main.bundlePath.hasPrefix("/Volumes/")
            say(f.t("connect.failedInstall", f.t("connect.moveFirst")), error: true, reveal: dmg ? Bundle.main.bundleURL : nil,
                revealTitle: f.t("connect.revealApp"))
            return
        }
        if let command { connectDismissed = command == "uninstall" }
        cliCommand = command
        cliBusy = true
        cliError = nil
        Task.detached {
            let path = Connect.path(loginShell: Connect.loginShellPath(), home: NSHomeDirectory())
            let error = command.flatMap { Connect.change(bin, $0, path: path) }
            if let command { Log.shared.write("cli \(command): " + (error ?? "ok")) }
            let status = Connect.doctor(bin, path: path)
            await MainActor.run {
                self.cliEnvPath = path
                if let status { self.cli = status }
                if command != nil { self.cliError = error }
                if status == nil, self.cliError == nil { self.cliError = self.f.t("connect.noDoctor") }
                self.cliBusy = false
                if !quiet { self.reportCLI(command, status) }
            }
        }
    }

    private func reportCLI(_ command: String?, _ status: Connect.Status?) {
        if let e = cliError { return say(f.t(command == "install" ? "connect.failedInstall" : "connect.failed", e), error: true) }
        guard let status else { return }
        if command == "uninstall" { return say(f.t("connect.removed")) }
        if !status.missing.isEmpty { return say(f.t("connect.missing", status.missing.joined(separator: ", ")), error: true) }
        if command == "install" { say(f.t("connect.done"), seconds: 8) } else { say(f.t("connect.checked")) }
    }

    /// A server that fails only gets a grey dot; the next attempt comes on schedule.
    private func pullServers(_ p: StoreDataProvider, force: Bool) {
        if pulling {
            pullAgain = pullAgain || force  // a host checked meanwhile is pulled right after
            return
        }
        guard force || (!remoteHosts.isEmpty && Date().timeIntervalSince(lastPull) >= (windowOpen ? 30 : 180)) else { return }
        pulling = true
        lastPull = Date()
        let hosts = remoteHosts
        p.pull(hosts) { [weak self] changed in
            guard let self else { return }
            self.pulling = false
            if changed { self.revision += 1 }
            for h in self.awaitingHosts.intersection(hosts) {
                self.awaitingHosts.remove(h)
                if let e = self.hostErrors[h] {
                    self.say(e == Remote.oldZagon ? h + ": " + self.f.t("servers.oldZagon") : self.f.t("servers.failed", h, e), error: true)
                } else {
                    self.say(self.f.t("servers.ok", h))
                }
            }
            if self.pullAgain {
                self.pullAgain = false
                self.pullServers(p, force: true)
            }
        }
    }

    private func tick(_ p: StoreDataProvider, force: Bool) {
        guard !busy, force || windowOpen || Date().timeIntervalSince(lastRefresh) >= 60 else { return }
        busy = true
        lastRefresh = Date()
        p.refresh { [weak self] changed in
            guard let self else { return }
            self.busy = false
            if changed || Date().timeIntervalSince(self.lastBump) >= 60 {
                self.lastBump = Date()
                self.revision += 1
            }
        }
    }
}

@main
@MainActor
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if args.contains("--snapshots") {
            setenv("TZ", "UTC", 1)
            Snapshots.render(to: URL(fileURLWithPath: value("--snapshots") ?? "build/snapshots"), fixtures: value("--fixtures"))
            return
        }
        if let dir = value("--app-icon") { exit(AppIcon.iconset(URL(fileURLWithPath: dir)) ? 0 : 1) }
        ZagonApp.main()
    }
}

struct ZagonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppDelegate.state

    var body: some Scene {
        MenuBarExtra {
            MainPanel().environmentObject(state).preferredColorScheme(.dark)
        } label: {
            // ponytail: rebuilt on every AppState change; give the status item its own observable if that shows in a profile
            Image(nsImage: statusIcon(state))
        }
        .menuBarExtraStyle(.window)
        .commands { ZagonCommands(app: state) }
    }
}

/// The status item, rasterised because a menu bar label shows only images and text. Monochrome without a warning is
/// a template image (the menu bar tints it); otherwise it is drawn in the bar's text colour. 1x screens get the numbers
/// beside the rings.
@MainActor
func statusIcon(_ app: AppState) -> NSImage {
    let vm = MainVM(app.provider, app.f)
    let five = vm.five?.pct, week = vm.week?.pct
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    let template = app.monoIcon && max(five ?? 0, week ?? 0) < 80
    let tint: Color = template ? .black : StatusButton.dark ? .white : .black.opacity(0.85)
    let r = ImageRenderer(content: MenuBarLabel(five: five, week: week, colored: !app.monoIcon, beside: scale < 2, tint: tint))
    r.scale = scale
    let image = r.nsImage ?? NSImage(size: NSSize(width: 40, height: 18))
    image.isTemplate = template
    let pct = { (p: Int?) in p.map { app.f.t("num.pct", "\($0)") } ?? "–" }
    StatusButton.button?.toolTip = app.f.t("menubar.tip", pct(five), pct(week))
    StatusButton.watch { [weak app] in app?.objectWillChange.send() }
    return image
}

struct Ring: View {
    let fraction: Double
    let color: Color
    var size: CGFloat = 72
    var line: CGFloat = 7
    var inset: CGFloat = 6
    var track = Z.track
    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: line)
            Circle().trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(inset)
        .frame(width: size, height: size)
    }
}

/// Zagon has no Dock icon, so the alert of an update found by the daily check opens behind other apps' windows: the
/// panel offers the update too (Sparkle's gentle reminders). Sparkle holds its delegate weakly; AppState keeps this.
final class UpdateReminders: NSObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    weak var app: AppState?
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        found(state.userInitiated ? nil : update.displayVersionString)
    }
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) { found(nil) }
    func standardUserDriverWillFinishUpdateSession() { found(nil) }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let v = item.displayVersionString
        MainActor.assumeIsolated { app?.updateChecked(found: v, error: nil) }
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { app?.updateChecked(found: nil, error: nil) }
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let e = error as NSError
        guard e.code != 1001 else { return }  // SUNoUpdateError: updaterDidNotFindUpdate says it
        MainActor.assumeIsolated { app?.updateChecked(found: nil, error: e.localizedDescription) }
    }
    /// After every cycle, also one that a check only brought forward (no result callback then): forget the check.
    /// The selector is spelled out, so a mismatch fails the build instead of never being called.
    @objc(updater:didFinishUpdateCycleForUpdateCheck:error:)
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated { app?.updateChecked(found: nil, error: nil, quiet: true) }
    }

    // Sparkle calls its user driver's delegate on the main thread.
    private func found(_ version: String?) { MainActor.assumeIsolated { app?.updateFound = version } }
}

// MARK: - Menu bar panel

struct MainPanel: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.isSnapshot) private var snapshot
    @State private var showIdle = false

    var body: some View {
        let f = app.f
        let vm = MainVM(app.provider, f)
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("ZAGON").font(.system(size: 13, weight: .semibold)).tracking(0.26).foregroundColor(Z.secondary)
                Spacer()
                ZoneClock()
                settings
            }
            if let problem = app.problem { Banner.amber(Emphasis(before: f.t("main.storeFailed", problem))) }
            if app.scanning { Text(f.t("main.scanning")).font(.system(size: 12)).foregroundColor(Z.muted) }
            if let v = app.updateFound {
                PillButton(title: f.t("main.updateFound", v), primary: true, expand: true) { app.checkForUpdates() }
            }
            if app.localTools, let cli = app.cli, !cli.connected, !app.connectDismissed {
                VStack(alignment: .leading, spacing: 8) {
                    Banner.blue(Emphasis(before: f.t("connect.banner")))
                    HStack(spacing: 8) {
                        let installing = app.cliBusy && app.cliCommand == "install"
                        PillButton(title: installing ? f.t("connect.connecting") : f.t("connect.button"), primary: true, expand: true,
                                   busy: installing) {
                            app.runCLI("install")
                        }
                        .disabled(app.cliBusy)
                        PillButton(title: f.t("connect.notNow")) { app.connectDismissed = true }.disabled(app.cliBusy)
                    }
                }
            }
            LimitsBlock(vm: vm)
            CappedScroll(maxHeight: max(200, (NSScreen.main?.visibleFrame.height ?? 800) - 440)) {
                SessionsBlock(vm: vm, showIdle: $showIdle)
            }
            TotalsBlock(vm: vm)
            ToastView()
            HStack(spacing: 8) {
                PillButton(title: f.t("main.openWindow"), primary: true, expand: true) { open(nil) }
                PillButton(title: f.t("main.daySummary"), expand: true) { open(.day) }
            }
        }
        .padding(16)
        .frame(width: 400)
        .background(Z.popover)
    }

    @ViewBuilder var settings: some View {
        let gear = Image(systemName: "gearshape").font(.system(size: 14)).foregroundColor(Z.secondary)
            .frame(width: 28, height: 28)
        if snapshot {
            gear
        } else {
            Menu {
                Button(app.f.t("main.openSettings")) { open(.settings) }
                Button(app.f.t("main.checkUpdates")) { app.checkForUpdates() }
                Button(app.f.t("main.quit")) { NSApp.terminate(nil) }
            } label: { gear }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(app.f.t("main.settings"))
        }
    }

    func open(_ screen: Screen?) {
        if let screen {
            app.screen = screen
            app.day = app.homeDay
        }
        MainWindow.shared.show(app)
    }
}

/// Rings or pace charts; a click switches between used + reset time and left + time until the reset. Whose limits they
/// are on top; a window with no current reading shows "–" and a line on when one comes, not 0 %.
struct LimitsBlock: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let vm: MainVM
    var body: some View {
        let f = app.f
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Caps(text: vm.limitsHeader)
                    Spacer(minLength: 8)
                    if let age = vm.limitsAge { Text(age).font(.system(size: 12)).foregroundColor(Z.muted).lineLimit(1) }
                }
                Group {
                    if app.pace {
                        let paces = PaceVM.both(app.provider, weekdaysOnly: app.paceWeekdays, f)
                        HStack(alignment: .top, spacing: 16) {
                            chart(paces.five, vm.five ?? .empty(f.t("limit.five"), f))
                            chart(paces.week, vm.week ?? .empty(f.t("limit.week"), f))
                        }
                    } else {
                        HStack(spacing: 12) {
                            ring(vm.five ?? .empty(f.t("limit.five"), f)).frame(maxWidth: .infinity, alignment: .leading)
                            ring(vm.week ?? .empty(f.t("limit.week"), f)).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { app.showLeft.toggle() }
                if vm.limitsMissing {
                    let unconnected = app.localTools && !(app.cli?.connected ?? true)
                    Text(f.t(unconnected ? "limit.hint.connect" : "limit.hint.wait")).font(.system(size: 12)).foregroundColor(Z.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let fc = vm.forecast { Banner.amber(fc) }
        }
    }

    /// The arc follows a new reading (or the used / left switch) in 0.4 s; at once with Reduce Motion.
    var arc: Animation? { reduceMotion ? nil : .easeOut(duration: 0.4) }

    func ring(_ r: RingVM) -> some View {
        let left = app.showLeft
        let pct = left ? r.leftPct : r.pct
        let fraction = pct == nil ? 0 : left ? 1 - r.fraction : r.fraction
        return HStack(spacing: 12) {
            ZStack {
                Ring(fraction: fraction, color: Color(hex: r.color)).animation(arc, value: fraction)
                Text(pct.map { "\($0)%" } ?? "–").font(mono(17, .semibold)).foregroundColor(pct == nil ? Z.secondary : Z.text)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(.system(size: 14, weight: .semibold)).foregroundColor(Z.text)
                Text(left && pct != nil ? r.leftLine : r.resetLine).font(.system(size: 12)).foregroundColor(Z.secondary)
                Text(r.inLine).font(.system(size: 12)).foregroundColor(Z.secondary)
            }
            .lineLimit(1).minimumScaleFactor(0.85)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(left ? r.spokenLeft : r.spoken)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { app.showLeft.toggle() }
    }

    @ViewBuilder func chart(_ p: PaceVM?, _ r: RingVM) -> some View {
        let left = app.showLeft
        let pct = left ? r.leftPct : r.pct
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(r.title).font(.system(size: 14, weight: .semibold)).foregroundColor(Z.text)
                Spacer(minLength: 4)
                Text(pct.map { "\($0)%" } ?? "–").font(mono(15, .semibold)).foregroundColor(pct == nil ? Z.secondary : Z.text)
            }
            if let p, pct != nil {
                PaceChart(pace: p).frame(height: 64)
                Text(p.verdict).font(.system(size: 12)).foregroundColor(p.ahead ? Color(hex: p.color) : Z.secondary)
                Text(left ? [r.leftLine, r.inLine].filter { !$0.isEmpty }.joined(separator: " · ") : r.resetLine)
                    .font(.system(size: 12)).foregroundColor(Z.secondary)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Z.track.opacity(0.35)).frame(height: 64)
                Text(r.resetLine).font(.system(size: 12)).foregroundColor(Z.secondary)
                Text(r.inLine).font(.system(size: 12)).foregroundColor(Z.secondary)
            }
        }
        .lineLimit(1).minimumScaleFactor(0.85)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([left ? r.spokenLeft : r.spoken, pct == nil ? "" : p?.verdict ?? ""].filter { !$0.isEmpty }
            .joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { app.showLeft.toggle() }
    }
}

/// Usage over the window against the even-pace diagonal (both axes 0…1).
struct PaceChart: View {
    let pace: PaceVM
    var body: some View {
        Canvas { ctx, size in
            func pt(_ p: PaceVM.Point) -> CGPoint { CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height) }
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6), with: .color(Z.track.opacity(0.35)))
            var even = Path()
            even.move(to: CGPoint(x: 0, y: size.height))
            even.addLine(to: CGPoint(x: size.width, y: 0))
            ctx.stroke(even, with: .color(Z.muted), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            var used = Path()
            used.move(to: pt(pace.points[0]))
            for p in pace.points.dropFirst() { used.addLine(to: pt(p)) }
            let color = Color(hex: pace.color)
            ctx.stroke(used, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            let n = pt(pace.now)
            ctx.fill(Path(ellipseIn: CGRect(x: n.x - 3.5, y: n.y - 3.5, width: 7, height: 7)), with: .color(color))
        }
    }
}

struct SessionsBlock: View {
    let vm: MainVM
    @Binding var showIdle: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let none = vm.noSessions { Text(none).font(.system(size: 12)).foregroundColor(Z.muted) }
            if !vm.waiting.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Caps(text: vm.waitingHeader, color: Z.bad)
                    ForEach(vm.waiting) { WaitingRow(s: $0) }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if !vm.working.isEmpty {
                    Caps(text: vm.workingHeader, color: Z.good)
                    ForEach(vm.working) { SessionRow(s: $0, dot: Z.working) }
                }
                if let idle = vm.idleButton {
                    Button { showIdle.toggle() } label: {
                        Text(showIdle ? vm.idleHideButton ?? idle : idle)
                            .font(.system(size: 12)).foregroundColor(Z.muted)
                            .padding(.vertical, 4).padding(.horizontal, 10)
                    }
                    .buttonStyle(.plain)
                    if showIdle { ForEach(vm.idle) { SessionRow(s: $0, dot: Z.muted) } }
                }
            }
        }
    }
}

struct WaitingRow: View {
    let s: SessionRowVM
    @EnvironmentObject private var app: AppState
    @State private var copied = false
    var body: some View {
        HStack(spacing: 10) {
            Dot(color: Z.waiting)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title).font(.system(size: 13, weight: .semibold)).foregroundColor(Z.text).lineLimit(1)
                Text(s.subtitle).font(.system(size: 12)).foregroundColor(Color(hex: 0xB9AEB0)).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(s.time).font(mono(12)).foregroundColor(Z.bad).lineLimit(1)
            Button { copy(s.command, $copied) } label: {
                Image(systemName: copied ? "checkmark" : "terminal").font(.system(size: 12))
                    .foregroundColor(copied ? Z.good : Z.text)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0x3A2C2D)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(hex: 0x4D3234)))
            }
            .buttonStyle(Pressable())
            .help(copied ? app.f.t("copied") : app.f.t("main.copyCommand") + ": " + s.command)
            .accessibilityLabel(app.f.t("main.copyCommand"))
        }
        .padding(.vertical, 9).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x2E2425)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(hex: 0x4D3234)))
    }
}

struct SessionRow: View {
    let s: SessionRowVM
    let dot: Color
    @EnvironmentObject private var app: AppState
    @State private var copied = false
    var body: some View {
        HStack(spacing: 10) {
            Dot(color: dot)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title).font(.system(size: 13, weight: .medium)).foregroundColor(Z.text).lineLimit(1)
                Text(s.subtitle).font(.system(size: 12)).foregroundColor(Z.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(copied ? app.f.t("copied") : s.time).font(mono(12)).foregroundColor(copied ? Z.good : Z.secondary).lineLimit(1)
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onTapGesture { copy(s.command, $copied) }
        .help(app.f.t("main.copyCommand") + ": " + s.command)
    }
}

struct TotalsBlock: View {
    let vm: MainVM
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(vm.totals.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.totals[i].value).font(mono(16, .semibold)).foregroundColor(Z.text).lineLimit(1)
                    Text(vm.totals[i].label).font(.system(size: 11)).foregroundColor(Z.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Divider1(color: Z.control) }
    }
}
