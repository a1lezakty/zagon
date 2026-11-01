#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// Codex CLI rollouts: `<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl` and `archived_sessions/`; a cold
// one may be `….jsonl.zst` instead (the same bytes, one zstd stream; Codex turns it back into `.jsonl` to append).
// Each line is `{"timestamp": ISO-8601, "type": <item>, "payload": {...}}` (serde: fields in this order, payload
// tag `type` first), which lets most lines be classified from their first few hundred bytes without a JSON parse.

public enum CodexSource {
    /// `$CODEX_HOME`, else `~/.codex`.
    public static func defaultHome() -> String {
        if let h = Sys.env("CODEX_HOME"), !h.isEmpty { return h }
        return (Sys.env("HOME") ?? "/") + "/.codex"
    }

    /// Live and archived rollouts.
    public static func specs(codexHome: String = defaultHome()) -> [SourceSpec] {
        ["sessions", "archived_sessions"].map { dir in
            SourceSpec(tool: .codex, root: codexHome + "/" + dir, accepts: isRollout) { _, rel, state in
                CodexParser(relativePath: rel, state: state)
            }
        }
    }

    @Sendable static func isRollout(_ rel: String) -> Bool {
        let name = rel.split(separator: "/").last ?? ""
        return name.hasPrefix("rollout-") && (name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst"))
    }
}

/// Parser of one rollout file. Usage comes from `token_count` events, as increments of `total_token_usage`
/// (`last_token_usage` repeats on duplicate events and misses requests that share one event).
public struct CodexParser: LineParser {
    struct State: Codable, Equatable {
        /// Native id of the session the file's records go to (the parent thread for sub-agents).
        var sid: String
        /// Sub-agent label (`<child thread id>`), "" for a main thread.
        var agent = ""
        var metaSeen = false
        var model: String?
        /// Last `total_token_usage`: input, cached, cache_write, output, reasoning, total.
        var total: [Int]?
        /// Which record kind carries typed messages in this turn (`user_message` or `item_completed`); the other
        /// kind is ignored so a version writing both does not count a message twice.
        var userKind: String?
        /// Working directory of the current turn (`session_meta.cwd`, then `turn_context.cwd`).
        var cwd: String?
    }

    var st: State
    /// Last emitted limit per window (not persisted: losing it only costs one extra snapshot).
    var lastLimit: [String: LimitSnapshot] = [:]

    public init(relativePath: String, state: String?) {
        if let s = state, let v = try? JSONDecoder().decode(State.self, from: Data(s.utf8)) {
            st = v
        } else {
            st = State(sid: Self.idFromName(relativePath))
        }
    }

    /// `rollout-2026-01-08T19-18-57-<uuid>.jsonl` (or `.jsonl.zst`) → `<uuid>`.
    static func idFromName(_ rel: String) -> String {
        var name = rel.split(separator: "/").last.map(String.init) ?? rel
        if name.hasSuffix(".zst") { name.removeLast(4) }
        let base = name.hasSuffix(".jsonl") ? String(name.dropLast(6)) : name
        return base.count >= 36 ? String(base.suffix(36)) : base
    }

    public func saveState() -> String? {
        (try? JSONEncoder().encode(st)).map { String(decoding: $0, as: UTF8.self) }
    }

    var sessionId: String { "codex:" + st.sid }
    var isSub: Bool { !st.agent.isEmpty }

    public mutating func parse(line: UnsafeRawBufferPointer, into out: inout ParseOutput) {
        guard let p = Prefix(line) else { return full(line, &out) }
        switch (p.type, p.ptype) {
        case ("response_item", let t?) where !Self.toolNames.keys.contains(t):
            switch (p.role, t) {
            case (nil, "message"): full(line, &out)
            case ("assistant", _), (nil, _): out.events.append(ActivityEvent(sessionId: sessionId, ts: p.ts, cwd: st.cwd))
            case (_?, "message"): break // user / developer: injected context, not typed by the human
            default: full(line, &out) // a role that may belong to a nested object: let the JSON decide
            }
        case ("event_msg", "item_completed"):
            if p.itemType == "UserMessage" || p.itemType == nil { full(line, &out) }
        case ("event_msg", let t?) where Self.events.contains(t): full(line, &out)
        case ("event_msg", nil), ("response_item", _), ("session_meta", _), ("turn_context", _): full(line, &out)
        case (let t, _) where !Self.knownTypes.contains(t): full(line, &out) // layout drift: let the JSON decide
        default: break
        }
    }

    /// Top-level item types the fast path classifies; anything else goes through a full parse.
    static let knownTypes: Set<String> = ["response_item", "event_msg", "session_meta", "turn_context", "compacted",
                                          "world_state", "token_usage_record"]

    static let events: Set<String> = ["token_count", "task_started", "turn_started", "task_complete", "turn_complete",
                                      "turn_aborted", "user_message"]
    /// Response items that are tool calls; `nil` = take `payload.name`.
    static let toolNames: [String: String?] = [
        "function_call": nil, "custom_tool_call": nil, "web_search_call": "web_search",
        "local_shell_call": "local_shell", "tool_search_call": "tool_search",
    ]

    mutating func full(_ line: UnsafeRawBufferPointer, _ out: inout ParseOutput) {
        guard let o = JValue.parse(Array(line)), let type = o["type"]?.string,
              let ts = o["timestamp"]?.string.flatMap(isoTime) else {
            out.badLines += 1; return
        }
        let p = o["payload"] ?? .object([])
        let ptype = p["type"]?.string
        switch type {
        case "session_meta": sessionMeta(p, &out)
        case "turn_context":
            if let c = p["cwd"]?.string { st.cwd = c }
            guard let m = p["model"]?.string, m != st.model else { return }
            st.model = m
            if !isSub { out.meta.append(SessionMeta(id: sessionId, tool: .codex, model: m)) }
        case "response_item":
            guard (p["role"]?.string ?? "assistant") == "assistant" else { return } // injected context
            out.events.append(ActivityEvent(sessionId: sessionId, ts: ts, cwd: st.cwd))
            if let t = ptype, let fixed = Self.toolNames[t], let name = fixed ?? p["name"]?.string {
                out.tools.append(ToolCall(sessionId: sessionId, ts: ts, name: name, callId: p["call_id"]?.string))
            }
        case "event_msg":
            switch ptype {
            case "token_count": tokenCount(p, ts, &out)
            case "task_started", "turn_started":
                st.userKind = nil // per turn: a session resumed by another CLI version may switch kinds
            case "task_complete", "turn_complete", "turn_aborted":
                out.events.append(ActivityEvent(sessionId: sessionId, ts: ts, cwd: st.cwd))
            case "user_message":
                // old CLIs also tagged injected instructions / environment context with a `kind`
                guard (p["kind"]?.string ?? "plain") == "plain" else { return }
                userMessage("user_message", p["message"]?.string, ts, &out)
            case "item_completed":
                guard let item = p["item"], item["type"]?.string == "UserMessage" else { return }
                let parts = (item["content"]?.array ?? []).compactMap { $0["text"]?.string }
                userMessage("item_completed", parts.joined(separator: "\n"), ts, &out)
            default: break
            }
        default: break
        }
    }

    mutating func sessionMeta(_ p: JValue, _ out: inout ParseOutput) {
        guard !st.metaSeen, let id = p["id"]?.string else { return }
        st.metaSeen = true
        if let c = p["cwd"]?.string { st.cwd = c }
        let sub = p["source"]?["subagent"] != nil || p["thread_source"]?.string == "subagent"
        if sub { // counted under the parent; without one (older review / compact agents) under its own id
            st.sid = p["parent_thread_id"]?.string ?? p["forked_from_id"]?.string ?? id; st.agent = id
            return
        }
        st.sid = id
        let cwd = p["cwd"]?.string
        let branch = p["git"]?["branch"]?.string
        out.meta.append(SessionMeta(id: sessionId, tool: .codex, project: cwd.map(ClaudeParser.project), cwd: cwd,
                                    gitBranch: branch))
    }

    mutating func userMessage(_ kind: String, _ text: String?, _ ts: Timestamp, _ out: inout ParseOutput) {
        guard !isSub else { return } // sub-agent prompts are generated, not typed
        if st.userKind == nil { st.userKind = kind }
        guard st.userKind == kind else { return }
        out.userMessages.append(UserMessage(sessionId: sessionId, ts: ts, text: text, cwd: st.cwd))
    }

    static let usageKeys = ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens",
                            "reasoning_output_tokens", "total_tokens"]
    static func usage(_ v: JValue?) -> [Int]? {
        guard let d = v, case .object = d else { return nil }
        return usageKeys.map { int(d[$0]) ?? 0 }
    }

    mutating func tokenCount(_ p: JValue, _ ts: Timestamp, _ out: inout ParseOutput) {
        if let rl = p["rate_limits"], case .object = rl { limits(rl, ts, &out) }
        guard let info = p["info"], case .object = info else { return }
        let last = Self.usage(info["last_token_usage"])
        var inc: [Int]?
        if let total = Self.usage(info["total_token_usage"]) {
            if let prev = st.total {
                if total == prev { return } // duplicate event (or a post-compaction context estimate)
                let d = zip(total, prev).map { $0 - $1 }
                inc = d.allSatisfy { $0 >= 0 } ? d : last // counter reset: trust the per-request numbers
            } else {
                inc = last ?? total // first event: totals may include history inherited from a fork
            }
            st.total = total
        } else {
            inc = last // very old versions: no totals to detect duplicates with
        }
        guard let u = inc, u[0] + u[3] + u[2] > 0 else { return }
        // OpenAI semantics: cached (and cache-write) tokens are part of input_tokens, reasoning part of output.
        out.usage.append(UsageRecord(sessionId: sessionId, agent: st.agent, ts: ts, model: st.model ?? "unknown",
                                     input: max(0, u[0] - u[1] - u[2]), output: u[3], cacheRead: u[1], cacheWrite: u[2],
                                     cwd: st.cwd))
    }

    mutating func limits(_ rl: JValue, _ ts: Timestamp, _ out: inout ParseOutput) {
        let id = rl["limit_id"]?.string
        for key in ["primary", "secondary"] {
            guard let w = rl[key], let pct = Self.double(w["used_percent"]) else { continue }
            let window = id == nil || id == "codex" ? key : "\(id!):\(key)"
            let resets = Self.double(w["resets_at"]) ?? Self.double(w["resets_in_seconds"]).map { ts + $0 }
            let s = LimitSnapshot(tool: .codex, window: window, usedPct: pct, resetsAt: resets,
                                  windowMinutes: Self.int(w["window_minutes"]), ts: ts)
            if let l = lastLimit[window], l.usedPct == s.usedPct, l.resetsAt == s.resetsAt,
               l.windowMinutes == s.windowMinutes, ts - l.ts < 60 { continue }
            lastLimit[window] = s
            out.limits.append(s)
        }
    }

    static func double(_ v: JValue?) -> Double? { v?.double.flatMap { $0.isFinite ? $0 : nil } }
    /// Token counts and window sizes: anything outside 0...2^50 (or not finite) is unusable, never a trap.
    static func int(_ v: JValue?) -> Int? { double(v).flatMap { (0...0x1p50).contains($0) ? Int($0) : nil } }
}

/// `timestamp`, item `type`, payload `type`, message `role` and `item.type` read from the head of a line.
fileprivate struct Prefix {
    var ts: Timestamp
    var type: String
    var ptype: String?
    var role: String?
    var itemType: String?

    init?(_ b: UnsafeRawBufferPointer) {
        let lim = min(b.count, 400)
        guard let (t, e1) = Prefix.str(b, "\"timestamp\":", 0, lim), let ts = isoTime(t),
              let (type, e2) = Prefix.str(b, "\"type\":", e1, lim) else { return nil }
        self.ts = ts; self.type = type
        let p = Prefix.str(b, "\"type\":", e2, lim)
        ptype = p?.0
        if let e3 = p?.1 {
            role = Prefix.str(b, "\"role\":", e3, lim)?.0
            itemType = Prefix.str(b, "\"item\":{\"type\":", e3, lim)?.0
        }
    }

    /// The string value after the first `key` in `b[from..<lim]`; nil if absent, escaped or cut off.
    static func str(_ b: UnsafeRawBufferPointer, _ key: StaticString, _ from: Int, _ lim: Int) -> (String, Int)? {
        let k = UnsafeRawBufferPointer(start: key.utf8Start, count: key.utf8CodeUnitCount)
        var i = from
        while i + k.count < lim {
            if b[i] == k[0], (1..<k.count).allSatisfy({ b[i + $0] == k[$0] }) {
                var j = i + k.count
                while j < lim, b[j] == 0x20 { j += 1 }
                guard j < lim, b[j] == 0x22 else { return nil }
                let s = j + 1
                var e = s
                while e < lim, b[e] != 0x22 { if b[e] == 0x5C { return nil }; e += 1 }
                guard e < lim else { return nil }
                return (String(decoding: UnsafeRawBufferPointer(rebasing: b[s..<e]), as: UTF8.self), e + 1)
            }
            i += 1
        }
        return nil
    }
}

/// `2026-01-08T19:18:57.977Z` (or with a `±HH:MM` offset) → epoch seconds.
fileprivate func isoTime(_ s: String) -> Timestamp? {
    let u = Array(s.utf8)
    guard u.count >= 19, u[4] == 0x2D, u[7] == 0x2D, u[10] == 0x54 || u[10] == 0x20, u[13] == 0x3A, u[16] == 0x3A
    else { return nil }
    func n(_ a: Int, _ b: Int) -> Int? {
        var v = 0
        for i in a..<b { guard u[i] >= 0x30, u[i] <= 0x39 else { return nil }; v = v * 10 + Int(u[i] - 0x30) }
        return v
    }
    guard var y = n(0, 4), let m = n(5, 7), let d = n(8, 10), let hh = n(11, 13), let mm = n(14, 16),
          let ss = n(17, 19), (1...12).contains(m), (1...31).contains(d) else { return nil }
    var i = 19, frac = 0.0
    if i < u.count, u[i] == 0x2E {
        i += 1
        var scale = 0.1
        while i < u.count, u[i] >= 0x30, u[i] <= 0x39 { frac += Double(u[i] - 0x30) * scale; scale /= 10; i += 1 }
    }
    var offset = 0
    if i < u.count, u[i] == 0x2B || u[i] == 0x2D, u.count >= i + 6, let oh = n(i + 1, i + 3), let om = n(i + 4, i + 6) {
        offset = (oh * 3600 + om * 60) * (u[i] == 0x2B ? 1 : -1)
    }
    // days from civil (H. Hinnant)
    y -= m <= 2 ? 1 : 0
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
    let days = era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468
    return Double(days * 86400 + hh * 3600 + mm * 60 + ss - offset) + frac
}
