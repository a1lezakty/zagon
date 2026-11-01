import SwiftUI
import ZagonUIModel

struct WorklogScreen: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.isSnapshot) private var snapshot
    /// nil = today
    @State private var day: Date?
    @State private var confirm = false

    var body: some View {
        if app.worklogPeriod != nil { ReconcileScreen() } else { dayBody }
    }

    @ViewBuilder var dayBody: some View {
        // The day, the intervals and the bar in the source's worklog zone (the design sample: the app's).
        let zone = app.taskBackend == nil ? app.zone : app.worklogZone
        let f = Fmt(lang: app.lang, timeZone: zone, now: app.provider.now)
        let d = day ?? f.now
        let key = TaskBackend.day(d, zone), cache = app.tasksNow
        let data = app.taskBackend == nil ? app.provider.worklog(d)
            : cache.plans[key]?.worklog(f)
                ?? WorklogData(day: f.startOfDay(d), workStart: nil, workEnd: nil, userSec: 0, sessionSec: 0, rows: [], splits: [])
        let vm = WorklogVM(data, f, machine: app.zone, host: app.currentTaskSource.map(app.sourceName))
        let rebuilding = app.currentTaskSource.map { app.planRebuilding.contains(app.planKey($0, key)) } ?? false
        Page(spacing: 18) {
            Header(vm.title, prev: { day = f.addDays(-1, to: d) }, next: { day = f.addDays(1, to: d) }) { WorklogMode() }
            SourceBar { app.loadTasks(.plan(key), force: true) }
            if let title = vm.textsTitle {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text").font(.system(size: 13)).foregroundColor(Z.link)
                        (Text(title).fontWeight(.semibold).foregroundColor(Z.text) + Text(" · " + vm.textsDetail).foregroundColor(Z.secondary))
                            .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        PillButton(title: f.t("worklog.rebuild"), height: 30, busy: rebuilding) { app.rebuildPlan(key) }
                            .disabled(rebuilding)
                    }
                    .padding(.vertical, 8).padding(.leading, 14).padding(.trailing, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Z.focusFill))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Z.focus))
                    if let z = vm.zoneLine {
                        Text(z).font(.system(size: 12)).foregroundColor(Z.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            StatsRow(stats: vm.stats, highlightLast: true)
            if vm.rows.isEmpty {
                Card(spacing: 10) {
                    Text(f.t("worklog.empty")).font(.system(size: 13)).foregroundColor(Z.secondary)
                    if !vm.excluded.isEmpty || !vm.unassigned.isEmpty { parts(vm, key, f) }
                }
            } else {
                Card(spacing: 10) {
                    HStack(spacing: 14) {
                        H2(text: f.t("worklog.byTask"))
                        Spacer(minLength: 0)
                        HStack(spacing: 6) {
                            Hatch().frame(width: 14, height: 8).clipShape(RoundedRectangle(cornerRadius: 3))
                            Text(f.t("dest.alreadyLogged"))
                        }
                        .font(.system(size: 12)).foregroundColor(Z.secondary)
                    }
                    VStack(spacing: 6) {
                        bar(vm.segments)
                        Ticks(labels: vm.ticks)
                    }
                }
                Card(spacing: 10) {
                    HStack(spacing: 14) {
                        H2(text: f.t("worklog.plan"))
                        Spacer(minLength: 0)
                        if vm.textsTitle != nil {
                            HStack(spacing: 12) {
                                Text(f.t("worklog.src")).foregroundColor(Z.muted)
                                ForEach([WorklogTextSource.summary, .manual, .titles], id: \.self) { TextSourceLabel(source: $0) }
                            }
                            .font(.system(size: 12))
                        }
                    }
                    table(vm.rows, key, f)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(vm.notes.indices, id: \.self) { i in
                            Text(vm.notes[i]).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        }
                        if let s = app.currentTaskSource, app.jiraOff(s) { JiraConnectHint(source: s) }
                        parts(vm, key, f)
                    }
                    .font(.system(size: 13)).foregroundColor(Z.body)
                    .padding(.vertical, 10).padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Z.inset))
                    Flow(spacing: 8, lineSpacing: 8) {
                        if let commit = vm.commitTitle {
                            // Not while the plan loads or is rebuilt: what is shown is about to change.
                            PillButton(title: commit, primary: true, height: 38, radius: 10, fontSize: 14) {
                                if app.taskBackend != nil, cache.loading == 0 { confirm = true }
                            }
                            .disabled(cache.loading > 0)
                            .confirmationDialog(commit + "?", isPresented: $confirm) {
                                Button(f.t("worklog.commitYes")) { app.commitPlan(key) }
                                Button(f.t("common.cancel"), role: .cancel) {}
                            } message: {
                                // With where the day summaries go.
                                Text(([f.t("worklog.commitDetail")] + vm.commitNotes).joined(separator: "\n"))
                            }
                        }
                        PillButton(title: f.t("worklog.edit"), height: 38, radius: 10, fontSize: 14) {}
                        CopyButton(title: f.t("worklog.copy"), height: 38, radius: 10, fontSize: 14) { vm.copyText }
                    }
                    .padding(.top, 4)
                }
            }
            if let m = cache.message {
                Text(m).font(.system(size: 13)).foregroundColor(Z.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: "\(String(describing: app.currentTaskSource))|\(key)|\(app.planEpoch)") { app.openPlan(key) }
        .onChange(of: app.zoneShown) { _ in day = nil }
    }

    func bar(_ segments: [WorklogSegmentVM]) -> some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                ForEach(segments.indices, id: \.self) { i in
                    let s = segments[i]
                    ZStack(alignment: .leading) {
                        if s.logged { Hatch() } else { Color(hex: s.color) }
                        Text(s.label).font(.system(size: 11, weight: .semibold)).foregroundColor(Z.onSeries).lineLimit(1)
                            .padding(.horizontal, 8)
                    }
                    .frame(width: max(2, s.width * g.size.width), height: max(0, g.size.height - 6))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .offset(x: s.x * g.size.width, y: 3)
                }
            }
        }
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(Z.inset))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Z.laneBorder))
    }

    func table(_ rows: [WorklogRowVM], _ day: String, _ f: Fmt) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(f.t("worklog.col.task")).frame(width: 84, alignment: .leading)
                Text(f.t("worklog.col.span")).frame(width: 104, alignment: .leading)
                Text(f.t("worklog.col.time")).frame(width: 72, alignment: .trailing)
                Text(f.t("worklog.col.text")).frame(maxWidth: .infinity, alignment: .leading)
                Text(f.t("worklog.col.dest")).frame(width: 136, alignment: .leading)
            }
            .font(.system(size: 12, weight: .medium)).foregroundColor(Z.muted)
            .padding(.vertical, 6).padding(.horizontal, 6)
            ForEach(rows.indices, id: \.self) { i in
                let r = rows[i], open = r.editable && app.worklogOpen == r.anchor
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(r.key).font(code(13)).foregroundColor(Z.link).frame(width: 84, alignment: .leading)
                        Text(r.span).font(mono(13)).frame(width: 104, alignment: .leading)
                        Text(r.time).font(mono(13)).frame(width: 72, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 6) {
                            // Two lines with texts per row; the whole text is in the expanded row.
                            if !open {
                                Text(r.text).font(.system(size: 13)).lineSpacing(3).lineLimit(r.editable ? 2 : nil)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if r.editable { labels(r, open: open, f) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 4) {
                            DestChip(text: r.destination, kind: r.kind)
                            if r.editable, let task = r.taskKey { rowMenu(task, day, f) }
                        }
                        // "только Zagon" and the row's menu side by side.
                        .frame(width: 136, alignment: .leading)
                    }
                    .padding(.vertical, 10).padding(.horizontal, 6)
                    if open { RowEditor(row: r, day: day).id(r.anchor).padding(.bottom, 12) }
                }
                .foregroundColor(r.kind == .alreadyLogged ? Z.muted : Z.text)
                .overlay(alignment: .top) { Divider1(color: Z.border) }
            }
        }
    }

    /// "day summary · from the summary · expand"
    func labels(_ r: WorklogRowVM, open: Bool, _ f: Fmt) -> some View {
        HStack(spacing: 8) {
            if r.daySummary {
                Text(f.t("worklog.daySummary")).foregroundColor(Z.summaryTag)
                    .padding(.horizontal, 8).frame(height: 20).background(Capsule().fill(Z.summaryTagFill))
            }
            if let s = r.source { TextSourceLabel(source: s) }
            Text("·").foregroundColor(Z.faint)
            Button { app.worklogOpen = open ? nil : r.anchor } label: {
                HStack(spacing: 3) {
                    Text(f.t(open ? "worklog.collapse" : "worklog.expand"))
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold))
                }
            }
            .buttonStyle(.plain).foregroundColor(Z.link)
        }
        .font(.system(size: 12))
    }

    /// The row's menu: keep its task out of the plans.
    @ViewBuilder func rowMenu(_ task: String, _ day: String, _ f: Fmt) -> some View {
        let dots = Image(systemName: "ellipsis").font(.system(size: 12)).foregroundColor(Z.secondary).frame(width: 22, height: 22)
        if snapshot {
            dots
        } else if app.taskBackend != nil {
            Menu {
                Button(f.t("worklog.exclude") + " · " + task) { app.editPlan(day, others: true) { try $0.exclude("task", task, add: true) } }
            } label: { dots }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(f.t("worklog.exclude") + " " + task)
        }
    }

    /// Time with no task by project ("don't log") and what is kept out ("bring back").
    @ViewBuilder func parts(_ vm: WorklogVM, _ day: String, _ f: Fmt) -> some View {
        let lines = vm.unassigned.map { ($0, true) } + vm.excluded.map { ($0, false) }
        ForEach(lines.indices, id: \.self) { i in
            let p = lines[i].0, add = lines[i].1
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(p.text).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                if (app.taskBackend != nil || snapshot) && p.action {
                    Text("·").foregroundColor(Z.faint)
                    Button(f.t(add ? "worklog.excludeLink" : "worklog.unexclude")) {
                        app.editPlan(day, others: true) { try $0.exclude(p.kind, p.name, add: add) }
                    }
                    .buttonStyle(.plain).foregroundColor(Z.link)
                }
            }
            .font(.system(size: 13)).foregroundColor(Z.body)
        }
    }
}

/// "from the summary" / "edited by hand" / "from session titles", the last with why.
struct TextSourceLabel: View {
    @EnvironmentObject private var app: AppState
    let source: WorklogTextSource
    var body: some View {
        let f = app.f, look = Self.look(source)
        let label = HStack(spacing: 4) {
            Image(systemName: look.icon).font(.system(size: 11))
            Text(f.t("worklog.src." + source.rawValue))
        }
        .foregroundColor(look.color)
        if source == .titles { label.help(f.t("worklog.src.titlesHelp")) } else { label }
    }

    static func look(_ s: WorklogTextSource) -> (icon: String, color: Color) {
        switch s {
        case .summary: return ("doc.text", Z.link)
        case .manual: return ("pencil", Z.working)
        case .titles: return ("list.bullet", Z.secondary)
        }
    }
}

/// An expanded plan row: its text (the day summary on the task's longest row) to edit, rebuild or shorten through the
/// CLI, where the day summary goes, and the sessions the row's time came from.
struct RowEditor: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.isSnapshot) private var snapshot
    let row: WorklogRowVM
    let day: String
    /// Editing the day summary (where the row has one, it opens on it), else the row's text.
    @State private var onSummary: Bool? = nil
    /// What is typed; nil = the plan's text.
    @State private var draft: String? = nil
    /// The button whose call runs.
    @State private var running: String? = nil

    var body: some View {
        let f = app.f, summary = onSummary ?? row.daySummary
        let saved = summary ? row.summary ?? "" : row.plain
        let text = Binding(get: { draft ?? saved }, set: { draft = $0 })
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                if row.daySummary {
                    Segmented(items: [f.t("worklog.text.summary"), f.t("worklog.text.row")], selected: summary ? 0 : 1) { i in
                        onSummary = i == 0
                        draft = nil
                    }
                }
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if snapshot {
                            Text(text.wrappedValue).lineSpacing(3).frame(maxWidth: .infinity, alignment: .topLeading)
                                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 18)
                        } else {
                            TextEditor(text: text).scrollContentBackground(.hidden).frame(minHeight: summary ? 280 : 90)
                                .disabled(running != nil)
                        }
                    }
                    .font(.system(size: 13)).foregroundColor(Z.text)
                    .padding(12)
                    Text(f.t.plural("worklog.chars", text.wrappedValue.count)).font(.system(size: 11)).foregroundColor(Z.muted).padding(8)
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Z.inset))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(hex: 0x4F8BFF), lineWidth: 1.5))
                Flow(spacing: 8, lineSpacing: 8) {
                    PillButton(title: f.t("worklog.text.rebuild"), busy: running == "rebuild") {
                        run("rebuild") { [id = row.id ?? 0] in try $0.rebuildText(id, summary: summary, shorten: false) }
                    }
                    PillButton(title: f.t("worklog.text.shorten"), busy: running == "shorten") {
                        run("shorten") { [id = row.id ?? 0] in try $0.rebuildText(id, summary: summary, shorten: true) }
                    }
                    PillButton(title: f.t("worklog.text.save"), primary: true, busy: running == "save") {
                        let typed = text.wrappedValue
                        run("save") { [id = row.id ?? 0] in try $0.setText(id, typed, summary: summary) }
                    }
                    .disabled(draft == nil || draft == saved)
                    if row.daySummary, row.kind == .jira, let task = row.taskKey {
                        Segmented(items: [f.t("worklog.summaryHere"), f.t("worklog.summaryComment")], selected: row.summaryAsComment ? 1 : 0,
                                  height: 30) { i in
                            if (i == 1) != row.summaryAsComment { app.setSummaryComment(day, task: task, i == 1) }
                        }
                    }
                }
                .disabled(running != nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                Text(f.t("worklog.from")).font(.system(size: 14, weight: .semibold)).foregroundColor(Z.text)
                ForEach(row.sessions.indices, id: \.self) { i in
                    let s = row.sessions[i]
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(s.title).font(code(13)).foregroundColor(Z.text).lineLimit(1).truncationMode(.middle)
                            if !s.role.isEmpty {
                                Text(s.role).font(.system(size: 11)).foregroundColor(Z.secondary)
                                    .padding(.horizontal, 7).frame(height: 18).background(Capsule().fill(Z.control))
                            }
                            Spacer(minLength: 0)
                            Text(s.time).font(mono(12)).foregroundColor(Z.body)
                        }
                        Text(s.how).font(.system(size: 12)).foregroundColor(Z.muted).lineLimit(2)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Z.card))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Z.border))
                }
                Text(row.explain).font(.system(size: 12)).foregroundColor(Z.muted).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 300, alignment: .leading)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Z.ground))
        // The day summary follows its task to another row; a row text typed for the old row is not for the new one.
        .onChange(of: row.id) { _ in if !(onSummary ?? row.daySummary) { draft = nil } }
    }

    /// A text call, then the plan again; the typed text stays when it failed.
    func run(_ button: String, _ edit: @escaping (TaskBackend) throws -> Void) {
        guard app.taskBackend != nil else { return }
        running = button
        app.editPlan(day, done: { ok in
            running = nil
            if ok { draft = nil }
        }, edit)
    }
}

/// "Day | Period" over the worklog screen; a period starts as this month.
struct WorklogMode: View {
    @EnvironmentObject private var app: AppState
    var body: some View {
        let f = app.f
        Segmented(items: [f.t("rec.mode.day"), f.t("rec.mode.period")], selected: app.worklogPeriod == nil ? 0 : 1, height: 30,
                  fontSize: 13) { i in
            if i == 0 { app.worklogPeriod = nil } else if app.worklogPeriod == nil {
                let r = RecPeriod.thisMonth.range(f)
                app.worklogPeriod = r.from...r.to
            }
        }
    }
}

struct DestChip: View {
    let text: String
    let kind: WorklogDestination
    var body: some View {
        let (bg, fg): (UInt32, UInt32) = kind == .alreadyLogged ? (0x2A2A2E, 0xA9A9B0)
            : kind == .jira ? (0x1F2E46, 0x9CC3FF) : (0x1E3A33, 0x5FD9B8)
        Text(text).font(.system(size: 12)).foregroundColor(Z.pair(fg)).lineLimit(1)
            .padding(.horizontal, 9).frame(height: 22)
            .background(Capsule().fill(Z.pair(bg)))
    }
}
