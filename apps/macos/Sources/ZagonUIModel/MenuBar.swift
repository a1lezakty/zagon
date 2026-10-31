import Foundation

/// The status item. Both AIs with a current reading (or Claude under `Limits.claudeHint`): a ring-in-ring each, Claude
/// left, Codex right (outer the week, inner 5 hours, the 5-hour number inside). One AI, or none: its pair of rings,
/// 5 hours left and the week right.
public struct MenuBarVM: Sendable, Equatable {
    public struct AI: Sendable, Equatable {
        public var tool: Tool
        /// Used percent; nil = no current reading.
        public var five: Int?
        public var week: Int?
        public var colors: RingColors
        public init(tool: Tool, five: Int?, week: Int?, colors: RingColors) {
            self.tool = tool; self.five = five; self.week = week; self.colors = colors
        }
    }

    public var ais: [AI]
    /// A ring-in-ring per AI instead of one pair of rings.
    public var nested: Bool { ais.count > 1 }
    /// Something is red: digits from 80 % (in a ring-in-ring only the 5-hour ones show), a ring from 95 %.
    public var alarm: Bool {
        ais.contains { max($0.five ?? 0, nested ? 0 : $0.week ?? 0) >= 80 || max($0.five ?? 0, $0.week ?? 0) >= 95 }
    }
    public var tip: String
    /// What VoiceOver reads for the status item.
    public var spoken: String

    public init(_ limits: Limits, colors: (Tool) -> RingColors = RingColors.standard, _ f: Fmt) {
        let now = f.now, current = limits.tools(at: now), shown = limits.shown(at: now)
        let known = shown.fiveHour ?? shown.week
        let hint = limits.claudeHint(at: now) ? limits.claudeHintLine(f) : nil
        // Nothing current: named after the first AI with any window (`shown` mixes them window by window).
        let anyAI = Tool.allCases.first { (limits[$0].fiveHour ?? limits[$0].week) != nil }
        let tools = current.count > 1 ? current : [current.first ?? anyAI ?? .claude]
        let ais = tools.map { t in
            let w = current.count > 1 ? limits[t] : shown
            return AI(tool: t, five: w.fiveHour?.pct(at: now), week: w.week?.pct(at: now), colors: colors(t))
        }
        self.init(ais: ais, known: known != nil || hint != nil, hint: hint, f)
    }

    /// Sample values (settings preview, snapshots).
    public init(ais: [AI], _ f: Fmt) { self.init(ais: ais, known: true, f) }

    private init(ais: [AI], known: Bool, hint: String? = nil, _ f: Fmt) {
        self.ais = ais
        let pct = { (p: Int?) in p.map { f.t("num.pct", "\($0)") } ?? "–" }
        let used = { (p: Int?) in p.map { f.t("limit.usedPct", f.t("num.pct", "\($0)")) } ?? f.t("limit.noData") }
        guard known else {
            tip = f.t("menubar.tip", "–", "–")
            spoken = "Zagon: " + f.t("limit.noData")
            return
        }
        tip = ais.map { f.t("menubar.tip.ai", $0.tool.name, pct($0.five), pct($0.week)) }.joined(separator: " · ")
        spoken = "Zagon: " + ais.map { f.t("menubar.spoken.ai", $0.tool.name, used($0.five), used($0.week)) }
            .joined(separator: "; ")
        // Claude without readings: where they come from (`Limits.claudeHint`).
        if let hint {
            tip += "\n" + hint
            spoken += ". " + hint
        }
    }
}

extension Limits {
    /// Under `claudeHint`: where Claude's limits come from. The wrapper setting when the script is there, else the
    /// terminal.
    public func claudeHintLine(_ f: Fmt) -> String {
        claudeWrapper.map { f.t("limit.hint.wrapper", $0) } ?? f.t("limit.hint.terminal")
    }

    /// The line for the editor's settings.json that "Copy setting" gives.
    public var claudeSetting: String? {
        claudeWrapper.map { p in
            let json = p.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"claudeCode.claudeProcessWrapper\": \"\(json)\""
        }
    }
}

/// The status item's picture, drawn only when what it shows changes: timers and events call `update` (it reads the
/// limits), the menu bar label only takes `image`. Both scales go into one picture, so the screen is not part of it.
@MainActor
public final class StatusIcon<Image> {
    public struct Look: Equatable, Sendable {
        public var vm: MenuBarVM
        public var mono: Bool
        /// The bar is dark: a picture that is not a template draws its own text colour.
        public var dark: Bool
    }

    public private(set) var look: Look?
    public private(set) var image: Image?
    private let limits: @MainActor () -> Limits
    private let draw: @MainActor (Look) -> Image?

    public init(limits: @escaping @MainActor () -> Limits, draw: @escaping @MainActor (Look) -> Image?) {
        self.limits = limits; self.draw = draw
    }

    /// Reads the limits and draws if the picture would differ; a failed drawing (nil) is tried again next time. True
    /// when `image` changed.
    @discardableResult
    public func update(colors: (Tool) -> RingColors, mono: Bool, dark: Bool, _ f: Fmt) -> Bool {
        let next = Look(vm: MenuBarVM(limits(), colors: colors, f), mono: mono, dark: dark)
        guard next != look, let drawn = draw(next) else { return false }
        look = next
        image = drawn
        return true
    }
}
