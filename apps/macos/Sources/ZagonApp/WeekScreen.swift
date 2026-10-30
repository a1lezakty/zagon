import SwiftUI
import ZagonUIModel

struct WeekScreen: View {
    @EnvironmentObject private var app: AppState
    /// Any day of the shown week; nil = this week.
    @State private var anchor: Date?
    @State private var metric: WeekMetric = .hours

    var body: some View {
        let f = app.f
        let at = anchor ?? f.now
        let vm = WeekVM(app.provider.week(containing: at), weekLimit: app.provider.limits().week, f)
        let metrics = WeekMetric.allCases
        Page {
            Header(vm.title, prev: { anchor = f.addDays(-7, to: at) }, next: { anchor = f.addDays(7, to: at) }) {
                Segmented(items: metrics.map(vm.metricTitle), selected: metrics.firstIndex(of: metric) ?? 0, height: 30,
                          fontSize: 13) { metric = metrics[$0] }
            }
            StatsRow(stats: vm.stats)
            ZoneApprox(at: at)
            Card {
                HStack(spacing: 14) {
                    H2(text: vm.chartTitle(metric))
                    Spacer(minLength: 0)
                    ForEach(vm.legend.indices, id: \.self) { i in
                        Legend(color: Color(hex: vm.legend[i].color), label: vm.legend[i].name, width: 10, height: 10)
                    }
                }
                WeekBars(days: vm.days(metric))
            }
            HStack(alignment: .top, spacing: 16) {
                limit(vm)
                projects(vm)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        // A date kept from the old zone may fall into the next or the previous week.
        .onChange(of: app.zoneShown) { _ in anchor = nil }
    }

    func limit(_ vm: WeekVM) -> some View {
        Card(spacing: 12, stretch: true) {
            H2(text: app.f.t("week.limit"))
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(vm.limit.indices, id: \.self) { i in
                    let l = vm.limit[i]
                    VStack(spacing: 6) {
                        Spacer(minLength: 0)
                        Text(l.text).font(mono(11)).foregroundColor(Z.secondary)
                        RoundedRectangle(cornerRadius: l.pct == nil ? 2 : 4)
                            .fill(l.pct == nil ? Z.barTrack : Z.week)
                            .frame(height: max(2, CGFloat(l.pct ?? 0) * 0.8))
                        Text(l.day).font(.system(size: 11)).foregroundColor(Z.muted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 120)
            if let fc = vm.limitForecast { Banner.blue(fc) }
        }
    }

    func projects(_ vm: WeekVM) -> some View {
        let f = app.f
        return Card(spacing: 10, stretch: true) {
            H2(text: f.t("week.projects"))
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(f.t("week.col.project")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(f.t("week.col.hours")).frame(width: 84, alignment: .trailing)
                    Text(f.t("week.col.cost")).frame(width: 64, alignment: .trailing)
                    Text(f.t("week.col.delta")).frame(width: 84, alignment: .trailing)
                }
                .font(.system(size: 12, weight: .medium)).foregroundColor(Z.muted)
                .padding(.vertical, 6).padding(.horizontal, 4)
                ForEach(vm.projects.indices, id: \.self) { i in
                    let p = vm.projects[i]
                    HStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Dot(color: Color(hex: p.color))
                            Text(p.name).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(p.hours).font(mono(13)).frame(width: 84, alignment: .trailing)
                        Text(p.cost).font(mono(13)).frame(width: 64, alignment: .trailing)
                        Text(p.delta).font(mono(13)).foregroundColor(p.good ? Z.good : Z.bad).frame(width: 84, alignment: .trailing)
                    }
                    .font(.system(size: 13)).foregroundColor(Z.text)
                    .padding(.vertical, 9).padding(.horizontal, 4)
                    .overlay(alignment: .top) { Divider1(color: Z.border) }
                }
            }
        }
    }
}

/// Stacked bars per day, scaled to the busiest day; today has a dashed outline.
struct WeekBars: View {
    let days: [WeekDayVM]
    var body: some View {
        let top = max(days.map(\.value).max() ?? 0, 1e-9)
        HStack(alignment: .bottom, spacing: 14) {
            ForEach(days.indices, id: \.self) { i in
                let d = days[i]
                let h = CGFloat(d.value / top) * 220
                VStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Text(d.total).font(mono(12)).foregroundColor(Z.body).lineLimit(1)
                    VStack(spacing: 0) {
                        ForEach(d.parts.indices.reversed(), id: \.self) { j in
                            Rectangle().fill(Color(hex: d.parts[j].color)).frame(height: h * CGFloat(d.parts[j].value / d.value))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: max(2, h), alignment: .bottom)
                    .background(Z.barTrack)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        if d.isToday {
                            RoundedRectangle(cornerRadius: 8).stroke(Z.week, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .padding(-3.5)
                        }
                    }
                    Text(d.label).font(.system(size: 12, weight: d.isToday ? .semibold : .regular))
                        .foregroundColor(d.isToday ? Z.text : Z.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 290)
        .padding(.top, 10)
    }
}
