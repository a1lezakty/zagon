import SwiftUI
import ZagonUIModel

/// Settings → Worklogs: `[worklog]` as the zagon the tasks come from has it, written there and on every other source
/// (`log config`), and that source's exclusions. Rebuilding when "What to log" opens is this Mac's own.
struct WorklogCard: View {
    @EnvironmentObject private var app: AppState
    @State private var zoneOpen = false
    /// The project key being typed; nil: not adding one.
    @State private var adding: String? = nil

    var body: some View {
        let f = app.f, s = app.currentTaskSource
        Card(spacing: 12) {
            Text(f.t("settings.wl")).font(.system(size: 15, weight: .semibold))
            Text(f.t("settings.wl.note")).font(.system(size: 13)).foregroundColor(Z.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let s, let entry = app.worklogConfig[s] {
                if let c = entry { rows(c, s, f) } else { note(f.t("settings.wl.none")) }
            }
            if let m = app.worklogConfigMessage {
                Text(m).font(.system(size: 12)).foregroundColor(Z.bad).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 13)).foregroundColor(Z.text)
        .frame(maxWidth: 640, alignment: .leading)
        .task(id: s) {
            app.worklogConfigMessage = nil
            app.loadWorklogConfig()
        }
    }

    @ViewBuilder func rows(_ c: TaskBackend.WorklogConfig, _ s: TaskBackend.Source, _ f: Fmt) -> some View {
        let now = app.provider.now, machine = c.machineTz.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
        let own = c.projects ?? [], jira = (c.jiraProjects ?? []).filter { !own.contains($0) }
        let daySummary = c.daySummary ?? true, atEnd = c.rebuildAtEnd ?? true
        if app.taskSources.count > 1 { note(f.t("settings.wl.shown", app.sourceName(s))) }
        line(f.t("settings.wl.tz")) {
            Flow(spacing: 12, lineSpacing: 6) {
                PillButton(title: c.tz.flatMap(TimeZone.init(identifier:)).map { Zones.label($0, at: now) }
                           ?? f.t("settings.wl.tzMachine", Zones.label(machine, at: now)), height: 30) { zoneOpen = true }
                    .popover(isPresented: $zoneOpen, arrowEdge: .bottom) {
                        ZonePicker(choice: ZoneChoice(id: c.tz, machine: machine) { id in
                            zoneOpen = false
                            if id != c.tz { app.setWorklog("tz", id ?? "system") { $0.tz = id } }
                        })
                        .environmentObject(app)
                    }
                Text(f.t("settings.wl.machine", Zones.label(machine, at: now))).foregroundColor(Z.muted).frame(height: 30)
            }
            note(f.t("settings.wl.tzNote"))
        }
        line(f.t("settings.wl.keys"), sub: f.t("settings.wl.keysSub")) {
            Flow(spacing: 6, lineSpacing: 6) {
                ForEach(jira, id: \.self) { chip($0) }
                ForEach(own, id: \.self) { k in
                    chip(k) { app.editProjects(remove: k) }
                }
                if let typed = adding {
                    Field(placeholder: "PROJ", text: Binding(get: { typed }, set: { adding = $0.uppercased() }), height: 28)
                        .frame(width: 96)
                        .onSubmit { add(own) }
                    PillButton(title: f.t("settings.wl.add"), height: 28) { add(own) }
                } else {
                    Button { adding = "" } label: {
                        Text("+ " + f.t("settings.wl.add")).foregroundColor(Z.body).padding(.horizontal, 12).frame(height: 28)
                            .overlay(Capsule().strokeBorder(Z.buttonBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            note(f.t("settings.wl.keysNote"))
        }
        line(f.t("settings.wl.rebuild")) {
            SettingsScreen.CheckRow(title: f.t("settings.wl.rebuildEnd"), on: atEnd) {
                app.setWorklog("rebuild_at_end", String(!atEnd)) { $0.rebuildAtEnd = !atEnd }
            }
            SettingsScreen.CheckRow(title: f.t("settings.wl.rebuildOpen"), on: app.rebuildOnOpen) { app.rebuildOnOpen.toggle() }
            note(f.t("settings.wl.rebuildNote"))
        }
        line(f.t("settings.wl.text")) {
            Segmented(items: [f.t("settings.wl.textShort"), f.t("settings.wl.textSummary")], selected: daySummary ? 1 : 0, height: 30,
                      fontSize: 13) { i in
                if (i == 1) != daySummary { app.setWorklog("day_summary", String(i == 1)) { $0.daySummary = i == 1 } }
            }
            note(f.t("settings.wl.textNote"))
        }
        line(f.t("settings.wl.link")) { note(f.t("settings.wl.linkNote")) }
        line(f.t("settings.wl.exclude")) {
            let excluded = c.exclude ?? []
            if excluded.isEmpty { note(f.t("settings.wl.excludeNone")) }
            ForEach(excluded, id: \.self) { e in
                HStack(spacing: 8) {
                    Text(["project", "task", "session"].contains(e.kind)
                         ? f.t("settings.wl.kind." + e.kind, e.kind == "session" ? String(e.name.prefix(8)) : e.name) : e.kind + " " + e.name)
                    Button(f.t("settings.wl.remove")) { app.removeExclusion(e) }.buttonStyle(.plain).foregroundColor(Z.link)
                }
            }
        }
    }

    /// A Jira project key typed in: letters first, then letters, digits or "_".
    func add(_ own: [String]) {
        let k = (adding ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        adding = nil
        guard k.count >= 2, k.first?.isLetter == true, k.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
              !own.contains(k) else { return }
        app.editProjects(add: k)
    }

    func line<V: View>(_ title: String, sub: String? = nil, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider1(color: Z.border)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundColor(Z.body)
                    if let sub { Text(sub).font(.system(size: 12)).foregroundColor(Z.muted) }
                }
                .frame(width: 150, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) { content() }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundColor(Z.muted).fixedSize(horizontal: false, vertical: true)
    }

    /// A project key; with `remove`, one typed here (Jira's own have no ×).
    func chip(_ key: String, remove: (() -> Void)? = nil) -> some View {
        HStack(spacing: 6) {
            Text(key).font(code(13, .medium)).foregroundColor(Z.text)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(Z.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(app.f.t("settings.wl.remove") + " " + key)
            }
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(Capsule().fill(remove == nil ? Z.control : Z.focusFill))
    }
}
