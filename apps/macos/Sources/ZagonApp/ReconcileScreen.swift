import AppKit
import SwiftUI
import ZagonUIModel

/// "What to log" over a period: totals, work by day and the reconciliation with Jira, by task or by day.
struct ReconcileScreen: View {
    @EnvironmentObject private var app: AppState
    @State private var filter: RecKind?
    @State private var byDay = false
    @State private var showMatch = false
    @State private var exporting = false
    /// The confirmation of "Log": the day's plan as just read, from that source.
    @State private var ask: Ask?

    struct Ask {
        var day: String
        var source: TaskBackend.Source
        var title: String?
        var detail: String
    }

    var body: some View {
        let f = app.f, z = app.zone, today = f.startOfDay(f.now)
        let period = app.worklogPeriod ?? today...today
        let from = TaskBackend.day(period.lowerBound, z), to = TaskBackend.day(period.upperBound, z)
        let cache = app.tasksNow
        let report = app.taskBackend == nil ? app.sampleReconcile : cache.reconciles[app.reconcileKey(from, to)]
        let vm = report.map { ReconcileVM($0, f) }
        Page(spacing: 18) {
            Header(vm?.title ?? f.t("worklog.title", f.dayRange(period.lowerBound, period.upperBound)),
                   prev: { shift(-1, period) }, next: { shift(1, period) }) { WorklogMode() }
            SourceBar { app.loadTasks(.reconcile(from, to), force: true) }
            PeriodCard(period: period, hint: vm?.hint ?? "", export: vm == nil ? nil : { exporting = true }) {
                app.loadTasks(.reconcile(from, to), force: true)
            }
            if let vm {
                content(vm)
            } else if cache.loading > 0 {
                Text(f.t("rec.loading")).font(.system(size: 13)).foregroundColor(Z.muted)
            }
            if let m = cache.message {
                Text(m).font(.system(size: 13)).foregroundColor(Z.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: "\(String(describing: app.currentTaskSource))|\(app.reconcileKey(from, to))") { app.loadTasks(.reconcile(from, to)) }
        // A plan read from another source must not be confirmed here.
        .onChange(of: app.currentTaskSource) { _ in ask = nil }
        // A write's outcome belongs to the period it was made in.
        .onChange(of: app.worklogPeriod) { _ in if let s = app.currentTaskSource { app.taskCache[s]?.message = nil } }
        .sheet(isPresented: $exporting) {
            if let vm { ReconcileExport(vm: vm, shown: $exporting).environmentObject(app) }
        }
        .confirmationDialog(ask?.title ?? f.t("worklog.nothing"),
                            isPresented: Binding(get: { ask != nil }, set: { if !$0 { ask = nil } }),
                            titleVisibility: .visible) {
            if let a = ask, a.title != nil, a.source == app.currentTaskSource {
                Button(f.t("worklog.commitYes")) { app.commitPlan(a.day) { app.loadTasks(.reconcile(from, to), force: true) } }
            }
            Button(f.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(ask?.detail ?? "")
        }
    }

    func shift(_ dir: Int, _ p: ClosedRange<Date>) {
        let r = RecPeriod.shift(p.lowerBound, p.upperBound, by: dir, app.f)
        app.worklogPeriod = r.from...r.to
        app.reconcileOpen = nil
    }

    /// "Log" on a day: that day's plan is read again; the confirmation shows exactly that plan, and the write goes as
    /// on the day screen (only while the plan is still the one shown).
    func log(_ d: ReconcileVM.DayLine) {
        app.reloadPlan(d.day) { s, plan in
            let c = ReconcileVM.confirmation(plan, key: d.jiraKey, app.f)
            ask = Ask(day: d.day, source: s, title: c.title, detail: c.detail)
        }
    }

    @ViewBuilder func content(_ vm: ReconcileVM) -> some View {
        if let c = vm.coverage { Banner.amber(c) }
        ForEach(vm.warnings, id: \.self) { Banner.blue(Emphasis(before: $0)) }
        StatsRow(stats: vm.stats, highlightLast: vm.connected)
        DayBars(vm: vm)
        table(vm)
    }

    func table(_ vm: ReconcileVM) -> some View {
        let f = app.f
        return Card(spacing: 10) {
            HStack(spacing: 12) {
                H2(text: f.t("rec.table"))
                Spacer(minLength: 0)
                Segmented(items: [f.t("rec.view.tasks"), f.t("rec.view.days")], selected: byDay ? 1 : 0) { byDay = $0 == 1 }
            }
            Flow(spacing: 6, lineSpacing: 6) {
                ForEach(vm.filters.indices, id: \.self) { i in
                    let it = vm.filters[i]
                    FilterChip(title: it.title, dot: it.kind.map(RecStyle.dot), selected: it.kind == filter) { filter = it.kind }
                }
            }
            if vm.empty {
                Text(f.t("rec.empty")).font(.system(size: 13)).foregroundColor(Z.secondary)
            } else if byDay {
                days(vm)
            } else {
                tasks(vm)
            }
            if !vm.notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(vm.notes, id: \.self) { Text($0).lineSpacing(3).fixedSize(horizontal: false, vertical: true) }
                }
                .font(.system(size: 13)).foregroundColor(Z.body)
                .padding(.vertical, 10).padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Z.inset))
            }
            Flow(spacing: 8, lineSpacing: 8) {
                PillButton(title: f.t("rec.export"), height: 38, radius: 10, fontSize: 14) { exporting = true }
                CopyButton(title: f.t("rec.copyMd"), height: 38, radius: 10, fontSize: 14) { vm.markdown() }
            }
            .padding(.top, 4)
        }
    }

    func tasks(_ vm: ReconcileVM) -> some View {
        let f = app.f
        return VStack(spacing: 0) {
            RecColumns(f.t("rec.col.task"), f.t("rec.col.title"), f.t("rec.col.sessions"), f.t("rec.col.jira"), f.t("rec.col.diff")) {
                Text(f.t("rec.col.mark"))
            }
            .font(.system(size: 12, weight: .medium)).foregroundColor(Z.muted)
            .padding(.vertical, 6).padding(.horizontal, 6)
            ForEach(vm.groups(filter)) { g in
                groupHead(g, vm)
                if g.kind == .match && !showMatch && filter != .match {
                    Button { showMatch = true } label: {
                        Text(f.t("rec.matchFolded", vm.tolerance)).font(.system(size: 12)).foregroundColor(Z.link)
                            .padding(.leading, 46).padding(.bottom, 8).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    ForEach(g.rows) { r in
                        let open = app.reconcileOpen == r.id
                        Button { app.reconcileOpen = open ? nil : r.id } label: { RecRow(row: r, open: open) }
                            .buttonStyle(.plain)
                        if open { DayDetail(lines: vm.days(r.id), log: log) }
                    }
                }
            }
            if filter == nil {
                // Not EmptyView: its frame goes with it, and the numbers slide a column right.
                RecColumns("", f.t("rec.total"), vm.total.sessions, vm.total.jira, vm.total.diff) { Color.clear.frame(height: 1) }
                    .font(mono(13, .semibold)).foregroundColor(Z.text)
                    .padding(.vertical, 10).padding(.horizontal, 6)
                    .overlay(alignment: .top) { Divider1(color: Z.border) }
            }
        }
    }

    func groupHead(_ g: ReconcileVM.Group, _ vm: ReconcileVM) -> some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 14, height: 1)
            HStack(spacing: 6) {
                Dot(color: RecStyle.dot(g.kind), size: 7)
                Text((g.title + " · " + vm.count(g)).uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.5)
                    .foregroundColor(g.kind == .zagonOnly || g.kind == .noTask ? Z.secondary : RecStyle.dot(g.kind)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                Text(g.sessions).frame(width: 92, alignment: .trailing)
                Text(g.jira).frame(width: 92, alignment: .trailing)
                Text(g.diff).frame(width: 92, alignment: .trailing)
            }
            .font(mono(12, .semibold)).foregroundColor(Z.secondary)
            Color.clear.frame(width: 120, height: 1)
        }
        .padding(.vertical, 9).padding(.horizontal, 6)
        .overlay(alignment: .top) { Divider1(color: Z.border) }
    }

    func days(_ vm: ReconcileVM) -> some View {
        VStack(spacing: 0) {
            ForEach(vm.dayGroups) { d in
                let rows = d.rows.filter { filter == nil || $0.kind == filter }
                if !rows.isEmpty {
                    Text(d.title).font(.system(size: 12, weight: .semibold)).foregroundColor(Z.secondary)
                        .padding(.vertical, 8).padding(.horizontal, 6).frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .top) { Divider1(color: Z.border) }
                    ForEach(rows) { RecRow(row: $0, open: nil) }
                }
            }
        }
    }
}

// MARK: - pieces

enum RecStyle {
    static func chip(_ k: RecKind) -> (bg: UInt32, fg: UInt32) {
        switch k {
        case .onlySessions: (0x3A2E1D, 0xF5B342)
        case .mismatch: (0x3D2423, 0xFF8C80)
        case .onlyJira: (0x2E2640, 0xC3A6FF)
        case .match: (0x1E3A33, 0x5FD9B8)
        case .zagonOnly, .noTask: (0x2A2A2E, 0xA9A9B0)
        }
    }

    static func dot(_ k: RecKind) -> Color {
        switch k {
        case .onlySessions: Color(hex: Palette.fiveHour)
        case .mismatch: Z.bad
        case .onlyJira: Color(hex: Palette.violet)
        case .match: Z.good
        case .zagonOnly, .noTask: Z.secondary
        }
    }
}

struct RecChip: View {
    let kind: RecKind
    var small = false
    @EnvironmentObject private var app: AppState
    var body: some View {
        let c = RecStyle.chip(kind)
        Text(app.f.t("rec.k." + kind.rawValue)).font(.system(size: small ? 11 : 12)).foregroundColor(Color(hex: c.fg)).lineLimit(1)
            .padding(.horizontal, small ? 8 : 9).frame(height: small ? 20 : 22)
            .background(Capsule().fill(Color(hex: c.bg)))
    }
}

/// A filter chip with the group's dot.
struct FilterChip: View {
    let title: String
    let dot: Color?
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let dot { Dot(color: dot, size: 7) }
                Text(title).font(.system(size: 12)).foregroundColor(selected ? Z.text : Z.body)
            }
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(selected ? Z.selection : Color.clear))
            .overlay(Capsule().strokeBorder(selected ? Color.clear : Z.control))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The table's columns: chevron, key, title, sessions, Jira, difference, mark.
struct RecColumns<Mark: View>: View {
    let key, title, sessions, jira, diff: String
    let mark: Mark
    init(_ key: String, _ title: String, _ sessions: String, _ jira: String, _ diff: String, @ViewBuilder mark: () -> Mark) {
        self.key = key; self.title = title; self.sessions = sessions; self.jira = jira; self.diff = diff; self.mark = mark()
    }
    var body: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 14, height: 1)
            Text(key).frame(width: 84, alignment: .leading)
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            Text(sessions).frame(width: 92, alignment: .trailing)
            Text(jira).frame(width: 92, alignment: .trailing)
            Text(diff).frame(width: 92, alignment: .trailing)
            mark.frame(width: 120, alignment: .leading)
        }
    }
}

/// A task (or an issue, or work with no task) over the period; `open` nil: not expandable (the by-day view).
struct RecRow: View {
    let row: ReconcileVM.Row
    let open: Bool?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Group {
                if let open {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundColor(open ? Z.secondary : Z.muted)
                } else { Color.clear.frame(height: 1) }
            }
            .frame(width: 14)
            Text(row.key).font(code(13)).foregroundColor(Z.link).frame(width: 84, alignment: .leading)
            Text(row.title).font(.system(size: 13)).foregroundColor(row.kind == .noTask ? Z.body : Z.text).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.sessions).font(mono(13)).foregroundColor(row.sessions == "—" ? Z.faint : Z.text).frame(width: 92, alignment: .trailing)
            Text(row.jira).font(mono(13)).foregroundColor(row.jira == "—" ? Z.faint : Z.text).frame(width: 92, alignment: .trailing)
            Text(row.diff ?? "—").font(mono(13, .medium)).foregroundColor(diffColor).frame(width: 92, alignment: .trailing)
            RecChip(kind: row.kind).frame(width: 120, alignment: .leading)
        }
        .padding(.vertical, 10).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(open == true ? Color(hex: 0x1C2230) : Color.clear))
        .contentShape(Rectangle())
        .overlay(alignment: .top) { Divider1(color: Z.border) }
    }

    var diffColor: Color {
        guard row.diff != nil else { return Z.faint }
        return row.sign > 0 ? Color(hex: Palette.fiveHour) : row.sign < 0 ? Color(hex: Palette.violet) : Z.secondary
    }
}

/// An open row: the task day by day, with "Log" / "Add" where time is missing in Jira.
struct DayDetail: View {
    let lines: [ReconcileVM.DayLine]
    let log: (ReconcileVM.DayLine) -> Void
    @EnvironmentObject private var app: AppState

    var body: some View {
        let f = app.f
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(f.t("rec.d.day")).frame(width: 110, alignment: .leading)
                Text(f.t("rec.d.what")).frame(maxWidth: .infinity, alignment: .leading)
                Text(f.t("rec.d.sessions")).frame(width: 80, alignment: .trailing)
                Text(f.t("rec.d.worklogs")).frame(width: 230, alignment: .leading)
                Color.clear.frame(width: 160, height: 1)
            }
            .font(.system(size: 12, weight: .medium)).foregroundColor(Z.muted)
            .padding(.vertical, 8)
            ForEach(lines) { line($0) }
        }
        .padding(.horizontal, 12).padding(.bottom, 4)
        .background(RoundedRectangle(cornerRadius: 10).fill(Z.inset))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Z.laneBorder))
        .padding(.leading, 26).padding(.vertical, 6)
    }

    func line(_ d: ReconcileVM.DayLine) -> some View {
        let f = app.f
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(d.title).font(.system(size: 13, weight: .semibold)).foregroundColor(Z.text)
                RecChip(kind: d.kind, small: true)
            }
            .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(d.sessions.indices, id: \.self) { i in
                    let s = d.sessions[i]
                    (Text(s.title).font(.system(size: 13, weight: .medium)).foregroundColor(Z.text)
                        + Text("  " + s.time).font(.system(size: 12)).foregroundColor(Z.secondary))
                        .lineLimit(1)
                    if !s.meta.isEmpty { Text(s.meta).font(.system(size: 12)).foregroundColor(Z.muted).lineLimit(1) }
                }
                if d.sessions.isEmpty {
                    Text(f.t("rec.d.noSessions")).font(.system(size: 12.5)).foregroundColor(Color(hex: Palette.violet))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let done = d.done, !d.sessions.isEmpty {
                    Text(done).font(.system(size: 12.5)).foregroundColor(Z.body).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(d.sessionTime).font(mono(13)).foregroundColor(d.sessionTime == "—" ? Z.faint : Z.text).frame(width: 80, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                if d.worklogs.isEmpty { Text(f.t("rec.d.noLogs")).font(.system(size: 13)).foregroundColor(Z.faint) }
                ForEach(d.worklogs.indices, id: \.self) { i in
                    Text(d.worklogs[i].span).font(mono(13)).foregroundColor(Z.text)
                    if !d.worklogs[i].comment.isEmpty {
                        Text(d.worklogs[i].comment).font(.system(size: 12)).foregroundColor(Z.muted).lineLimit(2)
                    }
                }
            }
            .frame(width: 230, alignment: .leading)
            Group {
                if let a = d.action {
                    PillButton(title: a, primary: d.primary, height: 28, radius: 8, fontSize: 12) { log(d) }
                } else { Color.clear.frame(height: 1) }
            }
            .frame(width: 160, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Divider1(color: Z.border) }
    }
}

/// Quick periods, the two dates, and what was counted.
struct PeriodCard: View {
    let period: ClosedRange<Date>
    let hint: String
    let export: (() -> Void)?
    let reload: () -> Void
    @EnvironmentObject private var app: AppState

    var body: some View {
        let f = app.f
        let quick = RecPeriod.allCases.first { let r = $0.range(f); return r.from == period.lowerBound && r.to == period.upperBound }
        Card(spacing: 12) {
            Flow(spacing: 6, lineSpacing: 6) {
                ForEach(RecPeriod.allCases, id: \.self) { p in
                    Chip(title: f.t("rec.q." + p.rawValue), selected: p == quick) {
                        let r = p.range(f)
                        app.worklogPeriod = r.from...r.to
                    }
                }
                Chip(title: f.t("rec.q.custom"), selected: quick == nil) {}
            }
            HStack(spacing: 10) {
                Text(f.t("rec.from")).font(.system(size: 13)).foregroundColor(Z.body)
                DateBox(date: period.lowerBound) { d in app.worklogPeriod = d...max(d, period.upperBound) }
                Text(f.t("rec.to")).font(.system(size: 13)).foregroundColor(Z.body)
                DateBox(date: period.upperBound) { d in app.worklogPeriod = min(d, period.lowerBound)...d }
                Spacer(minLength: 0)
                if let export { PillButton(title: f.t("rec.export"), action: export) }
                PillButton(title: f.t("rec.reload"), action: reload)
            }
            if !hint.isEmpty {
                Text(hint).font(.system(size: 12)).foregroundColor(Z.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A day in the app's zone; plain text in snapshots (the AppKit picker draws as a placeholder there).
struct DateBox: View {
    let date: Date
    let set: (Date) -> Void
    @EnvironmentObject private var app: AppState
    @Environment(\.isSnapshot) private var snapshot

    var body: some View {
        if snapshot {
            Text(Self.text(date, app.zone)).font(.system(size: 13)).foregroundColor(Z.text)
                .padding(.horizontal, 10).frame(width: 120, height: 30, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Z.sidebar))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Z.control))
        } else {
            DatePicker("", selection: Binding(get: { date }, set: { set(app.f.startOfDay($0)) }), displayedComponents: .date)
                .labelsHidden()
                .environment(\.timeZone, app.zone)
                .fixedSize()
        }
    }

    static func text(_ d: Date, _ zone: TimeZone) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "dd.MM.yyyy"
        fmt.timeZone = zone
        return fmt.string(from: d)
    }
}

/// Hours per day of the period: hatched = in Jira, amber = not logged, violet outline = Jira beyond the sessions, grey
/// = Jira before the session history; days not come yet stay empty.
struct DayBars: View {
    let vm: ReconcileVM
    @EnvironmentObject private var app: AppState

    var body: some View {
        let f = app.f, n = CGFloat(max(vm.bars.count, 1))
        let top = max(8, vm.bars.map { max($0.sessionH, $0.jiraH) }.max() ?? 8)
        Card(spacing: 10) {
            HStack(spacing: 14) {
                H2(text: f.t("rec.byDay"))
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Hatch().frame(width: 14, height: 8).clipShape(RoundedRectangle(cornerRadius: 3))
                    Text(f.t("rec.lg.jira"))
                }
                .font(.system(size: 12)).foregroundColor(Z.secondary)
                Legend(color: Color(hex: Palette.fiveHour), label: f.t("rec.lg.unlogged"))
                if vm.connected {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(Color(hex: Palette.violet), lineWidth: 1.2).frame(width: 14, height: 8)
                        Text(f.t("rec.lg.over"))
                    }
                    .font(.system(size: 12)).foregroundColor(Z.secondary)
                }
                if vm.coverageIndex != nil { Legend(color: Color(hex: 0x3A3A40), label: f.t("rec.lg.before")) }
            }
            GeometryReader { g in
                let slot = g.size.width / n
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in draw(ctx, size, slot, top) }
                    if let c = vm.coverageIndex, CGFloat(c) * slot > 160 {
                        Text(f.t("rec.chart.before")).font(.system(size: 11)).foregroundColor(Z.muted)
                            .position(x: CGFloat(c) * slot / 2, y: 12)
                    }
                    if let t = vm.todayIndex {
                        let x = CGFloat(t + 1) * slot
                        if g.size.width - x > 140 {
                            Text(f.t("rec.chart.future")).font(.system(size: 12)).foregroundColor(Z.faint)
                                .position(x: (x + g.size.width) / 2, y: g.size.height / 2)
                        }
                    }
                }
            }
            .frame(height: 124)
            .background(RoundedRectangle(cornerRadius: 8).fill(Z.inset))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Z.laneBorder))
            GeometryReader { g in
                let slot = g.size.width / n
                let ticks = vm.ticks(slot: Double(slot))
                ZStack(alignment: .topLeading) {
                    ForEach(ticks.indices, id: \.self) { i in
                        Text(ticks[i].label).font(mono(11)).foregroundColor(Z.muted).fixedSize()
                            .offset(x: CGFloat(ticks[i].index) * slot)
                    }
                }
            }
            .frame(height: 14)
        }
    }

    func draw(_ ctx: GraphicsContext, _ size: CGSize, _ slot: CGFloat, _ top: Double) {
        let h = size.height - 16, base = size.height - 4, w = max(1, slot - 3)
        func y(_ v: Double) -> CGFloat { CGFloat(v / top) * h }
        for (i, b) in vm.bars.enumerated() where b.kind != .future {
            let x = CGFloat(i) * slot + 1.5
            if b.kind == .before {
                if b.jiraH > 0 {
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: base - y(b.jiraH), width: w, height: y(b.jiraH)), cornerRadius: 2),
                             with: .color(Color(hex: 0x3A3A40)))
                }
                continue
            }
            let s = y(b.sessionH), logged = y(min(b.sessionH, b.jiraH))
            if s > 0 {
                ctx.fill(Path(roundedRect: CGRect(x: x, y: base - s, width: w, height: s), cornerRadius: 2), with: .color(Color(hex: Palette.fiveHour)))
            }
            if logged > 0 { hatch(ctx, CGRect(x: x, y: base - logged, width: w, height: logged)) }
            if b.jiraH > b.sessionH + 0.25 {
                let j = y(b.jiraH)
                ctx.stroke(Path(roundedRect: CGRect(x: x - 0.5, y: base - j, width: w + 1, height: j - s), cornerRadius: 2),
                           with: .color(Color(hex: Palette.violet)), lineWidth: 1.2)
            }
        }
        for i in [vm.coverageIndex, vm.todayIndex.map { $0 + 1 }].compactMap({ $0 }) where i < vm.bars.count {
            var p = Path()
            p.move(to: CGPoint(x: CGFloat(i) * slot, y: 0))
            p.addLine(to: CGPoint(x: CGFloat(i) * slot, y: size.height))
            ctx.stroke(p, with: .color(Z.faint), lineWidth: 1)
        }
    }

    /// `Hatch` inside one bar.
    func hatch(_ ctx: GraphicsContext, _ r: CGRect) {
        var c = ctx
        let shape = Path(roundedRect: r, cornerRadius: 2)
        c.clip(to: shape)
        c.fill(shape, with: .color(Color(hex: 0x2E2E33)))
        var lines = Path(), x = r.minX - r.height
        while x < r.maxX {
            lines.move(to: CGPoint(x: x, y: r.maxY))
            lines.addLine(to: CGPoint(x: x + r.height, y: r.minY))
            x += 8.5
        }
        c.stroke(lines, with: .color(Color(hex: 0x4A4A52)), lineWidth: 3)
    }
}

/// Export sheet: Markdown (with its sections) or CSV, copied or saved.
struct ReconcileExport: View {
    let vm: ReconcileVM
    @Binding var shown: Bool
    @EnvironmentObject private var app: AppState
    @State private var csv = false
    @State private var sections = ReconcileVM.Sections()

    var body: some View {
        let f = app.f, text = csv ? vm.csv() : vm.markdown(sections), name = vm.fileName(csv: csv)
        VStack(alignment: .leading, spacing: 14) {
            Text(f.t("rec.x.title")).font(.system(size: 18, weight: .bold)).foregroundColor(Z.text)
            HStack(spacing: 16) {
                Segmented(items: ["Markdown", "CSV"], selected: csv ? 1 : 0, height: 28, fontSize: 13) { csv = $0 == 1 }
                if csv {
                    Text(f.t("rec.x.csvNote")).font(.system(size: 12)).foregroundColor(Z.muted)
                } else {
                    Toggle(f.t("rec.x.totals"), isOn: $sections.totals)
                    Toggle(f.t("rec.x.tasks"), isOn: $sections.tasks)
                    Toggle(f.t("rec.x.days"), isOn: $sections.days)
                }
            }
            .toggleStyle(.checkbox).font(.system(size: 13))
            ScrollView {
                Text(text).font(code(11.5)).foregroundColor(Z.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
            .frame(height: 420)
            .background(RoundedRectangle(cornerRadius: 10).fill(Z.inset))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Z.laneBorder))
            HStack(spacing: 8) {
                Text(name).font(.system(size: 12)).foregroundColor(Z.muted).lineLimit(1)
                Spacer(minLength: 0)
                PillButton(title: f.t("rec.x.close")) { shown = false }
                CopyButton(title: f.t("copy")) { text }
                PillButton(title: f.t("rec.x.save"), primary: true) { save(text, name) }
            }
        }
        .padding(24)
        .frame(width: 780)
        .background(Z.popover)
    }

    func save(_ text: String, _ name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            app.toast = Toast(text: app.f.t("rec.x.saved", url.lastPathComponent))
        } catch { NSAlert(error: error).runModal() }
    }
}
