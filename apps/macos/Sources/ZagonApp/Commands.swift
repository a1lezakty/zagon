import AppKit
import SwiftUI
import ZagonUIModel

/// The app menu: Settings… ⌘, and the screens ⌘1…⌘7 (back and forth in a day, week or month: ⌘[ ⌘] in `Header`).
@MainActor
struct ZagonCommands: Commands {
    let app: AppState

    init(app: AppState) {
        self.app = app
        // A click on a notification brings up the sessions: what waits, what finished, the limits.
        MacNotifications.onOpen = { [weak app] in app?.show(.sessions) }
    }

    var body: some Commands {
        let f = app.f
        CommandGroup(replacing: .appSettings) {
            Button(f.t("main.openSettings")) { app.show(.settings) }.keyboardShortcut(",")
        }
        CommandMenu(f.t("menu.go")) {
            ForEach(Screen.allCases) { s in
                let key = Character(String((Screen.allCases.firstIndex(of: s) ?? 0) + 1))
                Button(f.t("nav.\(s.rawValue)")) { app.show(s) }.keyboardShortcut(KeyEquivalent(key))
            }
        }
    }
}

extension AppState {
    /// Opens the main window, set by whoever owns it; nil = only the window already on screen is brought forward.
    static var openMain: (@MainActor () -> Void)?

    /// The main window on `screen`, in front.
    func show(_ screen: Screen) {
        self.screen = screen
        if let open = Self.openMain {
            open()
        } else {
            NSApp.windows.first { $0.title == "Zagon" }?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
