import SwiftUI
import ZagonUIModel

struct WindowRoot: View {
    @EnvironmentObject private var app: AppState
    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            Rectangle().fill(Z.divider).frame(width: 1).frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                if app.welcome { WelcomeBar().padding(.horizontal, 28).padding(.top, 20) }
                Group {
                    switch app.screen {
                    case .day: DayScreen()
                    case .week: WeekScreen()
                    case .calendar: CalendarScreen()
                    case .tasks: TasksScreen()
                    case .worklog: WorklogScreen()
                    case .sessions: SessionsScreen()
                    case .settings: SettingsScreen()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .foregroundColor(Z.text)
        .background(Z.ground)
        .overlay(alignment: .bottom) { ToastView().frame(maxWidth: 560).padding(20) }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var app: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZoneClock().padding(.horizontal, 12).padding(.bottom, app.scanning ? 2 : 8)
            if app.scanning {
                Text(app.f.t("main.scanning")).font(.system(size: 12)).foregroundColor(Z.muted)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            ForEach(Screen.allCases) { s in
                let on = s == app.screen
                Button { app.screen = s } label: {
                    Text(app.f.t("nav.\(s.rawValue)"))
                        .font(.system(size: 14, weight: on ? .medium : .regular))
                        .foregroundColor(on ? Z.text : Z.body)
                        .padding(.vertical, 9).padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(on ? Z.selection : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider1().padding(.vertical, 10).padding(.horizontal, 4)
            Text(app.f.t("nav.machines").uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.66)
                .foregroundColor(Z.muted).padding(.vertical, 4).padding(.horizontal, 12)
            ForEach(app.provider.hosts(), id: \.name) { h in
                HStack(spacing: 8) {
                    Dot(color: h.online ? Z.working : Z.faint, size: 7)
                    Text(h.name)
                }
                .font(.system(size: 13)).foregroundColor(Z.body)
                .padding(.vertical, 6).padding(.horizontal, 12)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(app.f.t(h.online ? "host.online" : "host.offline", h.name))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16).padding(.horizontal, 12)
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Z.sidebar)
    }
}

// MARK: - Sessions

struct SessionsScreen: View {
    @EnvironmentObject private var app: AppState
    @State private var showIdle = true
    var body: some View {
        let vm = MainVM(app.provider, app.f)
        Page {
            Header(app.f.t("nav.sessions"))
            HStack(alignment: .top, spacing: 16) {
                Card(spacing: 16) {
                    LimitsBlock(vm: vm)
                    TotalsBlock(vm: vm)
                }
                .frame(width: 420)
                Card { SessionsBlock(vm: vm, showIdle: $showIdle) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
