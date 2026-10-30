import AppKit
import SwiftUI
import ZagonUIModel

/// The app icon (Finder, Dock, the DMG): the menu bar's two rings, the week outside and 5 hours inside, on a dark tile
/// laid out on the macOS grid (an 824 tile with a soft shadow on a 1024 canvas). Up to 32 px the rings are thicker
/// and there is no shadow, so 16×16 still reads.
struct AppIconView: View {
    let px: CGFloat
    /// The rings side by side, as in the menu bar (an alternative for the user to compare).
    var pair = false
    var body: some View {
        let small = px <= 32
        let tile = px * 824 / 1024
        let rings = tile * (small ? 0.84 : 0.70)
        let line = rings * (small ? 0.167 : 0.125), gap = rings * (small ? 0.09 : 0.08)
        let shape = RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
        let track = Color.white.opacity(0.09)
        ZStack {
            shape.fill(LinearGradient(colors: [Color(hex: 0x3A3A42), Color(hex: 0x141417)], startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: max(1, tile / 200)))
                .frame(width: tile, height: tile)
                .shadow(color: .black.opacity(small ? 0 : 0.4), radius: px * 0.014, y: px * 0.012)
            if pair {
                let d = tile * (small ? 0.42 : 0.36), w = d * (small ? 0.2 : 0.16)
                HStack(spacing: tile * 0.05) {
                    Ring(fraction: 0.82, color: Color(hex: Palette.fiveHour), size: d, line: w, inset: w / 2, track: track)
                    Ring(fraction: 0.68, color: Color(hex: Palette.week), size: d, line: w, inset: w / 2, track: track)
                }
            } else {
                Ring(fraction: 0.68, color: Color(hex: Palette.week), size: rings, line: line, inset: line / 2, track: track)
                Ring(fraction: 0.82, color: Color(hex: Palette.fiveHour), size: rings, line: line, inset: line * 1.5 + gap,
                     track: track)
            }
        }
        .frame(width: px, height: px)
    }
}

@MainActor
enum AppIcon {
    /// `Zagon --app-icon <dir>`: the iconset `iconutil` turns into AppIcon.icns (16…512 pt, 1x and 2x).
    static func iconset(_ dir: URL) -> Bool {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var ok = true
        for pt in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = CGFloat(pt * scale)
                ok = Snapshots.write(AppIconView(px: px), width: px, scale: 1, "icon_\(pt)x\(pt)" + (scale == 2 ? "@2x" : ""), dir) && ok
            }
        }
        return ok
    }
}
