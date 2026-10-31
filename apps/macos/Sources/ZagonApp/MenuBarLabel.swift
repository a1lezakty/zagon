import AppKit
import SwiftUI
import ZagonUIModel

/// The status item: two rings side by side, 5 hours left and the week right, each with its percent inside. Coloured
/// rings by default (5 hours orange, the week blue); monochrome follows the menu bar like a template image. A warning
/// keeps the ring apart from the other one: from 80 % its digits turn red, from 95 % the ring too. The track is the
/// bar's own colour, faint.
struct MenuBarLabel: View {
    /// Used percent; nil = no reading.
    let five: Int?
    let week: Int?
    var colored = true
    /// The menu bar's text colour, the one a template image gets.
    let tint: Color

    static let red = Color(hex: 0xFF453A)

    var body: some View {
        HStack(spacing: 4) {
            ring(five, Palette.fiveHour)
            ring(week, Palette.week)
        }
        .fixedSize()
    }

    /// 20 pt rings with a 1.5 pt rim leave a 17 pt hole; "88", the widest pair, is about 11 × 6.4 pt in 9 pt bold, so
    /// its corners stay ~2 pt off the rim.
    static let size: CGFloat = 20, line: CGFloat = 1.5
    static let digits = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)

    /// 100 % and over is a full ring with "!": three digits do not fit inside.
    func ring(_ pct: Int?, _ own: UInt32) -> some View {
        let c = (pct ?? 0) >= 95 ? Self.red : colored ? Color(hex: own) : tint
        return ZStack {
            Ring(fraction: min(1, Double(pct ?? 0) / 100), color: c, size: Self.size, line: Self.line,
                 inset: Self.line / 2, track: tint.opacity(0.25))
            Text(pct.map { $0 >= 100 ? "!" : "\($0)" } ?? "–")
                .font(Font(Self.digits as CTFont))
                .foregroundColor((pct ?? 0) >= 80 ? Self.red : tint)
                // centred on the digits themselves (cap height), not on the line box with its descender
                .alignmentGuide(VerticalAlignment.center) { $0[.firstTextBaseline] - Self.digits.capHeight / 2 }
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

    /// Calls `changed` when the bar turns dark or light (wallpaper, appearance), once the button exists; a new button
    /// (MenuBarExtra made the item again) is watched instead.
    static func watch(_ changed: @escaping @MainActor () -> Void) {
        guard let b = button, watching?.button !== b else { return }
        watching = (b, b.observe(\.effectiveAppearance) { _, _ in Task { @MainActor in changed() } })
    }
}
