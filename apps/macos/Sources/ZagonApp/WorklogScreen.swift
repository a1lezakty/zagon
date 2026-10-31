import SwiftUI
import ZagonUIModel

struct WorklogScreen: View {
    @EnvironmentObject private var app: AppState
    /// nil = today
    @State private var day: Date?
    @State private var confirm = false

    var body: some View {
        let f = app.f
        let d = day ?? f.now
        let key = TaskBackend.day(d, app.zone), cache = app.tasksNow
        let data = app.taskBackend == nil ? app.provider.worklog(d)
            : cache.plans[key]?.worklog(f)
                ?? WorklogData(day: f.startOfDay(d), workStart: nil, workEnd: nil, userSec: 0, sessionSec: 0, rows: [], splits: [])
        let vm = WorklogVM(data, f)
        Page(spacing: 18) {
            Header(vm.title, prev: { day = f.addDays(-1, to: d) }, next: { day = f.addDays(1, to: d) })
            SourceBar { app.loadTasks(.plan(key), force: true) }
            StatsRow(stats: vm.stats, highlightLast: true)
            if vm.rows.isEmpty {
                Card { Text(f.t("worklog.empty")).font(.system(size: 13)).foregroundColor(Z.secondary) }
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
                    H2(text: f.t("worklog.plan"))
                    table(vm.rows)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(vm.notes.indices, id: \.self) { i in
                            Text(vm.notes[i]).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.system(size: 13)).foregroundColor(Z.body)
                    .padding(.vertical, 10).padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Z.inset))
                    Flow(spacing: 8, lineSpacing: 8) {
                        if let commit = vm.commitTitle {
                            PillButton(title: commit, primary: true, height: 38, radius: 10, fontSize: 14) {
                                if app.taskBackend != nil, cache.loading == 0 { confirm = true }
                            }
                            .confirmationDialog(commit + "?", isPresented: $confirm) {
                                Button(f.t("worklog.commitYes")) { app.commitPlan(key) }
                                Button(f.t("common.cancel"), role: .cancel) {}
                            } message: {
                                Text(f.t("worklog.commitDetail"))
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
        .task(id: "\(String(describing: app.currentTaskSource))|\(key)") { app.loadTasks(.plan(key)) }
        .onChange(of: app.zoneShown) { _ in day = nil }
    }

    func bar(_ segments: [WorklogSegmentVM]) -> some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                ForEach(segments.indices, id: \.self) { i in
                    let s = segments[i]
                    ZStack(alignment: .leading) {
                        if s.logged { Hatch() } else { Color(hex: s.color) }
                        Text(s.label).font(.system(size: 11, weight: .semibold)).foregroundColor(Z.onAccent).lineLimit(1)
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

    func table(_ rows: [WorklogRowVM]) -> some View {
        let f = app.f
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(f.t("worklog.col.task")).frame(width: 84, alignment: .leading)
                Text(f.t("worklog.col.span")).frame(width: 104, alignment: .leading)
                Text(f.t("worklog.col.time")).frame(width: 72, alignment: .trailing)
                Text(f.t("worklog.col.text")).frame(maxWidth: .infinity, alignment: .leading)
                Text(f.t("worklog.col.dest")).frame(width: 120, alignment: .leading)
            }
            .font(.system(size: 12, weight: .medium)).foregroundColor(Z.muted)
            .padding(.vertical, 6).padding(.horizontal, 6)
            ForEach(rows.indices, id: \.self) { i in
                let r = rows[i]
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(r.key).font(code(13)).foregroundColor(Z.link).frame(width: 84, alignment: .leading)
                    Text(r.span).font(mono(13)).frame(width: 104, alignment: .leading)
                    Text(r.time).font(mono(13)).frame(width: 72, alignment: .trailing)
                    Text(r.text).font(.system(size: 13)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    DestChip(text: r.destination, kind: r.kind).frame(width: 120, alignment: .leading)
                }
                .foregroundColor(r.kind == .alreadyLogged ? Z.muted : Z.text)
                .padding(.vertical, 10).padding(.horizontal, 6)
                .overlay(alignment: .top) { Divider1(color: Z.border) }
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
        Text(text).font(.system(size: 12)).foregroundColor(Color(hex: fg)).lineLimit(1)
            .padding(.horizontal, 9).frame(height: 22)
            .background(Capsule().fill(Color(hex: bg)))
    }
}
