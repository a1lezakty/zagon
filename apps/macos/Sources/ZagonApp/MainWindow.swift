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
        AppState.openMain = { MainWindow.shared.show(AppDelegate.state) }
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
        // The Dock tile from the bundle's icon (set once the tile exists), also where Launch Services has not picked it
        // up yet: a fresh build showed the generic icon.
        NSApp.applicationIconImage = Bundle.main.image(forResource: "AppIcon")
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func make(_ app: AppState) -> NSWindow {
        let host = NSHostingController(rootView: WindowRoot().environmentObject(app).preferredColorScheme(.dark)
            .frame(minWidth: 980, minHeight: 620))
        host.sizingOptions = [.minSize]
        let w = MainNSWindow(contentViewController: host)
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

/// ⌘W closes the window and Zagon keeps running: the app has no File menu to give it that key.
final class MainNSWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // The W key (kVK_ANSI_W) in any layout, Caps Lock or not.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .command, event.keyCode == 13 {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The visible result of an action, over the panel and the window: a note goes away after a few seconds, an error
/// stays until it is closed.
struct Toast: Equatable {
    let id = UUID()
    var text: String
    var error = false
    /// A file to show in Finder, and the button's title (default "Show in Finder").
    var reveal: URL?
    var revealTitle: String?
}

struct ToastView: View {
    @EnvironmentObject private var app: AppState
    var body: some View {
        if let t = app.toast {
            HStack(spacing: 10) {
                Image(systemName: t.error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 13)).foregroundColor(t.error ? Z.bad : Z.good)
                Text(t.text).font(.system(size: 13)).foregroundColor(Z.text).lineLimit(5).fixedSize(horizontal: false, vertical: true)
                    .help(t.text)
                Spacer(minLength: 0)
                if let url = t.reveal {
                    PillButton(title: t.revealTitle ?? app.f.t("toast.reveal"), height: 28) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
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

/// Over the window until "Got it": the status item as it looks now, what to do when it is hidden, and Connect when
/// Claude Code / Codex are not connected yet.
struct WelcomeBar: View {
    @EnvironmentObject private var app: AppState
    var body: some View {
        let f = app.f, vm = MainVM(app.provider, f)
        // macOS 26 lets the user hide menu bar items in its settings.
        let hider = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                Banner.blue(Emphasis(before: f.t("welcome.text") + (hider ? "\n" + f.t("welcome.settings") : "")))
                HStack(alignment: .top, spacing: 6) {
                    // Numbers inside even where a 1x bar puts them beside: twice the size, they read.
                    MenuBarLabel(five: vm.five?.pct, week: vm.week?.pct, colored: !app.monoIcon, tint: Z.text)
                        .scaleEffect(2).frame(width: 80, height: 36)
                    Image(systemName: "arrow.up.right").font(.system(size: 16, weight: .semibold)).foregroundColor(Z.secondary)
                }
                .padding(.top, 4)
            }
            HStack(spacing: 8) {
                if app.localTools, let cli = app.cli, !cli.connected {
                    let installing = app.cliBusy && app.cliCommand == "install"
                    PillButton(title: installing ? f.t("connect.connecting") : f.t("connect.button"), primary: true, busy: installing) {
                        app.runCLI("install")
                    }
                    .disabled(app.cliBusy)
                }
                PillButton(title: f.t("welcome.ok")) { app.welcomeDone() }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }
}
