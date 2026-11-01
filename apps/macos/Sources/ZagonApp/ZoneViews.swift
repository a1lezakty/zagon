import SwiftUI
import ZagonUIModel

/// A zone setting other than the app's own (the worklog zone): its value (nil = the machine's), the machine's zone,
/// and where a pick goes.
struct ZoneChoice {
    var id: String?
    var machine: TimeZone
    var pick: (String?) -> Void
}

/// The zone list: "System" first, then every known zone west to east, filtered by a search.
struct ZonePicker: View {
    @EnvironmentObject private var app: AppState
    @State private var find = ""
    /// nil: the app's own zone.
    var choice: ZoneChoice?

    var body: some View {
        let f = app.f, now = app.provider.now, selected = choice.map(\.id) ?? app.zoneID
        VStack(alignment: .leading, spacing: 8) {
            Field(placeholder: f.t("zone.find"), text: $find)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    row(choice.map { f.t("settings.wl.tzMachine", Zones.label($0.machine, at: now)) }
                        ?? f.t("zone.system", Zones.label(.autoupdatingCurrent, at: now)), on: selected == nil) { pick(nil) }
                    ForEach(Zones.search(find, at: now), id: \.self) { id in
                        row(TimeZone(identifier: id).map { Zones.label($0, at: now) } ?? id, on: selected == id) { pick(id) }
                    }
                }
            }
            .frame(height: 300)
            if choice == nil { ZoneNotes() }
        }
        .padding(12)
        .frame(width: 340)
    }

    func pick(_ id: String?) {
        if let choice { choice.pick(id) } else { app.zoneID = id }
    }

    func row(_ title: String, on: Bool, _ pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13)).foregroundColor(on ? Z.text : Z.body).lineLimit(1)
                Spacer(minLength: 0)
                if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundColor(Z.week) }
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Z.selection : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// What the chosen zone means, and the honest caveat for an offset that is not whole hours.
struct ZoneNotes: View {
    @EnvironmentObject private var app: AppState
    var body: some View {
        let f = app.f
        VStack(alignment: .leading, spacing: 6) {
            Text(f.t("zone.note"))
            Text(f.t("zone.base"))
            if !Zones.wholeHours(app.zone, at: app.provider.now) { Text(f.t("zone.approx")).foregroundColor(Z.amber) }
        }
        .font(.system(size: 12)).foregroundColor(Z.muted).fixedSize(horizontal: false, vertical: true)
    }
}

/// The caveat on screens that split tokens into days, shown only for a zone that is not whole hours from UTC.
struct ZoneApprox: View {
    @EnvironmentObject private var app: AppState
    let at: Date
    var body: some View {
        if !Zones.wholeHours(app.zone, at: at) {
            Text(app.f.t("zone.approx")).font(.system(size: 12)).foregroundColor(Z.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "14:32 · UTC+5": the time in the chosen zone; a click opens the zone list.
struct ZoneClock: View {
    @EnvironmentObject private var app: AppState
    @State private var open = false
    var body: some View {
        let f = app.f
        Button { open = true } label: {
            // Ticks on its own: the screens redraw only when data changes.
            TimelineView(.everyMinute) { _ in
                Text(f.time(app.provider.now) + " · " + Zones.offset(app.zone, at: app.provider.now))
                    .font(.system(size: 12)).foregroundColor(Z.secondary).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(f.t("zone.title"))
        .popover(isPresented: $open, arrowEdge: .bottom) { ZonePicker().environmentObject(app) }
    }
}

/// Settings: the zone in use and a button to the list.
struct ZoneCard: View {
    @EnvironmentObject private var app: AppState
    @State private var open = false
    var body: some View {
        let f = app.f, now = app.provider.now
        Card(spacing: 12) {
            Text(f.t("zone.title")).font(.system(size: 15, weight: .semibold))
            HStack(spacing: 12) {
                Text(app.zoneID == nil ? f.t("zone.system", Zones.label(app.zone, at: now)) : Zones.label(app.zone, at: now))
                    .font(.system(size: 13)).foregroundColor(Z.text)
                PillButton(title: f.t("zone.change")) { open = true }
                    .popover(isPresented: $open, arrowEdge: .bottom) { ZonePicker().environmentObject(app) }
            }
            ZoneNotes()
        }
        .frame(maxWidth: 640, alignment: .leading)
    }
}
