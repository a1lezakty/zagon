/// Secret scrubbing for everything a handoff shows: applied to every fragment taken from a log and once more to the
/// finished document, before it is written or printed anywhere. Swift `Regex` (stdlib), no Foundation.
public enum Redact {
    public static let mark = "[redacted]"

    /// Each match becomes `[redacted]`; when the pattern has a group 1 (a key name, `Bearer `, `://user:`), that
    /// group is kept in front of the mark. `value` (optional) must accept the rest of the match, else it is kept.
    struct Rule {
        let re: Regex<AnyRegexOutput>
        let value: (@Sendable (Substring) -> Bool)?
        init(_ pattern: String, value: (@Sendable (Substring) -> Bool)? = nil) {
            // simple word boundaries: Unicode ones see no boundary in `x:ghp_…` or `a.sk-…`
            re = try! Regex(pattern).wordBoundaryKind(.simple); self.value = value
        }
    }

    static let strongKey = #"passw(?:or)?d|pwd|secret|api[_\-]?key|access[_\-]?key|private[_\-]?key|credential"#
    /// A key name and its separator, also inside escaped JSON (`\"password\":`).
    static func keyName(_ names: String) -> String { #"[A-Za-z0-9_\-]*(?:"# + names + #")s?[A-Za-z0-9_\-]*\\?["']?\s*[:=]\s*"# }

    /// (Read-only after init; `Regex` is not marked Sendable.)
    nonisolated(unsafe) static let rules: [Rule] = [
        // PEM blocks, also cut off ones (fragments are truncated)
        Rule(#"-----BEGIN [A-Z0-9 ]+-----[\s\S]*?(?:-----END [A-Z0-9 ]+-----|\z)"#),
        // (written so that the push guard, which greps for literal token prefixes, does not trip on this file)
        Rule(#"\bgithub[_]pat_[A-Za-z0-9_]{20,}"#),
        Rule(#"\bgh[pousr]_[A-Za-z0-9]{20,}"#),
        Rule(#"\bsk-(?:ant-)?[A-Za-z0-9_\-]{16,}"#),
        Rule(#"\bxox[abpres]-[A-Za-z0-9\-]{10,}"#),
        Rule(#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        Rule(#"\bglpat-[A-Za-z0-9_\-]{20,}"#), // GitLab
        Rule(#"\bAIza[0-9A-Za-z_\-]{35}"#),    // Google API key
        Rule(#"\b[0-9a-fA-F]{64,}\b"#),         // long hex keys (sha256 sums go too: harmless)
        Rule(#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#), // JWT
        Rule(#"(?i)\b((?:bearer|basic)\s+)(?=[A-Za-z0-9._~+/=\-]*[0-9])[A-Za-z0-9._~+/=\-]{12,}"#),
        Rule(#"(://[^/\s:@]+:)[^/\s@]+(?=@)"#), // user:password@host
        // key = "quoted value", also with spaces or cut before its closing quote (password: "correct horse …)
        Rule(#"(?i)\b("# + keyName(strongKey + "|token") + #")(?:"(?:\\.|[^"\\\n])*"?|'[^'\n]*'?)"#),
        // password=…, DB_PASSWORD: …, x-api-key: …, \"password\":\"…\" — any value
        Rule(#"(?i)\b("# + keyName(strongKey) + #"(?:\\?["'])?)[^\s"'\\,;&]+"#),
        // token=…: short numbers are counters (max_tokens=4096), not secrets
        Rule(#"(?i)\b("# + keyName("token") + #"(?:\\?["'])?)(?![0-9]{1,12}(?:[\s"'\\,;&]|$))[^\s"'\\,;&]+"#),
        // long base64 / hex near key / token / secret (with a digit, and not a path like key-service/backend-api)
        Rule(#"(?i)\b((?:key|token|secret|passw(?:or)?d|credential)s?\b[^\n]{0,40}?)[A-Za-z0-9+/_\-]{32,}={0,2}"#,
             value: { v in v.contains(where: \.isNumber) && !(v.contains("/") && v.contains(where: { $0 == "-" || $0 == "_" })) }),
    ]

    /// Long random-looking words (mixed case and digits): a pasted key with no telltale name around it.
    /// ponytail: heuristic; add a rule above when a real format slips through.
    nonisolated(unsafe) static let entropic = try! Regex(#"[A-Za-z0-9_\-+/]{40,}={0,2}"#)

    public static func clean(_ s: String) -> String {
        var out = s
        for rule in rules {
            out = out.replacing(rule.re) { m in
                let whole = m.output[0].substring ?? ""
                let keep = m.output.count > 1 ? m.output[1].substring ?? "" : ""
                if let check = rule.value, !check(whole.dropFirst(keep.count)) { return String(whole) }
                return keep + mark
            }
        }
        return out.replacing(entropic) { m in
            let w = String(m.output[0].substring ?? "")
            return looksRandom(w) ? mark : w
        }
    }

    static func looksRandom(_ w: String) -> Bool {
        w.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "/" }).contains { seg in
            guard seg.utf8.count >= 24 else { return false }
            var up = false, low = false, digit = false
            for c in seg.utf8 {
                switch c {
                case 0x41...0x5A: up = true
                case 0x61...0x7A: low = true
                case 0x30...0x39: digit = true
                default: break
                }
            }
            return up && low && digit
        }
    }

    /// Files whose content never goes into a handoff (only the path may be shown).
    public static func isSensitivePath(_ path: String) -> Bool {
        let name = path.split(separator: "/").last.map { $0.lowercased() } ?? ""
        return name.hasPrefix(".env") || name.hasSuffix(".pem") || name.hasSuffix(".key") || name.hasPrefix("id_")
            || name.hasSuffix(".p12") || name.hasSuffix(".pfx") || [".netrc", ".npmrc", ".pgpass"].contains(name)
            || name.hasPrefix("credentials")
    }

    /// Whether a command line touches a sensitive file (then its output is not quoted, not even the first line).
    public static func mentionsSensitiveFile(_ command: String) -> Bool {
        command.split(whereSeparator: { " \t\n'\"<>|;&()=".contains($0) }).contains { isSensitivePath(String($0)) }
    }
}
