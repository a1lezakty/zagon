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
            failed = !emptyStates(lang, dir) || failed
            if let fixtures {
                do {
                    failed = !screens(try AppState.fixture(fixtures, lang), query: "demo video", prefix: "db-", lang, dir) || failed
                } catch {
                    print("fixture store failed: \(error)")
                    failed = true
                }
            }
        }
        failed = !menubar(dir) || failed
        failed = !appIcon(dir) || failed
        if failed { exit(1) }
    }

    /// The status item on a light, a dark and a wallpaper-tinted menu bar, at the bar's own size and at 2x, monochrome
    /// and coloured. `menubar-<mode>@<n>x.png`, one AI: 5 hours / week at 2/41, 62/88, 97/100 and no reading.
    /// `menubar-both-<mode>@<n>x.png`, Claude | Codex: at rest, red digits, red rings, a window without a reading.
    /// `menubar-digits@<n>x.png` / `menubar-both-digits@<n>x.png`: every value 0…99, to see each one inside its ring.
    static func menubar(_ dir: URL) -> Bool {
        let bars: [(UInt32, Color)] = [(0xF2F2F4, .black.opacity(0.85)), (0x1E1E22, .white.opacity(0.9)),
                                       (0x2F67C8, .white.opacity(0.95))]
        let f = Fmt(lang: .en, now: Date())
        func vm(_ ais: [(Tool, Int?, Int?)]) -> MenuBarVM {
            MenuBarVM(ais: ais.map { MenuBarVM.AI(tool: $0.0, five: $0.1, week: $0.2, colors: .standard($0.0)) }, f)
        }
        let sheets: [(String, [MenuBarVM])] = [
            ("", [vm([(.claude, 2, 41)]), vm([(.claude, 62, 88)]), vm([(.claude, 97, 100)]), vm([(.claude, nil, nil)])]),
            ("both-", [vm([(.claude, 62, 35), (.codex, 18, 71)]), vm([(.claude, 88, 50), (.codex, 2, 41)]),
                       vm([(.claude, 97, 100), (.codex, 96, 62)]), vm([(.claude, nil, 35), (.codex, 18, nil)])]),
        ]
        var ok = true
        for (name, states) in sheets {
            for colored in [false, true] {
                let sheet = VStack(spacing: 8) {
                    ForEach(bars.indices, id: \.self) { b in
                        HStack(spacing: 40) {
                            ForEach(states.indices, id: \.self) { s in
                                HStack(spacing: 14) {
                                    MenuBarLabel(vm: states[s], colored: colored, tint: bars[b].1)
                                    Image(systemName: "wifi")
                                    Image(systemName: "battery.75percent")
                                    Text("Thu 20:18")
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .font(Font(NSFont.menuBarFont(ofSize: 0) as CTFont))
                        .foregroundColor(bars[b].1)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(Color(hex: bars[b].0))
                    }
                }
                .padding(8)
                .background(Color(hex: Palette.muted))
                for scale in [1, 2] as [CGFloat] {
                    ok = write(sheet, width: 1280, scale: scale, "menubar-\(name)\(colored ? "color" : "mono")@\(Int(scale))x", dir) && ok
                }
            }
        }
        for (name, both) in [("", false), ("both-", true)] {
            let digits = VStack(spacing: 6) {
                ForEach(0..<10) { r in
                    HStack(spacing: 16) {
                        ForEach(0..<5) { c in
                            let n = r * 10 + c * 2
                            MenuBarLabel(vm: both ? vm([(.claude, n, 40), (.codex, n + 1, 70)]) : vm([(.claude, n, n + 1)]),
                                         tint: bars[0].1)
                        }
                    }
                }
            }
            .padding(12)
            .background(Color(hex: bars[0].0))
            for scale in [1, 2] as [CGFloat] {
                ok = write(digits, width: 320, scale: scale, "menubar-\(name)digits@\(Int(scale))x", dir) && ok
            }
        }
        return ok
    }

    /// The app icon at 1024, and at 16…256 px as Finder shows it on a light and a dark window.
    static func appIcon(_ dir: URL) -> Bool {
        let sizes: [CGFloat] = [16, 32, 64, 128, 256]
        let rows = VStack(spacing: 0) {
            ForEach([0xF5F5F7, 0x1E1E22] as [UInt32], id: \.self) { bg in
                HStack(alignment: .bottom, spacing: 24) {
                    ForEach(sizes, id: \.self) { AppIconView(px: $0) }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: bg))
            }
        }
        return write(AppIconView(px: 1024), width: 1024, scale: 1, "app-icon", dir)
            && write(rows, width: 640, scale: 1, "app-icon-sizes", dir)
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
        if prefix.isEmpty {
            // The first window (where Zagon lives, Connect) and a toast, in the window and in the panel.
            let connected = state.cli
            state.cli = Connect.Status(ok: ["hooks: ~/.claude/settings.json"], missing: ["MCP: claude"])
            state.screen = .day
            state.welcome = true
            state.toast = Toast(text: state.f.t("connect.done"))
            let root = WindowRoot().environmentObject(state).fixedSize(horizontal: false, vertical: true)
            ok = write(root, width: 1280, "welcome-\(lang.rawValue)", dir) && ok
            ok = write(MainPanel().environmentObject(state), width: 400, "main-toast-\(lang.rawValue)", dir) && ok
            state.welcome = false
            state.toast = nil
            state.cli = connected
        }
        return ok
    }

    /// The panel with nothing to show yet (an empty store, not connected), with the last reading from before a reset, and
    /// with both AIs (a ring in a ring each, used and left).
    static func emptyStates(_ lang: Lang, _ dir: URL) -> Bool {
        let empty = AppState(provider: StoreDataProvider.empty(), lang: lang)
        empty.cli = Connect.Status(missing: ["hooks: ~/.claude/settings.json"])
        var p = MockDataProvider(lang: lang)
        p.staleLimits = true
        let stale = AppState(provider: p, lang: lang, homeBack: 1)
        stale.cli = AppState.mock(lang).cli
        let a = write(MainPanel().environmentObject(empty), width: 400, "main-empty-\(lang.rawValue)", dir)
        let b = write(MainPanel().environmentObject(stale), width: 400, "main-stale-\(lang.rawValue)", dir)
        var two = MockDataProvider(lang: lang)
        two.codexLimits = true
        let both = AppState(provider: two, lang: lang)
        both.cli = stale.cli
        let c = write(MainPanel().environmentObject(both), width: 400, "main-both-\(lang.rawValue)", dir)
        both.showLeft = true
        let d = write(MainPanel().environmentObject(both), width: 400, "main-both-left-\(lang.rawValue)", dir)
        return a && b && c && d
    }

    static func write<V: View>(_ view: V, width: CGFloat, scale: CGFloat = 2, _ name: String, _ dir: URL) -> Bool {
        let r = ImageRenderer(content: view.frame(width: width)
            .environment(\.isSnapshot, true).environment(\.colorScheme, .dark))
        r.scale = scale
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
