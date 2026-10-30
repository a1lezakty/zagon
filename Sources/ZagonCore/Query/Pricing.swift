/// API list prices, used only to show "$ at API prices" next to token counts (subscriptions are billed differently).
public enum Pricing {
    /// USD per million tokens: input, output, cache read, cache write kept 5 minutes (OpenAI: 30 minutes) and kept an
    /// hour (OpenAI: 12 hours).
    public typealias Rates = (input: Double, output: Double, cacheRead: Double, cacheWrite: Double, cacheWrite1h: Double)

    /// Anthropic: cache writes are 1.25x input (5 minutes) and 2x input (1 hour) for every model.
    static func claude(_ input: Double, _ output: Double, _ cacheRead: Double) -> Rates {
        (input, output, cacheRead, input * 1.25, input * 2)
    }

    /// OpenAI: most models do not charge cache writes; where they do, the 12-hour write is twice the 30-minute one.
    static func openai(_ input: Double, _ output: Double, _ cacheRead: Double, write: Double = 0) -> Rates {
        (input, output, cacheRead, write, write * 2)
    }

    /// By model id without its date. Checked 2026-10-30 on https://platform.claude.com/docs/en/about-claude/pricing and
    /// https://developers.openai.com/api/docs/pricing; models shut down since are priced from their own pages,
    /// https://developers.openai.com/api/docs/models/<model>.
    // ponytail: one price per model; Haiku 5.5 prompts over 100K tokens (5x) and OpenAI prompts over 272K (about 2x)
    // are priced per request, which hourly totals do not keep.
    static let table: [String: Rates] = [
        "claude-fable-5-1": claude(10, 50, 0.25), "claude-mythos-5-1": claude(10, 50, 0.25),
        "claude-fable-5": claude(10, 50, 1), "claude-mythos-5": claude(10, 50, 1),
        "claude-opus-5-5": claude(4, 20, 0.2),
        "claude-opus-5": claude(5, 25, 0.5), "claude-opus-4-8": claude(5, 25, 0.5), "claude-opus-4-7": claude(5, 25, 0.5),
        "claude-opus-4-6": claude(5, 25, 0.5), "claude-opus-4-5": claude(5, 25, 0.5),
        "claude-opus-4-1": claude(15, 75, 1.5), "claude-opus-4": claude(15, 75, 1.5), "claude-opus-4-0": claude(15, 75, 1.5),
        "claude-sonnet-5-5": claude(2, 10, 0.1), "claude-sonnet-5": claude(2, 10, 0.2),
        "claude-sonnet-4-6": claude(3, 15, 0.3), "claude-sonnet-4-5": claude(3, 15, 0.3), "claude-sonnet-4": claude(3, 15, 0.3),
        "claude-sonnet-4-0": claude(3, 15, 0.3),
        "claude-haiku-5-5": claude(0.1, 0.5, 0.01), "claude-haiku-4-5": claude(1, 5, 0.1),
        "claude-3-5-haiku": claude(0.8, 4, 0.08),
        "gpt-5.6-sol": openai(4, 20, 0.4, write: 5), "gpt-5.6-terra": openai(2, 12, 0.2, write: 2.5),
        "gpt-5.6-luna": openai(0.2, 1.2, 0.02, write: 0.25),
        "gpt-5.5": openai(5, 30, 0.5),
        "gpt-5.4": openai(2.5, 15, 0.25), "gpt-5.4-mini": openai(0.75, 4.5, 0.075), "gpt-5.4-nano": openai(0.2, 1.25, 0.02),
        "gpt-5.3-codex": openai(1.75, 14, 0.175), "gpt-5.2": openai(1.75, 14, 0.175), "gpt-5.2-codex": openai(1.75, 14, 0.175),
        "gpt-5.1": openai(1.25, 10, 0.125), "gpt-5.1-codex": openai(1.25, 10, 0.125),
        "gpt-5.1-codex-max": openai(1.25, 10, 0.125), "gpt-5.1-codex-mini": openai(0.25, 2, 0.025),
        "gpt-5": openai(1.25, 10, 0.125), "gpt-5-codex": openai(1.25, 10, 0.125),
        "gpt-5-mini": openai(0.25, 2, 0.025), "gpt-5-nano": openai(0.05, 0.4, 0.005),
        "codex-mini-latest": openai(1.5, 6, 0.375),
    ]

    /// nil = no known price (shown as "$ ?", never as $0).
    public static func rates(_ model: String) -> Rates? { table[key(model)] }

    /// `model` as the table keys it: lower case, no cloud prefix (`us.anthropic.`), suffix (`@…`, `[1m]`, `-v1:0`) or date
    /// (`-20250805`, `-2025-08-07`).
    static func key(_ model: String) -> String {
        var m = Substring(model.lowercased())
        if let r = m.firstRange(of: "claude-") { m = m[r.lowerBound...] }
        if let i = m.firstIndex(where: { $0 == "@" || $0 == "[" || $0 == ":" }) { m = m[..<i] }
        if m.hasSuffix("-v1") { m = m.dropLast(3) }
        let parts = m.split(separator: "-", omittingEmptySubsequences: false)
        func digits(_ s: Substring, _ n: Int) -> Bool { s.count == n && s.allSatisfy(\.isNumber) }
        if let last = parts.last, digits(last, 8) { return parts.dropLast().joined(separator: "-") }
        let n = parts.count
        if n > 3, digits(parts[n - 3], 4), digits(parts[n - 2], 2), digits(parts[n - 1], 2) {
            return parts.dropLast(3).joined(separator: "-")
        }
        return String(m)
    }

    /// `cacheWrite` is all cache writes, `cacheWrite1h` the part of them kept for an hour. 0 for a model with no price:
    /// callers count its tokens as unpriced (`Pricing.rates` nil).
    public static func cost(model: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int, cacheWrite1h: Int = 0) -> Double {
        guard let r = rates(model) else { return 0 }
        return (Double(input) * r.input + Double(output) * r.output + Double(cacheRead) * r.cacheRead
                + Double(max(0, cacheWrite - cacheWrite1h)) * r.cacheWrite + Double(cacheWrite1h) * r.cacheWrite1h) / 1_000_000
    }

    public static func cost(model: String, _ t: TokenTotals) -> Double {
        cost(model: model, input: t.input, output: t.output, cacheRead: t.cacheRead, cacheWrite: t.cacheWrite,
             cacheWrite1h: t.cacheWrite1h)
    }

    /// Tokens of `t` left out of `cost` because `model` has no price.
    public static func unpriced(model: String, _ t: TokenTotals) -> Int { rates(model) == nil ? t.total : 0 }
}
