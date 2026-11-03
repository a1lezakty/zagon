import AppKit
import SwiftUI
import ZagonUIModel

/// The status item (`MenuBarVM`). One AI: two rings side by side, 5 hours left and the week right, each with its
/// percent inside. Both AIs: a ring-in-ring each, Claude left and Codex right, the week outside and 5 hours inside
/// with its percent. Each AI has its own two colours (settings); monochrome follows the menu bar like a template image,
/// the outer ring a little fainter so the two rims read apart. A warning keeps the ring apart from the others: from
/// 80 % its digits turn red, from 95 % the ring too. The track is the bar's own colour, faint. An AI without a 5-hour
/// window shows its week ring alone, the week's number inside (`MenuBarVM.AI.weekOnly`). Another Claude Code account
/// follows as a ring-in-ring with its higher number inside, next to the default account (`MenuBarVM.accounts`, `row`).
struct MenuBarLabel: View {
    let vm: MenuBarVM
    var colored = true
    /// The menu bar's text colour, the one a template image gets.
    let tint: Color

    static let red = Color(hex: 0xFF453A)

    var body: some View {
        HStack(spacing: 4) {
            if vm.nested {
                ForEach(vm.row.indices, id: \.self) { nested(vm.row[$0]) }
            } else {
                if let ai = vm.ais.first {
                    if !ai.weekOnly { ring(ai.five, ai.colors.five) }
                    ring(ai.week, ai.colors.week)
                }
                ForEach(vm.accounts.indices, id: \.self) { nested(vm.accounts[$0]) }
            }
        }
        .fixedSize()
    }

    /// Points wide: 20 per ring or ring-in-ring, 4 between (the welcome bar's 2x preview takes its frame from this).
    static func width(_ vm: MenuBarVM) -> CGFloat {
        let n = vm.nested ? vm.row.count : (vm.ais.first.map { $0.weekOnly ? 1 : 2 } ?? 0) + vm.accounts.count
        return CGFloat(n) * size + CGFloat(max(n - 1, 0)) * 4
    }

    /// 20 pt rings with a 2 pt rim leave a 16 pt hole; "88", the widest pair, is about 11 × 6.4 pt in 9 pt bold, so
    /// its corners stay ~1.5 pt off the rim. A whole-point inset keeps the rim on pixels: 0.75 got rounded off-centre.
    static let size: CGFloat = 20, line: CGFloat = 2
    static let digits = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
    /// A ring-in-ring: two 2 pt rims with no gap leave a 12 pt hole, so its digits are 8 pt; "88" (~9.8 × 5.7 pt) clears
    /// the rim by ~0.3 pt at its corners, more where the glyphs round off.
    static let inner = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .bold)

    func color(_ pct: Int?, _ own: UInt32, faint: Bool = false) -> Color {
        (pct ?? 0) >= 95 ? Self.red : colored ? Color(hex: own) : faint ? tint.opacity(0.6) : tint
    }

    static func fraction(_ pct: Int?) -> Double { min(1, Double(pct ?? 0) / 100) }

    /// 100 % and over is a full ring with "!": three digits do not fit inside.
    func number(_ pct: Int?, _ font: NSFont) -> some View {
        Text(pct.map { $0 >= 100 ? "!" : "\($0)" } ?? "–")
            .font(Font(font as CTFont))
            .foregroundColor((pct ?? 0) >= 80 ? Self.red : tint)
            // centred on the digits themselves (cap height), not on the line box with its descender
            .alignmentGuide(VerticalAlignment.center) { $0[.firstTextBaseline] - font.capHeight / 2 }
    }

    func ring(_ pct: Int?, _ own: UInt32) -> some View {
        ZStack {
            Ring(fraction: Self.fraction(pct), color: color(pct, own), size: Self.size, line: Self.line,
                 inset: Self.line / 2, track: tint.opacity(0.25))
            number(pct, Self.digits)
        }
        .frame(width: Self.size, height: Self.size)
    }

    @ViewBuilder func nested(_ ai: MenuBarVM.AI) -> some View {
        if ai.weekOnly { ring(ai.week, ai.colors.week) } else { ringInRing(ai) }
    }

    /// One 4 pt track under both rims (two adjacent faint tracks would leave a seam where their edges blend).
    func ringInRing(_ ai: MenuBarVM.AI) -> some View {
        ZStack {
            Circle().stroke(tint.opacity(0.25), lineWidth: Self.line * 2).padding(Self.line)
            Ring(fraction: Self.fraction(ai.week), color: color(ai.week, ai.colors.week, faint: true), size: Self.size,
                 line: Self.line, inset: Self.line / 2, track: .clear)
            Ring(fraction: Self.fraction(ai.five), color: color(ai.five, ai.colors.five), size: Self.size,
                 line: Self.line, inset: Self.line * 1.5, track: .clear)
            number(ai.inside, Self.inner)
        }
        .frame(width: Self.size, height: Self.size)
    }
}

/// The status item's button behind MenuBarExtra (SwiftUI gives no handle to it): for its tooltip, and for the menu
/// bar's text colour, which a non-template icon has to pick by itself (the bar follows the wallpaper, not only the
/// system appearance).
@MainActor
enum StatusButton {
    private static weak var found: NSStatusBarButton?

    static var button: NSStatusBarButton? {
        if let found, found.window != nil { return found }
        // The status item's own window first; any window if a later macOS names it otherwise.
        let windows = NSApp.windows.filter { $0.className.contains("StatusBar") }
        found = (windows.isEmpty ? NSApp.windows : windows).lazy.compactMap { $0.contentView.flatMap(find) }.first
        return found
    }

    private static func find(_ v: NSView) -> NSStatusBarButton? {
        v as? NSStatusBarButton ?? v.subviews.lazy.compactMap(find).first
    }

    static var dark: Bool {
        let a = button?.effectiveAppearance ?? NSApp.effectiveAppearance
        let name = a.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
        return name == .darkAqua || name == .vibrantDark
    }

    private static var watching: (button: NSStatusBarButton, kvo: NSKeyValueObservation)?
    private static var wasDark: Bool?

    /// Calls `changed` when the bar turns dark or light (wallpaper, appearance), once the button exists; a new button
    /// (MenuBarExtra made the item again) is watched instead. KVO fires on every `setAppearance` too: AppKit sets one on
    /// the button to draw the item's copies for other menu bars after each new image. Passed on unchecked, that drew a
    /// new image, which got new copies drawn, and so on: a busy core (0.1.2, macOS 27).
    static func watch(_ changed: @escaping @MainActor () -> Void) {
        guard let b = button, watching?.button !== b else { return }
        wasDark = dark
        watching = (b, b.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in
                guard dark != wasDark else { return }
                wasDark = dark
                changed()
            }
        })
    }
}
