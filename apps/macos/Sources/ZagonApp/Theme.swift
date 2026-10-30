import AppKit
import SwiftUI
import ZagonUIModel

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Design colours (dark). Accents come from `Palette`; the rest are the mockups' greys and tints.
enum Z {
    static let ground = Color(hex: Palette.ground)
    static let sidebar = Color(hex: Palette.sidebar)
    static let card = Color(hex: Palette.card)
    static let popover = Color(hex: Palette.popover)
    static let inset = Color(hex: Palette.inset)
    static let border = Color(hex: Palette.border)
    static let control = Color(hex: Palette.control)
    static let text = Color(hex: Palette.text)
    static let body = Color(hex: Palette.body)
    static let secondary = Color(hex: Palette.secondary)
    static let muted = Color(hex: Palette.muted)
    static let track = Color(hex: Palette.track)
    static let week = Color(hex: Palette.week)
    static let working = Color(hex: Palette.working)
    static let waiting = Color(hex: Palette.waiting)
    static let good = Color(hex: Palette.good)
    static let bad = Color(hex: Palette.bad)
    static let link = Color(hex: Palette.link)
    static let selection = Color(hex: Palette.selection)
    static let divider = Color(hex: 0x2A2A2F)
    static let barTrack = Color(hex: 0x2A2A2E)
    static let laneBorder = Color(hex: 0x26262A)
    static let button = Color(hex: 0x2C2C30)
    static let buttonBorder = Color(hex: 0x44444A)
    static let onAccent = Color(hex: 0x0E1420)
    static let faint = Color(hex: 0x55555C)
    static let soft = Color(hex: 0xD6D6DA)
    static let focus = Color(hex: 0x3A4B69)
    static let focusFill = Color(hex: 0x232C3B)
}

/// Numbers: the system font with monospaced digits.
func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight).monospacedDigit()
}

/// Commands and task keys.
func code(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

/// Copies and raises `copied` for 1.5 s, so the place that copied can say so.
@MainActor
func copy(_ s: String, _ copied: Binding<Bool>) {
    copyToPasteboard(s)
    copied.wrappedValue = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied.wrappedValue = false }
}

/// A text button that copies, then reads "Copied ✓" for 1.5 s.
struct CopyButton: View {
    let title: String
    var height: CGFloat = 36
    var radius: CGFloat = 9
    var fontSize: CGFloat = 13
    let text: () -> String
    @EnvironmentObject private var app: AppState
    @State private var copied = false
    var body: some View {
        PillButton(title: copied ? app.f.t("copied.button") : title, height: height, radius: radius, fontSize: fontSize) {
            copy(text(), $copied)
        }
    }
}

/// Plain, but a press shows.
struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.75 : 1)
    }
}

// MARK: snapshot mode

private struct SnapshotKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Rendering into a PNG: AppKit-backed views (scroll views, text fields, menus) are replaced by plain ones,
    /// because `ImageRenderer` draws them as placeholders.
    var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

struct Scrolling<Content: View>: View {
    @Environment(\.isSnapshot) private var snapshot
    @ViewBuilder let content: () -> Content
    var body: some View {
        if snapshot { content() } else { ScrollView { content() } }
    }
}

/// Scrolls only when the content is taller than `maxHeight`, otherwise takes the content's height.
struct CappedScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var height: CGFloat = 0
    @Environment(\.isSnapshot) private var snapshot
    var body: some View {
        if snapshot {
            content()
        } else {
            ScrollView {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
            }
            .frame(height: min(height, maxHeight))
            .onPreferenceChange(HeightKey.self) { height = $0 }
        }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: building blocks

struct Dot: View {
    let color: Color
    var size: CGFloat = 8
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

struct H2: View {
    let text: String
    var size: CGFloat = 16
    var body: some View { Text(text).font(.system(size: size, weight: .semibold)).foregroundColor(Z.text) }
}

/// Uppercase caption with letter spacing ("WAITING FOR YOU · 2").
struct Caps: View {
    let text: String
    var color = Z.secondary
    var size: CGFloat = 12
    var body: some View {
        Text(text.uppercased()).font(.system(size: size, weight: .semibold)).tracking(size * 0.04).foregroundColor(color)
    }
}

struct Card<Content: View>: View {
    var padding = EdgeInsets(top: 16, leading: 18, bottom: 18, trailing: 18)
    var radius: CGFloat = 14
    var fill = Z.card
    var border = Z.border
    var spacing: CGFloat = 14
    /// Fill the height offered (cards side by side in a row of equal height).
    var stretch = false
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content() }
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: stretch ? .infinity : nil, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: radius).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(border))
    }
}

struct StatTile: View {
    let stat: Stat
    var size: CGFloat = 22
    var highlight = false
    var body: some View {
        VStack(alignment: .leading, spacing: size >= 22 ? 4 : 3) {
            Text(stat.value).font(mono(size, .semibold)).foregroundColor(Z.text).lineLimit(1)
            Text(stat.label).font(.system(size: 12)).foregroundColor(highlight ? Color(hex: 0xC9D8EE) : Z.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let d = stat.delta {
                Text(d).font(.system(size: 12)).foregroundColor(stat.good == false ? Z.bad : Z.good)
            }
        }
        .padding(.vertical, size >= 22 ? 14 : 12).padding(.horizontal, size >= 22 ? 16 : 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(highlight ? Color(hex: 0x1F2733) : Z.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(highlight ? Z.focus : Z.border))
    }
}

struct StatsRow: View {
    let stats: [Stat]
    var size: CGFloat = 22
    var spacing: CGFloat = 12
    var highlightLast = false
    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(stats.indices, id: \.self) { i in
                StatTile(stat: stats[i], size: size, highlight: highlightLast && i == stats.count - 1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct PillButton: View {
    let title: String
    var primary = false
    var height: CGFloat = 36
    var radius: CGFloat = 9
    var fontSize: CGFloat = 13
    var expand = false
    /// Working: a spinner before the title, and no clicks.
    var busy = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14) }
                Text(title)
                    .font(.system(size: fontSize, weight: primary ? .semibold : .medium))
                    .foregroundColor(primary ? Z.onAccent : Z.text)
                    .lineLimit(1)
            }
            .padding(.horizontal, expand ? 8 : 14)
            .frame(maxWidth: expand ? .infinity : nil)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: radius).fill(primary ? Z.week : Z.button))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(primary ? Color.clear : Z.buttonBorder))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .disabled(busy)
        .opacity(busy || !enabled ? 0.6 : 1)
    }
}

/// Rounded toggle chip (usage dimensions, task filters).
struct Chip: View {
    let title: String
    let selected: Bool
    var height: CGFloat = 28
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).foregroundColor(selected ? Z.text : Z.body)
                .padding(.horizontal, height >= 28 ? 12 : 10).frame(height: height)
                .background(Capsule().fill(selected ? Z.selection : Color.clear))
                .overlay(Capsule().strokeBorder(selected ? Color.clear : Z.control))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct Segmented: View {
    let items: [String]
    let selected: Int
    var height: CGFloat = 26
    var fontSize: CGFloat = 12
    let pick: (Int) -> Void
    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                Button { pick(i) } label: {
                    Text(items[i]).font(.system(size: fontSize)).foregroundColor(i == selected ? Z.text : Z.body)
                        .padding(.horizontal, fontSize > 12 ? 12 : 10).frame(height: height)
                        .background(i == selected ? Z.selection : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Z.control))
    }
}

struct SquareButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundColor(Z.text)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Z.popover))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Z.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Page title with optional ‹ › and trailing controls.
struct Header<Trailing: View>: View {
    let title: String
    var prev: (() -> Void)?
    var next: (() -> Void)?
    let trailing: Trailing
    @EnvironmentObject private var app: AppState

    init(_ title: String, prev: (() -> Void)? = nil, next: (() -> Void)? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.prev = prev; self.next = next; self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            if let prev, let next {
                HStack(spacing: 6) {
                    SquareButton(symbol: "chevron.left", label: app.f.t("nav.prev"), action: prev)
                    SquareButton(symbol: "chevron.right", label: app.f.t("nav.next"), action: next)
                }
            }
            Text(title).font(.system(size: 24, weight: .bold)).foregroundColor(Z.text).lineLimit(1)
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension Header where Trailing == EmptyView {
    init(_ title: String, prev: (() -> Void)? = nil, next: (() -> Void)? = nil) {
        self.init(title, prev: prev, next: next) { EmptyView() }
    }
}

/// Main column of a window section: padding of the mockups, scrolls when live.
struct Page<Content: View>: View {
    var spacing: CGFloat = 20
    var insets = EdgeInsets(top: 24, leading: 32, bottom: 40, trailing: 32)
    @ViewBuilder let content: () -> Content
    var body: some View {
        Scrolling {
            VStack(alignment: .leading, spacing: spacing) { content() }
                .padding(insets)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// Coloured sentence with one bold fragment (forecasts).
struct Banner: View {
    let text: Emphasis
    let dot: Color
    let fill: Color
    let border: Color
    let ink: Color
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Dot(color: dot).padding(.top, 5)
            (Text(text.before) + Text(text.bold).bold().foregroundColor(.white) + Text(text.after))
                .font(.system(size: 13)).foregroundColor(ink).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(border))
    }

    static func amber(_ e: Emphasis) -> Banner {
        Banner(text: e, dot: Color(hex: Palette.fiveHour), fill: Color(hex: 0x2B2A24), border: Color(hex: 0x4A4330),
               ink: Color(hex: 0xEDE6D6))
    }

    static func blue(_ e: Emphasis) -> Banner {
        Banner(text: e, dot: Z.week, fill: Color(hex: 0x1E2633), border: Color(hex: 0x2F4363), ink: Color(hex: 0xDCE7F7))
    }
}

struct Legend: View {
    let color: Color
    let label: String
    var width: CGFloat = 14
    var height: CGFloat = 8
    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: width, height: height)
            Text(label)
        }
        .font(.system(size: 12)).foregroundColor(Z.secondary)
    }
}

struct Bar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 8
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2).fill(Z.barTrack)
                RoundedRectangle(cornerRadius: height / 2).fill(color).frame(width: g.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
    }
}

struct Divider1: View {
    var color = Z.divider
    var body: some View { Rectangle().fill(color).frame(height: 1) }
}

/// Text field that turns into plain text in snapshots.
struct Field: View {
    let placeholder: String
    @Binding var text: String
    var height: CGFloat = 34
    var fontSize: CGFloat = 13
    var fill = Z.sidebar
    var border = Z.control
    var radius: CGFloat = 8
    @Environment(\.isSnapshot) private var snapshot
    var body: some View {
        Group {
            if snapshot {
                Text(text.isEmpty ? placeholder : text).foregroundColor(text.isEmpty ? Z.muted : Z.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(placeholder, text: $text).textFieldStyle(.plain).foregroundColor(Z.text)
            }
        }
        .font(.system(size: fontSize))
        .padding(.horizontal, fontSize > 13 ? 12 : 10)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: radius).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(border))
    }
}

/// Left-to-right flow that wraps to the next line (chips, buttons, footers).
struct Flow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (v, f) in zip(subviews, arrange(bounds.width, subviews).frames) {
            v.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
        }
    }

    func arrange(_ width: CGFloat, _ subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            var s = v.sizeThatFits(.unspecified)
            if s.width > width { s = v.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0 && x + s.width > width { x = 0; y += rowH + lineSpacing; rowH = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: s))
            maxX = max(maxX, x + s.width)
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return (frames, CGSize(width: maxX, height: y + rowH))
    }
}

/// Grey diagonal stripes: time already logged in Jira.
struct Hatch: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0x2E2E33)))
            var p = Path()
            var x = -size.height
            while x < size.width {
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 8.5
            }
            ctx.stroke(p, with: .color(Color(hex: 0x4A4A52)), lineWidth: 3)
        }
    }
}

/// Hour labels spread edge to edge under a track.
struct Ticks: View {
    let labels: [String]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(labels.indices, id: \.self) { i in
                Text(labels[i])
                if i < labels.count - 1 { Spacer(minLength: 0) }
            }
        }
        .font(mono(11)).foregroundColor(Z.muted)
    }
}
