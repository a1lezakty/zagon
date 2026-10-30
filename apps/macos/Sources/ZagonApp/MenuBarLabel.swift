import AppKit
import SwiftUI
import ZagonUIModel

/// The status item: two rings side by side, 5 hours left and the week right, each with its percent inside (`beside`:
/// the numbers to the right instead, for 1x screens where 9 pt digits blur). Coloured rings by default (5 hours
/// orange, the week blue); monochrome follows the menu bar like a template image. A warning keeps the ring apart from
/// the other one: from 80 % its digits turn red, from 95 % the ring too. The track is the bar's own colour, faint.
struct MenuBarLabel: View {
    /// Used percent; nil = no reading.
    let five: Int?
    let week: Int?
    var colored = true
    var beside = false
    /// The menu bar's text colour, the one a template image gets.
    let tint: Color

    static let red = Color(hex: 0xFF453A)

    var body: some View {
        HStack(spacing: 4) {
            ring(five, Palette.fiveHour)
            ring(week, Palette.week)
            if beside {
                (number(five) + Text(" · ").foregroundColor(tint) + number(week))
                    .font(Font(NSFont.menuBarFont(ofSize: 0) as CTFont).monospacedDigit())
            }
        }
    }

    func number(_ pct: Int?) -> Text {
        Text(pct.map { "\($0)" } ?? "–").foregroundColor((pct ?? 0) >= 80 ? Self.red : tint)
    }

    /// 100 % and over is a full ring with "!": three digits do not fit inside.
    func ring(_ pct: Int?, _ own: UInt32) -> some View {
        let c = (pct ?? 0) >= 95 ? Self.red : colored ? Color(hex: own) : tint
        return ZStack {
            Ring(fraction: min(1, Double(pct ?? 0) / 100), color: c, size: 18, line: 2, inset: 1, track: tint.opacity(0.25))
            if !beside {
                Text(pct.map { $0 >= 100 ? "!" : "\($0)" } ?? "–")
                    .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                    .foregroundColor((pct ?? 0) >= 80 ? Self.red : tint)
                    .lineLimit(1).minimumScaleFactor(0.7).frame(width: 13)
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// The status item's button behind MenuBarExtra (SwiftUI gives no handle to it): for its tooltip, and for the menu
/// bar's text colour, which a non-template icon has to pick by itself (the bar follows the wallpaper, not only the
/// system appearance).
@MainActor
enum StatusButton {
    static var button: NSStatusBarButton? {
        NSApp.windows.lazy.compactMap { $0.contentView.flatMap(find) }.first
    }

    private static func find(_ v: NSView) -> NSStatusBarButton? {
        v as? NSStatusBarButton ?? v.subviews.lazy.compactMap(find).first
    }

    static var dark: Bool {
        let a = button?.effectiveAppearance ?? NSApp.effectiveAppearance
        let name = a.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
        return name == .darkAqua || name == .vibrantDark
    }

    private static var watching: NSKeyValueObservation?

    /// Calls `changed` when the bar turns dark or light (wallpaper, appearance), once the button exists.
    static func watch(_ changed: @escaping @MainActor () -> Void) {
        guard watching == nil, let b = button else { return }
        watching = b.observe(\.effectiveAppearance) { _, _ in Task { @MainActor in changed() } }
    }
}
