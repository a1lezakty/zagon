import AppKit
import SwiftUI
import ZagonUIModel

/// Opening Zagon (Finder, Launchpad, Spotlight, the Dock) shows the window, the first time and again while it runs: a
/// status item alone can be hidden behind the notch or a full menu bar, and a launch that shows nothing looks broken.
/// Opened at login, it stays in the menu bar.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The one AppState; the menu bar scene takes it as its StateObject.
    static let state = AppState.local()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // macOS marks the login item's launch in its open event.
        let e = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = e?.eventID == AEEventID(kAEOpenApplication)
            && e?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        if !atLogin { MainWindow.shared.show(Self.state) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.shared.show(Self.state)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// The main window, made with AppKit: SwiftUI opens its scenes only from inside a view, and the window has to open
/// from the app delegate too. While it is open Zagon is a regular app (Dock, Cmd-Tab, the app menu); closed, only the
/// status item is left.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    static let shared = MainWindow()
    private var window: NSWindow?
    private weak var app: AppState?

    func show(_ app: AppState) {
        self.app = app
        let w = window ?? make(app)
        window = w
        app.windowOpen = true
        NSApp.setActivationPolicy(.regular)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func make(_ app: AppState) -> NSWindow {
        let host = NSHostingController(rootView: WindowRoot().environmentObject(app).preferredColorScheme(.dark)
            .frame(minWidth: 980, minHeight: 620))
        host.sizingOptions = [.minSize]
        let w = NSWindow(contentViewController: host)
        w.title = "Zagon"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(NSSize(width: 1280, height: 860))
        w.center()
        w.setFrameAutosaveName("main")
        return w
    }

    func windowWillClose(_ notification: Notification) {
        app?.windowOpen = false
        NSApp.setActivationPolicy(.accessory)
    }
}

/// The visible result of an action, over the panel and the window: a note goes away after a few seconds, an error
/// stays until it is closed.
struct Toast: Equatable {
    let id = UUID()
    var text: String
    var error = false
    /// A saved file: "Show in Finder".
    var reveal: URL?
}

struct ToastView: View {
    @EnvironmentObject private var app: AppState
    var body: some View {
        if let t = app.toast {
            HStack(spacing: 10) {
                Dot(color: t.error ? Z.bad : Z.working)
                Text(t.text).font(.system(size: 13)).foregroundColor(Z.text).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let url = t.reveal {
                    PillButton(title: app.f.t("toast.reveal"), height: 28) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button { app.toast = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundColor(Z.secondary)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(app.f.t("toast.close"))
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Z.control))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(t.error ? Z.bad.opacity(0.6) : Z.buttonBorder))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        }
    }
}

/// Over the window until "Got it": where Zagon lives, and Connect when Claude Code / Codex are not connected yet.
struct WelcomeBar: View {
    @EnvironmentObject private var app: AppState
    var body: some View {
        let f = app.f
        VStack(alignment: .leading, spacing: 10) {
            Banner.blue(Emphasis(before: f.t("welcome.text")))
            HStack(spacing: 8) {
                if app.localTools, let cli = app.cli, !cli.connected {
                    PillButton(title: app.cliBusy ? f.t("connect.connecting") : f.t("connect.button"), primary: true) {
                        app.runCLI("install")
                    }
                }
                PillButton(title: f.t("welcome.ok")) { app.welcomeDone() }
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }
}
