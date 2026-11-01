import AppKit
import SwiftUI
import ZagonUIModel

struct SettingsScreen: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.isSnapshot) private var snapshot
    /// The summary time being typed; nil = the file's.
    @State private var summaryTime: String?
    @State private var summaryTimeBad = false
    var body: some View {
        let f = app.f
        Page {
            Header(f.t("nav.settings"))
            Card(spacing: 12) {
                Text(f.t("connect.title")).font(.system(size: 15, weight: .semibold))
                Text(f.t("connect.note")).font(.system(size: 13)).foregroundColor(Z.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let cli = app.cli {
                    ForEach(cli.ok, id: \.self) { line in
                        HStack(spacing: 8) { Dot(color: Z.working, size: 7); Text(line) }
                    }
                    ForEach(cli.missing, id: \.self) { line in
                        HStack(spacing: 8) { Dot(color: Z.bad, size: 7); Text(line) }
                    }
                    ForEach(cli.notes, id: \.self) { line in
                        // Claude's tools left out matter: said in words, not as doctor's line.
                        let tools = line.hasPrefix("claude: MCP skipped")
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Dot(color: tools ? Z.waiting : Z.faint, size: 7)
                            Text(tools ? f.t("connect.mcpSkipped") : line).foregroundColor(tools ? Z.text : Z.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else if AppState.cliPath == nil {
                    Text(f.t("connect.onlyApp")).foregroundColor(Z.muted)
                }
                HStack(spacing: 8) {
                    let busy = app.cliBusy, running = app.cliCommand
                    PillButton(title: busy && running == "install" ? f.t("connect.connecting") : f.t("connect.button"), primary: true,
                               busy: busy && running == "install") { app.runCLI("install") }
                    PillButton(title: f.t("connect.remove"), busy: busy && running == "uninstall") { app.runCLI("uninstall") }
                    PillButton(title: f.t("connect.check"), busy: busy && running == nil) { app.runCLI(nil) }
                }
                .disabled(app.cliBusy)
                if let e = app.cliError, !EditorPanelsCard.ran(app) {
                    Text(f.t("connect.failed", e)).font(.system(size: 12)).foregroundColor(Z.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 13)).foregroundColor(Z.text)
            .frame(maxWidth: 640, alignment: .leading)
            EditorPanelsCard()
            JiraCard()
            if app.currentTaskSource != nil { WorklogCard() }
            ZoneCard()
            Card(spacing: 12) {
                Text(f.t("settings.view")).font(.system(size: 15, weight: .semibold))
                HStack(spacing: 12) {
                    Text(f.t("settings.view.limits")).font(.system(size: 13)).foregroundColor(Z.body).frame(width: 90, alignment: .leading)
                    Segmented(items: [f.t("settings.view.rings"), f.t("settings.view.pace")], selected: app.pace ? 1 : 0) {
                        app.pace = $0 == 1
                    }
                }
                CheckRow(title: f.t("settings.view.weekdays"), on: app.paceWeekdays) { app.paceWeekdays.toggle() }
                if AppState.cliPath != nil {
                    CheckRow(title: f.t("settings.launch"), on: app.launchAtLogin) { app.setLaunchAtLogin(!app.launchAtLogin) }
                }
                HStack(spacing: 12) {
                    Text(f.t("settings.view.icon")).font(.system(size: 13)).foregroundColor(Z.body).frame(width: 90, alignment: .leading)
                    Segmented(items: [f.t("settings.view.colored"), f.t("settings.view.mono")], selected: app.monoIcon ? 1 : 0) {
                        app.monoIcon = $0 == 1
                    }
                }
                Text(f.t("settings.view.note")).font(.system(size: 12)).foregroundColor(Z.muted)
                    .fixedSize(horizontal: false, vertical: true)
                colors(f)
            }
            .frame(maxWidth: 640, alignment: .leading)
            Card(spacing: 12) {
                Text(f.t("settings.notify")).font(.system(size: 15, weight: .semibold))
                Text(f.t("settings.notify.note")).font(.system(size: 13)).foregroundColor(Z.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(NotifySettings.categories, id: \.self) { c in
                    let on = app.notify.thresholds(c)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(NotifySettings.title(c, f)).font(.system(size: 13, weight: .medium)).foregroundColor(Z.text)
                        HStack(spacing: 6) {
                            ForEach(NotifySettings.steps, id: \.self) { v in
                                Chip(title: "\(v)", selected: on.contains(v), height: 24) {
                                    app.editNotify { $0.set(c, v, on: !on.contains(v)) }
                                }
                            }
                        }
                    }
                }
                CheckRow(title: f.t("settings.notify.mac"), on: app.macNotify) {
                    app.macNotify.toggle()
                    if app.macNotify { app.askNotify() }
                }
                if app.macNotify && app.notifyDenied {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(f.t("settings.notify.denied")).font(.system(size: 12)).foregroundColor(Z.bad)
                            .fixedSize(horizontal: false, vertical: true)
                        PillButton(title: f.t("settings.notify.openSystem"), height: 28, radius: 8, fontSize: 12) {
                            MacNotifications.openSettings()
                        }
                    }
                    .padding(.leading, 25)
                }
                if app.macNotify {
                    CheckRow(title: f.t(app.remoteHosts.isEmpty ? "settings.notify.remoteAlone" : "settings.notify.remote"),
                             on: app.macNotifyRemote) { app.macNotifyRemote.toggle() }
                        .padding(.leading, 25)
                }
                let reset = app.notify.limitReset
                CheckRow(title: f.t("settings.notify.reset"), on: reset) { app.editNotify { $0.limitReset = !reset } }
                if let e = app.notifyError {
                    Text(f.t("settings.notify.failed", e)).font(.system(size: 12)).foregroundColor(Z.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            // Allowed or denied in System Settings meanwhile: read again whenever settings show.
            .onAppear { if !snapshot { app.checkNotify() } }
            summary(f)
            Card(spacing: 12) {
                Text(f.t("settings.servers")).font(.system(size: 15, weight: .semibold))
                Text(f.t("settings.servers.note")).font(.system(size: 13)).foregroundColor(Z.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                let hosts = app.sshHosts, errors = app.hostErrors, hints = app.hostHints
                if hosts.isEmpty {
                    Text(f.t("settings.servers.none")).font(.system(size: 13)).foregroundColor(Z.muted)
                }
                ForEach(hosts, id: \.self) { h in
                    let on = app.remoteHosts.contains(h)
                    Button { app.setRemote(h, on: !on) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 15))
                                .foregroundColor(on ? Z.week : Z.muted)
                            Text(h).font(.system(size: 14)).foregroundColor(Z.text)
                            if on { Dot(color: app.serverOnline(h) ? Z.working : Z.faint, size: 7) }
                            if on, let e = errors[h] {
                                Text(e == Remote.oldZagon ? f.t("servers.oldZagon") : e == Remote.noZagon ? f.t("servers.noZagonShort") : e).font(.system(size: 12)).foregroundColor(Z.muted).lineLimit(1).truncationMode(.middle)
                            } else if on, let hint = hints[h] {
                                Text(f.t(hint)).font(.system(size: 12)).foregroundColor(Z.muted).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if on, errors[h] == Remote.noZagon {
                        CopyButton(title: f.t("servers.copyInstall"), height: 28, radius: 8, fontSize: 12) { Remote.installCommand }
                            .padding(.leading, 25)
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            Card(spacing: 12) {
                Text(f.t("settings.updates")).font(.system(size: 15, weight: .semibold))
                Text(f.t("settings.updates.version", AppState.version)).font(.system(size: 13)).foregroundColor(Z.secondary)
                CheckRow(title: f.t("settings.updates.auto"), on: app.autoUpdate) { app.autoUpdate.toggle() }
                PillButton(title: f.t("main.checkUpdates")) { app.checkForUpdates() }
            }
            .frame(maxWidth: 640, alignment: .leading)
            Card(spacing: 12) {
                Text(f.t("settings.diag")).font(.system(size: 15, weight: .semibold))
                Text(f.t("settings.diag.note")).font(.system(size: 13)).foregroundColor(Z.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                PillButton(title: f.t("settings.diag.collect")) { collect(f) }
            }
            .frame(maxWidth: 640, alignment: .leading)
        }
    }

    /// When the services of the checked servers write the day summary (the Mac has none): the servers' time when they
    /// answered, else this Mac's config.toml for the switch and "as on the server" for the time.
    func summary(_ f: Fmt) -> some View {
        let servers = app.remoteHosts, known = app.summaries.sharedAt(servers)
        let at = known.map { NotifySettings.minutes($0) } ?? app.notify.summaryAt
        let text = Binding(get: { summaryTime ?? known.flatMap(NotifySettings.minutes).map(NotifySettings.clock) ?? "" },
                           set: { summaryTime = $0; summaryTimeBad = false })
        return Card(spacing: 12) {
            Text(f.t("settings.summary")).font(.system(size: 15, weight: .semibold))
            // Without a server the Mac rebuilds at the end of the day itself, when that is on (`startWorklogTexts`).
            let mac = servers.isEmpty && app.endOfDayTexts && (app.worklogConfig[.local] ?? nil)?.rebuildAtEnd != false
            Text(f.t(!servers.isEmpty ? "settings.summary.note" : mac ? "settings.summary.mac" : "settings.summary.noServer")).font(.system(size: 13))
                .foregroundColor(Z.secondary).fixedSize(horizontal: false, vertical: true)
            CheckRow(title: f.t("settings.summary.on"), on: at != nil) {
                summaryTime = nil
                app.setSummaryTime(at == nil ? 20 * 60 : nil)
            }
            .disabled(servers.isEmpty)
            if at != nil && !servers.isEmpty {
                HStack(spacing: 12) {
                    Text(f.t("settings.summary.time")).font(.system(size: 13)).foregroundColor(Z.body).frame(width: 90, alignment: .leading)
                    Field(placeholder: known == nil ? f.t("settings.summary.asServer") : "20:00", text: text, height: 30).frame(width: 130)
                    PillButton(title: f.t("settings.summary.save"), height: 30, radius: 8, fontSize: 12) {
                        guard let m = NotifySettings.minutes(text.wrappedValue) else { summaryTimeBad = true; return }
                        summaryTime = nil
                        app.setSummaryTime(m)
                    }
                }
            }
            if summaryTimeBad {
                Text(f.t("settings.summary.bad")).font(.system(size: 12)).foregroundColor(Z.bad)
            }
            if let m = app.summaries.atMessage, !m.isEmpty {
                Text(m).font(.system(size: 12)).foregroundColor(Z.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(servers.isEmpty ? 0.55 : 1)
        .frame(maxWidth: 640, alignment: .leading)
        // Before the task: a server that did not answer last time is asked again (an answer still on its way stays one).
        .onAppear { app.summaries.unanswered = [] }
        .task(id: servers) { app.loadSummaryTimes() }
    }

    /// Ring colours per AI, 5 hours and the week: a palette swatch or the system colour panel, a live preview, a reset.
    func colors(_ f: Fmt) -> some View {
        let standard = Tool.allCases.allSatisfy { app.colors($0) == RingColors.standard($0) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(f.t("settings.colors")).font(.system(size: 13)).foregroundColor(Z.body).frame(width: 90, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Tool.allCases, id: \.self) { tool in
                        Text(tool.name).font(.system(size: 12, weight: .semibold)).foregroundColor(Z.secondary)
                            .padding(.top, tool == .claude ? 0 : 6)
                        ForEach(LimitKind.allCases, id: \.self) { swatches(tool, $0, f) }
                    }
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Text(f.t("settings.colors.preview")).font(.system(size: 13)).foregroundColor(Z.body).frame(width: 90, alignment: .leading)
                ColorPreview(claude: app.colors(.claude), codex: app.colors(.codex), colored: !app.monoIcon, f: f)
            }
            HStack(spacing: 12) {
                Color.clear.frame(width: 90, height: 1)
                PillButton(title: f.t("settings.colors.reset"), height: 28, radius: 8, fontSize: 12) {
                    for t in Tool.allCases { app.setColors(t, .standard(t)) }
                }
                .disabled(standard)
            }
            Text(f.t("settings.colors.note")).font(.system(size: 12)).foregroundColor(Z.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static let colorNames: [UInt32: String] = [
        Palette.fiveHour: "color.orange", Palette.week: "color.blue", Palette.working: "color.green",
        Palette.violet: "color.violet", Palette.good: "color.mint", Palette.link: "color.sky", Palette.muted: "color.grey",
    ]
    static let rainbow = AngularGradient(gradient: Gradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red]),
                                         center: .center, startAngle: .zero, endAngle: .degrees(360))

    func swatches(_ tool: Tool, _ kind: LimitKind, _ f: Fmt) -> some View {
        let app = self.app
        let now = kind == .week ? app.colors(tool).week : app.colors(tool).five
        let title = f.t(kind == .week ? "limit.week" : "limit.five"), custom = !RingColors.swatches.contains(now)
        // read afresh: the colour panel calls back long after this body
        let set = { (v: UInt32) in
            var c = app.colors(tool)
            if kind == .week { c.week = v } else { c.five = v }
            app.setColors(tool, c)
        }
        return HStack(spacing: 4) {
            Text(title).font(.system(size: 12)).foregroundColor(Z.body).frame(width: 64, alignment: .leading)
            ForEach(RingColors.swatches, id: \.self) { s in
                Button { set(s) } label: { Swatch(fill: Color(hex: s), selected: s == now) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(tool.name), \(title): \(f.t(Self.colorNames[s] ?? "settings.colors.other"))")
                    .accessibilityAddTraits(s == now ? .isSelected : [])
            }
            Button { ColorPanel.shared.open("\(tool.name) · \(title)", now, set) } label: {
                HStack(spacing: 6) {
                    Swatch(fill: Self.rainbow, selected: custom, dot: custom ? Color(hex: now) : nil)
                    Text(f.t("settings.colors.other")).font(.system(size: 12)).foregroundColor(Z.body)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
            .accessibilityLabel("\(tool.name), \(title): \(f.t("settings.colors.other"))")
            .accessibilityAddTraits(custom ? .isSelected : [])
        }
    }

    /// A colour dot, ringed when chosen; `dot` is a picked colour shown inside the rainbow one.
    struct Swatch<S: ShapeStyle>: View {
        let fill: S
        let selected: Bool
        var dot: Color?
        var body: some View {
            Circle().fill(fill).frame(width: 18, height: 18)
                .overlay { if let dot { Circle().fill(dot).frame(width: 10, height: 10) } }
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Z.text : Color.clear, lineWidth: 2))
                .contentShape(Circle())
        }
    }

    struct CheckRow: View {
        let title: String
        let on: Bool
        let action: () -> Void
        var body: some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 15))
                        .foregroundColor(on ? Z.week : Z.muted)
                    Text(title).font(.system(size: 13)).foregroundColor(Z.text)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    func collect(_ f: Fmt) {
        do {
            let zip = try app.collectDiagnostics()
            app.say(f.t("settings.diag.saved"), reveal: zip, seconds: 10)
        } catch {
            app.say(f.t("settings.diag.failed", Log.scrub(String(describing: error))), error: true)
        }
    }
}

/// The menu bar in the chosen colours, on a light and a dark bar: each AI alone (its pair of rings) and both (a
/// ring-in-ring each). Fixed sample values, below the warnings.
struct ColorPreview: View {
    let claude: RingColors
    let codex: RingColors
    let colored: Bool
    let f: Fmt
    static let column: CGFloat = 100

    var body: some View {
        let a = MenuBarVM.AI(tool: .claude, five: 62, week: 35, colors: claude)
        let b = MenuBarVM.AI(tool: .codex, five: 18, week: 71, colors: codex)
        let samples = [(f.t("settings.colors.alone", "Claude"), [a]), (f.t("settings.colors.alone", "Codex"), [b]),
                       (f.t("settings.colors.both"), [a, b])]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                ForEach(samples.indices, id: \.self) {
                    Text(samples[$0].0).font(.system(size: 11)).foregroundColor(Z.muted).lineLimit(1).frame(width: Self.column)
                }
            }
            ForEach([true, false], id: \.self) { light in
                HStack(spacing: 0) {
                    ForEach(samples.indices, id: \.self) {
                        MenuBarLabel(vm: MenuBarVM(ais: samples[$0].1, f), colored: colored,
                                     tint: light ? .black.opacity(0.85) : .white)
                            .frame(width: Self.column)
                    }
                }
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: light ? 0xE6E6EA : 0x2A2A2E)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The system colour panel behind "Other…". There is one panel, so it edits the colour it was last opened for.
@MainActor
final class ColorPanel: NSObject {
    static let shared = ColorPanel()
    private var apply: ((UInt32) -> Void)?

    func open(_ title: String, _ color: UInt32, _ apply: @escaping (UInt32) -> Void) {
        let p = NSColorPanel.shared
        self.apply = nil
        p.showsAlpha = false
        p.color = NSColor(srgbRed: CGFloat(color >> 16 & 0xFF) / 255, green: CGFloat(color >> 8 & 0xFF) / 255,
                          blue: CGFloat(color & 0xFF) / 255, alpha: 1)
        p.title = title
        p.setTarget(self)
        p.setAction(#selector(changed(_:)))
        self.apply = apply
        p.makeKeyAndOrderFront(nil)
    }

    @objc private func changed(_ p: NSColorPanel) {
        guard let c = p.color.usingColorSpace(.sRGB) else { return }
        func byte(_ v: CGFloat) -> UInt32 { UInt32((min(1, max(0, v)) * 255).rounded()) }
        apply?(byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent))
    }
}

/// Settings → Claude limits from the IDE panel: `zagon editor-panels on|off` through the CLI inside Zagon.app, as
/// connecting does (one CLI run at a time, the error under the buttons and in a toast).
struct EditorPanelsCard: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.isSnapshot) private var snapshot

    /// The CLI's last run was this card's.
    static func ran(_ app: AppState) -> Bool { app.cliCommand?.hasPrefix("editor-panels") ?? false }

    var body: some View {
        let f = app.f
        Card(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(f.t("editors.title")).font(.system(size: 15, weight: .semibold))
                Caps(text: f.t("editors.tag"), color: Z.week, size: 11)
            }
            Text(f.t("editors.note")).font(.system(size: 13)).foregroundColor(Z.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let vm = app.editors {
                ForEach(vm.lines, id: \.text) { line in
                    HStack(spacing: 8) { Dot(color: line.on ? Z.working : Z.faint, size: 7); Text(line.text) }
                }
                ForEach(vm.notes, id: \.self) { note in
                    Text(note).font(.system(size: 12)).foregroundColor(Z.muted).fixedSize(horizontal: false, vertical: true)
                }
                if AppState.cliPath != nil || snapshot {
                    HStack(spacing: 8) {
                        let busy = app.cliBusy, running = app.cliCommand
                        if vm.canEnable {
                            PillButton(title: f.t("editors.enable"), busy: busy && running == "editor-panels on") {
                                app.runCLI("editor-panels on")
                            }
                        }
                        if vm.canDisable {
                            PillButton(title: f.t("editors.disable"), busy: busy && running == "editor-panels off") {
                                app.runCLI("editor-panels off")
                            }
                            // Reads the editors again; the line below reads the panel's marks on every redraw.
                            PillButton(title: f.t("editors.check")) { app.readEditors() }
                        }
                    }
                    .disabled(app.cliBusy)
                    if vm.canDisable {
                        // The samples' line is made up: a real one reads the machine rendering them.
                        Text(snapshot ? EditorPanelsVM.panelCheck(run: f.now - 3600, reading: f.now - 3000, f) : EditorPanelsVM.panelCheck(f)).font(.system(size: 12)).foregroundColor(Z.body).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(f.t("connect.onlyApp")).foregroundColor(Z.muted)
                }
            }
            Text(f.t("editors.effects")).font(.system(size: 12)).foregroundColor(Z.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text(f.t("editors.cursorAgent")).font(.system(size: 12)).foregroundColor(Z.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let e = app.cliError, Self.ran(app) {
                Text(f.t("connect.failed", e)).font(.system(size: 12)).foregroundColor(Z.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 13)).foregroundColor(Z.text)
        .frame(maxWidth: 640, alignment: .leading)
        .onAppear { app.readEditors() }
    }
}
