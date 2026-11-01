import AppKit
import SwiftUI
import ZagonUIModel

struct DayScreen: View {
    @EnvironmentObject private var app: AppState
    @State private var dim: UsageDimension = .project

    var body: some View {
        let f = app.f
        let vm = DayVM(dayData, f)
        Page {
            Header(vm.title, prev: { app.day = f.addDays(-1, to: app.day) }, next: { app.day = f.addDays(1, to: app.day) }) {
                PillButton(title: f.t("today"), height: 32, radius: 8) { app.day = f.startOfDay(f.now) }
                PillButton(title: f.t("day.export"), primary: true, height: 32, radius: 8) { export(vm) }
            }
            StatsRow(stats: vm.stats)
            if !vm.limitNotes.isEmpty { NotesStrip(notes: vm.limitNotes) }
            ZoneApprox(at: app.day)
            if vm.isEmpty || vm.timeline.lanes.isEmpty {
                Card {
                    Text(f.t(vm.isEmpty ? "day.empty" : "day.noDetail")).font(.system(size: 13)).foregroundColor(Z.secondary)
                }
            } else {
                Timeline(vm: vm.timeline)
                HStack(alignment: .top, spacing: 16) {
                    usage(vm)
                    done(vm)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func usage(_ vm: DayVM) -> some View {
        let rows = vm.usage(dim)
        return Card(stretch: true) {
            H2(text: app.f.t("day.usage"))
            Flow(spacing: 6) {
                ForEach(UsageDimension.allCases, id: \.self) { d in
                    Chip(title: vm.dimensionTitle(d), selected: d == dim) { dim = d }
                }
            }
            ForEach(rows.indices, id: \.self) { i in
                let r = rows[i]
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(r.name).font(.system(size: 13)).foregroundColor(Z.text).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(r.tokens).font(mono(13)).foregroundColor(Z.secondary)
                        Text(r.cost).font(mono(13)).foregroundColor(Z.text).frame(width: 52, alignment: .trailing)
                    }
                    Bar(fraction: r.share, color: Color(hex: r.color))
                }
            }
            Text(app.f.t("day.apiNote")).font(.system(size: 12)).foregroundColor(Z.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The day as the store has it, with the summary the CLI just answered when the pull has not brought it yet (one
    /// without cards says nothing: the Mac's own list stays, as `SummaryJob.newest`).
    var dayData: DayData {
        var d = app.provider.day(app.day)
        if let r = app.summaryJob(dayKey).result, !r.doc.items.isEmpty, r.at > d.summaryInfo?.at ?? .distantPast {
            d.doc = r.doc
            d.summaryInfo = SummaryInfo(engine: r.engine, at: r.at, weekPct: nil, sources: (r.doc.hosts ?? []).map(app.provider.hostName))
        }
        return d
    }

    var dayKey: String { StoreDataProvider.day(app.day, app.zone) }

    func done(_ vm: DayVM) -> some View {
        let f = app.f
        return Card(spacing: 12, stretch: true) {
            HStack(alignment: .top, spacing: 10) {
                H2(text: f.t("day.done"))
                Spacer(minLength: 0)
                // Days that have not come yet have nothing to sum up.
                if dayKey <= StoreDataProvider.day(f.now, app.zone) { SummaryButton(from: dayKey, to: dayKey, has: vm.hasSummary) }
            }
            if let s = vm.summary {
                SummaryCards(vm: s, note: false).id(dayKey)
                if let n = vm.leftOutNote {
                    Text(n).font(.system(size: 12)).foregroundColor(Z.muted).fixedSize(horizontal: false, vertical: true)
                    projects(vm.leftOut)
                }
            } else {
                Text(f.t("sum.fallback")).font(.system(size: 12)).foregroundColor(Z.muted)
                projects(vm.projects)
            }
            if let w = vm.longestWait {
                Text(w).font(.system(size: 13)).foregroundColor(Z.alarmInk).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 10).padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Z.alarmFill))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Z.alarmBorder))
                    .padding(.top, 4)
            }
            if let n = vm.summaryNote {
                Text(n).font(.system(size: 12)).foregroundColor(Z.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The day's projects without a written summary: sessions with their time and branch.
    func projects(_ ps: [DoneProjectVM]) -> some View {
        ForEach(ps.indices, id: \.self) { i in
            let p = ps[i]
            HStack(alignment: .top, spacing: 10) {
                Dot(color: Color(hex: p.color)).padding(.top, 6)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(p.name).font(.system(size: 13, weight: .semibold)).foregroundColor(Z.text)
                        Spacer(minLength: 0)
                        Text(p.numbers).font(mono(12)).foregroundColor(Z.secondary)
                    }
                    ForEach(p.sessions.indices, id: \.self) { j in
                        Text(p.sessions[j]).font(.system(size: 13)).foregroundColor(Z.body).lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    func export(_ vm: DayVM) {
        let panel = NSSavePanel()
        let c = app.f.calendar.dateComponents([.year, .month, .day], from: app.day)
        panel.nameFieldStringValue = String(format: "zagon-%04d-%02d-%02d.md", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try vm.markdown.write(to: url, atomically: true, encoding: .utf8) } catch { NSAlert(error: error).runModal() }
    }
}

/// "5-hour limit hit … · week over the day …"
struct NotesStrip: View {
    let notes: [Note]
    var body: some View {
        Flow(spacing: 10, lineSpacing: 8) {
            ForEach(notes.indices, id: \.self) { i in
                if i > 0 { Text("·").foregroundColor(Z.faint) }
                HStack(spacing: 6) {
                    Dot(color: Color(hex: notes[i].color))
                    Text(notes[i].text)
                }
            }
        }
        .font(.system(size: 13)).foregroundColor(Z.body)
        .padding(.vertical, 12).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Z.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Z.border))
    }
}

struct Timeline: View {
    let vm: TimelineVM
    @EnvironmentObject private var app: AppState
    var body: some View {
        Card {
            HStack(spacing: 14) {
                H2(text: app.f.t("day.timeline"))
                Spacer(minLength: 0)
                Legend(color: Z.working, label: app.f.t("day.worked"))
                Legend(color: Z.waiting, label: app.f.t("day.waited"))
            }
            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: 210, height: 1)
                    Ticks(labels: vm.ticks)
                }
                ForEach(vm.lanes.indices, id: \.self) { i in lane(vm.lanes[i]) }
            }
        }
    }

    func lane(_ l: LaneVM) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(l.title).font(.system(size: 13, weight: .medium)).foregroundColor(Z.text).lineLimit(1)
                Text(l.host).font(.system(size: 11)).foregroundColor(Z.muted).lineLimit(1)
            }
            .padding(.trailing, 12)
            .frame(width: 210, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .topLeading) {
                    ForEach(l.segments.indices, id: \.self) { j in
                        let s = l.segments[j]
                        RoundedRectangle(cornerRadius: 4).fill(s.waiting ? Z.waiting : Z.working)
                            .frame(width: max(2, s.width * g.size.width), height: max(0, g.size.height - 6))
                            .offset(x: s.x * g.size.width, y: 3)
                    }
                }
            }
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(Z.inset))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Z.laneBorder))
        }
    }
}
