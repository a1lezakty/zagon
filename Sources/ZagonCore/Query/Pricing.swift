/// API list prices, used only to show "$ at API prices" next to token counts (subscriptions are billed differently).
public enum Pricing {
    /// USD per million tokens: input, output, cache read, cache write; nil = unknown model (counted as $0).
    /// ponytail: by model family, current list prices; a dated table when old models' prices matter.
    public static func rates(_ model: String) -> (input: Double, output: Double, cacheRead: Double, cacheWrite: Double)? {
        let m = model.lowercased()
        if m.contains("opus") { return (5, 25, 0.5, 6.25) }
        if m.contains("sonnet") { return (3, 15, 0.3, 3.75) }
        if m.contains("haiku") { return (1, 5, 0.1, 1.25) }
        if m.hasPrefix("gpt-5") || m.contains("codex") { return (1.25, 10, 0.125, 0) }
        return nil
    }

    public static func cost(model: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> Double {
        guard let r = rates(model) else { return 0 }
        return (Double(input) * r.input + Double(output) * r.output + Double(cacheRead) * r.cacheRead
                + Double(cacheWrite) * r.cacheWrite) / 1_000_000
    }

    public static func cost(model: String, _ t: TokenTotals) -> Double {
        cost(model: model, input: t.input, output: t.output, cacheRead: t.cacheRead, cacheWrite: t.cacheWrite)
    }
}
