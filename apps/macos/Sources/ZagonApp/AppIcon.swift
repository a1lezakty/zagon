import AppKit
import SwiftUI
import ZagonUIModel

/// The app icon (Finder, Dock, the DMG): sheep in a corral. The round fence lights up like the 5-hour ring (68 % of
/// its posts orange); one sheep carries a red paint mark: a session waits for you. A dark tile on the macOS grid (an
/// 824 tile with a soft shadow on a 1024 canvas); the drawing is in 1024 units. Up to 32 px: fewer, thicker posts,
/// the sheep as white spots, the mark as a red dot and no shadow, so 16×16 still reads.
struct AppIconView: View {
    let px: CGFloat
    var body: some View {
        let small = px <= 32
        let tile = px * 824 / 1024
        let shape = RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [Color(hex: 0x3A3A42), Color(hex: 0x141417)], startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: max(1, tile / 200)))
                .frame(width: tile, height: tile)
                .shadow(color: .black.opacity(small ? 0 : 0.4), radius: px * 0.014, y: px * 0.012)
            Canvas { ctx, size in
                ctx.scaleBy(x: size.width / 1024, y: size.height / 1024)
                if small {
                    Self.fence(ctx, posts: 12, post: CGSize(width: 76, height: 130), track: 30)
                    for (x, y, r) in [(420, 450, 110), (610, 600, 105)] as [(CGFloat, CGFloat, CGFloat)] {
                        ctx.fill(Self.circle(x, y, r), with: .color(Color(hex: Palette.text)))
                    }
                    ctx.fill(Self.circle(610, 594, 66), with: .color(Color(hex: Palette.waiting)))
                } else {
                    Self.fence(ctx, posts: 18, post: CGSize(width: 40, height: 88), track: 14)
                    Self.sheep(ctx, 430, 430, 1.05, 1)
                    Self.sheep(ctx, 618, 520, 1, -1)
                    Self.sheep(ctx, 452, 650, 1.05, 1, mark: Color(hex: Palette.waiting))
                }
            }
        }
        .frame(width: px, height: px)
    }

    static func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }

    /// Posts round (512, 520) from 12 o'clock clockwise, each turned along the circle, over a faint rail.
    static func fence(_ ctx: GraphicsContext, posts n: Int, post: CGSize, track: CGFloat) {
        let r: CGFloat = 296
        ctx.stroke(circle(512, 520, r), with: .color(Color(hex: Palette.text).opacity(0.18)), lineWidth: track)
        for i in 0..<n {
            let a = CGFloat(i) / CGFloat(n) * 2 * .pi
            var c = ctx
            c.translateBy(x: 512 + r * sin(a), y: 520 - r * cos(a))
            c.rotate(by: .radians(Double(a)))
            c.fill(Path(roundedRect: CGRect(x: -post.width / 2, y: -post.height / 2, width: post.width, height: post.height),
                        cornerRadius: post.width * 0.4),
                   with: .color(Color(hex: CGFloat(i) / CGFloat(n) < 0.68 ? Palette.fiveHour : Palette.muted)))
        }
    }

    /// A white cloud of wool on dark legs, a dark face looking right (`dir` 1) or left (-1), scale `k`; `mark`: a paint
    /// mark on its back.
    static func sheep(_ ctx: GraphicsContext, _ x: CGFloat, _ y: CGFloat, _ k: CGFloat, _ dir: CGFloat, mark: Color? = nil) {
        let wool = Color(hex: Palette.text), dark = Color(hex: Palette.ground)
        for lx: CGFloat in [-38, -12, 18, 42] {
            ctx.fill(Path(roundedRect: CGRect(x: x + (lx - 9) * k, y: y + 30 * k, width: 18 * k, height: 44 * k), cornerRadius: 9 * k),
                     with: .color(dark))
        }
        let puffs: [(CGFloat, CGFloat, CGFloat)] = [(-46, 4, 34), (-22, -22, 36), (12, -26, 36), (42, -4, 34), (26, 22, 34),
                                                    (-10, 24, 36), (-2, -2, 40)]
        for (dx, dy, r) in puffs { ctx.fill(circle(x + dx * k, y + dy * k, r * k), with: .color(wool)) }
        if let mark {
            // Four quadratic curves, each relative to where the last one ended.
            let steps: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(18, -16, 34, -2), (16, 14, 4, 30), (-12, 16, -30, 8),
                                                                  (-20, -8, -8, -36)]
            var p = Path(), at = CGPoint(x: x - 14 * k, y: y - 20 * k)
            p.move(to: at)
            for (cx, cy, ex, ey) in steps {
                let end = CGPoint(x: at.x + ex * k, y: at.y + ey * k)
                p.addQuadCurve(to: end, control: CGPoint(x: at.x + cx * k, y: at.y + cy * k))
                at = end
            }
            p.closeSubpath()
            ctx.fill(p, with: .color(mark))
        }
        let hx = x + dir * 70 * k, hy = y - 10 * k
        var ear = ctx
        ear.translateBy(x: hx - dir * 22 * k, y: hy - 24 * k)
        ear.rotate(by: .degrees(Double(dir) * -30))
        ear.fill(Path(ellipseIn: CGRect(x: -22 * k, y: -10 * k, width: 44 * k, height: 20 * k)), with: .color(dark))
        ctx.fill(Path(ellipseIn: CGRect(x: hx - 26 * k, y: hy - 32 * k, width: 52 * k, height: 64 * k)), with: .color(dark))
        ctx.fill(circle(hx + dir * 8 * k, hy - 8 * k, 6 * k), with: .color(wool))
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
