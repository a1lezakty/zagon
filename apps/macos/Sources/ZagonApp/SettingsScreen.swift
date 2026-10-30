import AppKit
import SwiftUI
import ZagonUIModel

struct SettingsScreen: View {
    @EnvironmentObject private var app: AppState
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
                        HStack(spacing: 8) { Dot(color: Z.faint, size: 7); Text(line).foregroundColor(Z.muted) }
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
                if let e = app.cliError {
                    Text(f.t("connect.failed", e)).font(.system(size: 12)).foregroundColor(Z.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 13)).foregroundColor(Z.text)
            .frame(maxWidth: 640, alignment: .leading)
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
                    if app.macNotify { MacNotifications.start() }
                }
                if app.macNotify {
                    CheckRow(title: f.t("settings.notify.remote"), on: app.macNotifyRemote) { app.macNotifyRemote.toggle() }
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
                                Text(e == Remote.oldZagon ? f.t("servers.oldZagon") : e).font(.system(size: 12)).foregroundColor(Z.muted).lineLimit(1).truncationMode(.middle)
                            } else if on, let hint = hints[h] {
                                Text(f.t(hint)).font(.system(size: 12)).foregroundColor(Z.muted).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
