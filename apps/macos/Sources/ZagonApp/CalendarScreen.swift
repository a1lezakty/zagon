import SwiftUI
import ZagonUIModel

struct CalendarScreen: View {
    @EnvironmentObject private var app: AppState
    /// Any day of the shown month; nil = the month of the selected day.
    @State private var anchor: Date?
    @State private var selected: Date?
    @State private var query: String?
    /// Hits of the last search that finished (searched off the main thread, 250 ms after the typing stops).
    @State private var found: [SearchHit] = []
    /// A range chosen for its summary (keys); nil = the shown month's.
    @State private var range: [String]?
    @State private var picking = false
    @Environment(\.isSnapshot) private var snapshot

    var body: some View {
        let f = app.f
        let sel = selected ?? app.day
        let at = anchor ?? sel
        let vm = CalendarVM(app.provider.month(containing: at), selected: sel, f)
        Page {
            Header(vm.title, prev: { anchor = f.addMonths(-1, to: f.startOfMonth(at)) },
                   next: { anchor = f.addMonths(1, to: f.startOfMonth(at)) }) {
                HStack(spacing: 6) {
                    Text(f.t("cal.less"))
                    ForEach(Palette.heat.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 4).fill(Color(hex: Palette.heat[i])).frame(width: 14, height: 14)
                    }
                    Text(f.t("cal.more"))
                }
                .font(.system(size: 12)).foregroundColor(Z.muted)
            }
            HStack(alignment: .top, spacing: 16) {
                grid(vm)
                dayCard(CalendarVM.card(app.provider.day(sel), f), sel).frame(width: 320)
            }
            summary(at)
            ZoneApprox(at: sel)
            search
        }
        .onChange(of: app.zoneShown) { _ in anchor = nil; selected = nil; range = nil }
        .sheet(isPresented: $picking) {
            RangeSheet(shown: $picking) { a, b in range = [StoreDataProvider.day(a, app.zone), StoreDataProvider.day(b, app.zone)] }
                .environmentObject(app)
        }
    }

    /// The month's summary, or the chosen range's.
    func summary(_ at: Date) -> some View {
        let f = app.f, z = app.zone, first = f.startOfMonth(at)
        let r = range ?? [StoreDataProvider.day(first, z), StoreDataProvider.day(f.addDays(-1, to: f.addMonths(1, to: first)), z)]
        let title = range == nil ? f.t("sum.month")
            : f.t("sum.range", f.dayRange(StoreDataProvider.start(r[0], z), StoreDataProvider.start(r[1], z)))
        return PeriodSummaryCard(title: title, from: r[0], to: r[1]) {
            if range != nil { PillButton(title: f.t("sum.back"), height: 30, radius: 8, fontSize: 12) { range = nil } }
            PillButton(title: f.t("sum.period"), height: 30, radius: 8, fontSize: 12) { picking = true }
        }
    }

    func grid(_ vm: CalendarVM) -> some View {
        Card(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(vm.weekdays.indices, id: \.self) { i in
                    Text(vm.weekdays[i]).frame(maxWidth: .infinity)
                }
            }
            .font(.system(size: 12)).foregroundColor(Z.muted)
            VStack(spacing: 6) {
                ForEach(0..<vm.cells.count / 7, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(0..<7, id: \.self) { col in
                            if let c = vm.cells[row * 7 + col] {
                                cell(c)
                            } else {
                                Color.clear.frame(maxWidth: .infinity).frame(height: 66)
                            }
                        }
                    }
                }
            }
            Flow(spacing: 16, lineSpacing: 8) {
                ForEach(vm.footer.indices, id: \.self) { Text(vm.footer[$0]) }
            }
            .font(.system(size: 12)).foregroundColor(Z.secondary)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Divider1(color: Z.border) }
        }
    }

    func cell(_ c: CalendarCellVM) -> some View {
        Button { selected = c.date } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(c.day)").font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
                Text(c.hours).font(mono(11)).opacity(0.85)
            }
            .padding(.vertical, 7).padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 66)
            .foregroundColor(c.level >= 4 ? Z.onAccent : c.future ? Z.faint : Z.text)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: Palette.heat[c.level])))
            .overlay {
                if c.selected {
                    RoundedRectangle(cornerRadius: 9).strokeBorder(Z.text, lineWidth: 2)
                } else if c.today {
                    RoundedRectangle(cornerRadius: 9).strokeBorder(Z.week, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func dayCard(_ card: DayCardVM, _ day: Date) -> some View {
        let f = app.f
        return Card(border: Z.focus, spacing: 12) {
            Caps(text: f.t("cal.selected"), color: Z.link)
            Text(card.title).font(.system(size: 20, weight: .bold)).foregroundColor(Z.text)
            HStack(alignment: .top, spacing: 8) {
                ForEach(card.stats.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.stats[i].value).font(mono(16, .semibold)).foregroundColor(Z.text).lineLimit(1)
                        Text(card.stats[i].label).font(.system(size: 11)).foregroundColor(Z.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !card.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(card.bullets.indices, id: \.self) { i in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•")
                            Text(card.bullets[i]).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.system(size: 13)).foregroundColor(Z.body)
            }
            Flow(spacing: 8, lineSpacing: 8) {
                PillButton(title: f.t("cal.openDay"), primary: true, height: 34) {
                    app.day = day
                    app.screen = .day
                }
            }
        }
    }

    var search: some View {
        let f = app.f
        let text = Binding(get: { query ?? app.initialQuery }, set: { query = $0 })
        let hits = CalendarVM.hits(snapshot ? app.provider.search(text.wrappedValue) : found, f)
        return Card(spacing: 12) {
            H2(text: f.t("search.title"))
            VStack(alignment: .leading, spacing: 6) {
                Text(f.t("search.label")).font(.system(size: 12)).foregroundColor(Z.secondary)
                Field(placeholder: "", text: text, height: 38, fontSize: 14, fill: Z.inset, border: Z.buttonBorder,
                      radius: 9)
            }
            ForEach(hits.indices, id: \.self) { i in
                let h = hits[i]
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.title).font(.system(size: 13, weight: .semibold)).foregroundColor(Z.text)
                        Text(h.meta).font(.system(size: 12)).foregroundColor(Z.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(h.command).font(code(12)).foregroundColor(Z.body).lineLimit(1)
                        .padding(.vertical, 6).padding(.horizontal, 8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Z.popover))
                        .textSelection(.enabled)
                    CopyButton(title: f.t("copy"), height: 30, radius: 8, fontSize: 12) { h.command }
                }
                .padding(.vertical, 10).padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Z.inset))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Z.border))
            }
        }
        .task(id: text.wrappedValue) {
            let q = text.wrappedValue, provider = app.provider
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let hits = await Task.detached { provider.search(q) }.value
            if !Task.isCancelled { found = hits }
        }
    }
}
