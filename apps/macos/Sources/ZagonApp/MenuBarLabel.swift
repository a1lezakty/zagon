import AppKit
import SwiftUI
import ZagonUIModel

/// The status item: two rings side by side, 5 hours left and the week right, each with its percent inside (`beside`:
/// the numbers to the right instead, for 1x screens where 9 pt digits blur). Monochrome follows the menu bar like a
/// template image, with colour only as a warning (yellow from 80 %, red from 95 %); `colored` gives the rings the
/// limits' own colours.
struct MenuBarLabel: View {
    /// Used percent; nil = no reading.
    let five: Int?
    let week: Int?
    var colored = false
    var beside = false
    /// The menu bar's own colour, the one a template image gets.
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            ring(five, Palette.fiveHour)
            ring(week, Palette.week)
            if beside {
                (number(five, Palette.fiveHour) + Text(" · ").foregroundColor(tint) + number(week, Palette.week))
                    .font(Font(NSFont.menuBarFont(ofSize: 0) as CTFont).monospacedDigit())
            }
        }
    }

    func color(_ pct: Int?, _ own: UInt32) -> Color {
        switch pct ?? 0 {
        case 95...: return Color(hex: Palette.waiting)
        case 80...: return Color(hex: 0xFFCC00)
        default: return colored ? Color(hex: own) : tint
        }
    }

    func number(_ pct: Int?, _ own: UInt32) -> Text {
        Text(pct.map { "\($0)" } ?? "–").foregroundColor(color(pct, own))
    }

    /// 100 % and over is a full ring with "!": three digits do not fit inside.
    func ring(_ pct: Int?, _ own: UInt32) -> some View {
        let c = color(pct, own)
        return ZStack {
            Ring(fraction: min(1, Double(pct ?? 0) / 100), color: c, size: 18, line: 2, inset: 1, track: c.opacity(0.3))
            if !beside {
                Text(pct.map { $0 >= 100 ? "!" : "\($0)" } ?? "–")
                    .font(.system(size: 9.5, weight: .bold).monospacedDigit()).foregroundColor(c)
                    .lineLimit(1).minimumScaleFactor(0.7).frame(width: 13)
            }
        }
        .frame(width: 18, height: 18)
    }
}
