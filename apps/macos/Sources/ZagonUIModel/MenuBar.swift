import Foundation

/// The status item. Both AIs with a current reading: a ring-in-ring each, Claude left, Codex right (outer the week,
/// inner 5 hours, the 5-hour number inside). One AI, or none: its pair of rings, 5 hours left and the week right.
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
        // Nothing current: named after the first AI with any window (`shown` mixes them window by window).
        let anyAI = Tool.allCases.first { (limits[$0].fiveHour ?? limits[$0].week) != nil }
        let tools = current.count > 1 ? current : [current.first ?? anyAI ?? .claude]
        let ais = tools.map { t in
            let w = current.count > 1 ? limits[t] : shown
            return AI(tool: t, five: w.fiveHour?.pct(at: now), week: w.week?.pct(at: now), colors: colors(t))
        }
        self.init(ais: ais, known: known != nil, f)
    }

    /// Sample values (settings preview, snapshots).
    public init(ais: [AI], _ f: Fmt) { self.init(ais: ais, known: true, f) }

    private init(ais: [AI], known: Bool, _ f: Fmt) {
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
    }
}
