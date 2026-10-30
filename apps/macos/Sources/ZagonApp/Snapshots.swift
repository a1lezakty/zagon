import AppKit
import SwiftUI
import ZagonUIModel

/// `Zagon --snapshots <dir>`: every screen on the design sample, dark, both languages, as PNG (for CI).
@MainActor
enum Snapshots {
    static let queries: [Lang: String] = [.en: "demo video", .ru: "демо видео"]

    /// The design sample as `<screen>-<lang>.png`; with `fixtures`, also a store scanned from them as `db-<screen>-<lang>.png`.
    static func render(to dir: URL, fixtures: String?) {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var failed = false
        for lang in Lang.allCases {
            failed = !screens(AppState.mock(lang), query: queries[lang] ?? "", prefix: "", lang, dir) || failed
            if let fixtures {
                do {
                    failed = !screens(try AppState.fixture(fixtures, lang), query: "demo video", prefix: "db-", lang, dir) || failed
                } catch {
                    print("fixture store failed: \(error)")
                    failed = true
                }
            }
        }
        failed = !icons(dir) || failed
        if failed { exit(1) }
    }

    /// The status item icon ×4: coloured on a dark bar, monochrome as a light and a dark menu bar tint it.
    static func icons(_ dir: URL) -> Bool {
        let p = MockDataProvider(lang: .en)
        let vm = MainVM(p, Fmt(lang: .en, now: p.now))
        func cell<V: View>(_ v: V, _ bar: UInt32) -> some View {
            v.scaleEffect(4).frame(width: 80, height: 80).background(Color(hex: bar))
        }
        let strip = HStack(spacing: 16) {
            cell(RingsIcon(five: vm.five, week: vm.week), 0x1E1E22)
            cell(RingsIcon(five: vm.five, week: vm.week, mono: true), 0xECECEC)
            cell(RingsIcon(five: vm.five, week: vm.week, mono: true).colorInvert(), 0x1E1E22)
        }
        .padding(16)
        return write(strip, width: 304, "icon", dir)
    }

    static func screens(_ state: AppState, query: String, prefix: String, _ lang: Lang, _ dir: URL) -> Bool {
        state.initialQuery = query
        var ok = write(MainPanel().environmentObject(state), width: 400, "\(prefix)main-\(lang.rawValue)", dir)
        if prefix.isEmpty {
            state.pace = true
            ok = write(MainPanel().environmentObject(state), width: 400, "main-pace-\(lang.rawValue)", dir) && ok
            state.pace = false
            state.showLeft = true
            ok = write(MainPanel().environmentObject(state), width: 400, "main-left-\(lang.rawValue)", dir) && ok
            state.showLeft = false
            let connected = state.cli
            state.cli = Connect.Status(ok: ["hooks: ~/.claude/settings.json"], missing: ["MCP: claude"])
            ok = write(MainPanel().environmentObject(state), width: 400, "main-connect-\(lang.rawValue)", dir) && ok
            state.cli = connected
        }
        for screen in Screen.allCases {
            state.screen = screen
            let root = WindowRoot().environmentObject(state).fixedSize(horizontal: false, vertical: true)
            ok = write(root, width: 1280, "\(prefix)\(screen.rawValue)-\(lang.rawValue)", dir) && ok
        }
        return ok
    }

    static func write<V: View>(_ view: V, width: CGFloat, _ name: String, _ dir: URL) -> Bool {
        let r = ImageRenderer(content: view.frame(width: width)
            .environment(\.isSnapshot, true).environment(\.colorScheme, .dark))
        r.scale = 2
        r.proposedSize = ProposedViewSize(width: width, height: nil)
        guard let cg = r.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]),
              (try? png.write(to: dir.appendingPathComponent(name + ".png"))) != nil
        else {
            print("snapshot failed: \(name)")
            return false
        }
        print("\(name).png \(cg.width)x\(cg.height)")
        return true
    }
}
