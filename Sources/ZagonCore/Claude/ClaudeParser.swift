#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Claude Code transcripts: `~/.claude/projects/<project>/<session>.jsonl` (main thread) and
/// `<project>/<session>/subagents/**/agent-*.jsonl` (sub-agents, counted under the parent session).
public enum ClaudeSource {
    public static func spec(root: String, indexPrompts: Bool = true) -> SourceSpec {
        SourceSpec(tool: .claude, root: root, accepts: { layout($0) != nil }, makeParser: { _, rel, _ in
            let l = layout(rel)!
            return ClaudeParser(sessionId: "claude:" + l.session, agent: l.agent, indexPrompts: indexPrompts)
        })
    }

    /// (session, agent) from a path relative to the projects dir; nil for files that are not transcripts.
    static func layout(_ rel: String) -> (session: String, agent: String)? {
        guard rel.hasSuffix(".jsonl") else { return nil }
        let parts = rel.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count == 2 { return (String(parts[1].dropLast(6)), "") }
        if parts.count >= 4, parts[2] == "subagents", parts.last!.hasPrefix("agent-") {
            return (String(parts[1]), String(parts.last!.dropLast(6)))
        }
        return nil
    }
}

/// One transcript record, only the fields Zagon reads. Filled by the byte scanner or by JSONDecoder (fallback).
struct ClaudeRecord: Decodable {
    var type: String?
    var timestamp: String?
    var cwd: String?
    var gitBranch: String?
    var isMeta: Bool?
    var isSidechain: Bool?
    var isCompactSummary: Bool?
    var isVisibleInTranscriptOnly: Bool?
    var turnOrigin: String?
    /// `origin.kind`: `human`, `channel` (Telegram and other channel plugins), `peer`, `task-notification`…
    var origin: Origin?
    var customTitle: String?
    var agentName: String?
    var aiTitle: String?
    var message: Message?

    struct Origin: Decodable {
        var kind: String?
        init(kind: String?) { self.kind = kind }
        // lenient: another shape of `origin` must not make the whole record unreadable
        init(from d: Decoder) throws { kind = try? d.container(keyedBy: K.self).decode(String.self, forKey: .kind) }
        enum K: String, CodingKey { case kind }
    }
    struct Usage: Decodable {
        var input_tokens: Int?, output_tokens: Int?, cache_read_input_tokens: Int?, cache_creation_input_tokens: Int?
    }
    struct Block: Decodable { var type: String?; var name: String?; var id: String?; var text: String? }
    struct Message: Decodable {
        var id: String?
        var model: String?
        var usage: Usage?
        var text: String?      // content as a plain string
        var blocks: [Block]?   // content as blocks
        enum CodingKeys: String, CodingKey { case id, model, usage, content }
        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = try? c.decodeIfPresent(String.self, forKey: .id)
            model = try? c.decodeIfPresent(String.self, forKey: .model)
            usage = try? c.decodeIfPresent(Usage.self, forKey: .usage)
            if let s = try? c.decodeIfPresent(String.self, forKey: .content) { text = s }
            else { blocks = try? c.decodeIfPresent([Block].self, forKey: .content) }
        }
    }
}

public struct ClaudeParser: LineParser {
    let sessionId: String
    let agent: String
    let indexPrompts: Bool
    var isSub: Bool { !agent.isEmpty }
    // Last values sent as SessionMeta; per pass only, so a new pass re-sends them once (merge is idempotent).
    var sentCwd: String?, sentBranch: String?, sentModel: String?, sentTitle: String?
    var started = false
    static let textLimit = 2000

    public init(sessionId: String, agent: String, indexPrompts: Bool) {
        self.sessionId = sessionId; self.agent = agent; self.indexPrompts = indexPrompts
    }

    public func saveState() -> String? { nil }

    public mutating func parse(line: UnsafeRawBufferPointer, into out: inout ParseOutput) {
        // Cheap prefilter: most lines (attachments, snapshots, api-request blobs) are irrelevant.
        let isAssistant = contains(line, "\"type\":\"assistant\"")
        let isUser = !isAssistant && contains(line, "\"type\":\"user\"")
        let isTitle = !isAssistant && !isUser && !isSub &&
            (contains(line, "\"customTitle\"") || contains(line, "\"agentName\"") || contains(line, "\"aiTitle\""))
        guard isAssistant || isUser || isTitle else { return }
        // The text is needed even without indexing: it tells notifications from typed messages.
        let wantText = isUser && !isSub
        guard let r = Self.scan(line, wantText: wantText) ?? Self.decode(line) else { out.badLines += 1; return }
        handle(r, into: &out)
    }

    mutating func handle(_ r: ClaudeRecord, into out: inout ParseOutput) {
        let ts = r.timestamp.flatMap { Time.parseISO($0) }
        switch r.type {
        case "assistant":
            guard let ts, let m = r.message else { return }
            meta(r, model: m.model, into: &out)
            if let u = m.usage {
                out.usage.append(UsageRecord(sessionId: sessionId, agent: agent, ts: ts, model: m.model ?? "?",
                    input: u.input_tokens ?? 0, output: u.output_tokens ?? 0, cacheRead: u.cache_read_input_tokens ?? 0,
                    cacheWrite: u.cache_creation_input_tokens ?? 0, messageId: m.id))
            }
            for b in m.blocks ?? [] where b.type == "tool_use" {
                out.tools.append(ToolCall(sessionId: sessionId, ts: ts, name: b.name ?? "?", callId: b.id))
            }
            out.events.append(ActivityEvent(sessionId: sessionId, ts: ts, cwd: r.cwd))
        case "user":
            guard let ts else { return }
            meta(r, model: nil, into: &out)
            if !isSub, let text = humanText(r) {
                // The text also feeds task keys; Ingest indexes it only when prompts are indexed.
                out.userMessages.append(UserMessage(sessionId: sessionId, ts: ts, text: text, cwd: r.cwd))
            } else {
                out.events.append(ActivityEvent(sessionId: sessionId, ts: ts, cwd: r.cwd))
            }
        case "custom-title", "agent-name", "ai-title":
            guard !isSub else { return }
            let t: (String, Int)? = r.customTitle.map { ($0, TitleRank.customTitle) }
                ?? r.agentName.map { ($0, TitleRank.agentName) } ?? r.aiTitle.map { ($0, TitleRank.aiTitle) }
            guard let (title, rank) = t, !title.isEmpty, title != sentTitle else { return }
            sentTitle = title
            out.meta.append(SessionMeta(id: sessionId, tool: .claude, title: title, titleRank: rank))
        default: break
        }
    }

    /// Text of a message typed by the human, or nil for tool results, meta records, notifications.
    /// Returns "" when the message is human but has no text (e.g. image only).
    func humanText(_ r: ClaudeRecord) -> String? {
        // A message the human sent through a channel (Telegram…) is recorded as meta from a peer, but it is typed.
        let channel = r.origin?.kind == "channel"
        if (r.isMeta == true && !channel) || r.isSidechain == true || r.isCompactSummary == true
            || r.isVisibleInTranscriptOnly == true {
            return nil
        }
        // Newer versions say who started the turn; older ones need heuristics.
        if let o = r.turnOrigin, !channel { if o != "human" { return nil } }
        guard let m = r.message else { return nil }
        var text: String
        if let s = m.text { text = s }
        else if let bs = m.blocks {
            if bs.contains(where: { $0.type == "tool_result" }) { return nil }
            guard let t = bs.first(where: { $0.type == "text" }) else { return bs.isEmpty ? nil : "" }
            text = t.text ?? ""
        } else { return nil }
        if r.turnOrigin == nil && !channel {
            for p in ["<task-notification", "<local-command-stdout", "<local-command-caveat", "<system-reminder",
                      "<channel"] where text.hasPrefix(p) { return nil }
        }
        if channel, text.hasPrefix("<channel"), let open = text.firstIndex(of: ">") {  // `<channel source=… user=…>text</channel>`
            text = String(text[text.index(after: open)...])
            if text.hasSuffix("</channel>") { text = String(text.dropLast(10)) }
            if text.hasPrefix("\n") { text.removeFirst() }
            if text.hasSuffix("\n") { text.removeLast() }
        }
        if text.utf8.count > Self.textLimit { text = String(decoding: text.utf8.prefix(Self.textLimit), as: UTF8.self) }
        return text
    }

    mutating func meta(_ r: ClaudeRecord, model: String?, into out: inout ParseOutput) {
        var m = SessionMeta(id: sessionId, tool: .claude)
        var changed = !started
        started = true
        if !isSub {
            if let c = r.cwd, c != sentCwd { sentCwd = c; m.cwd = c; m.project = Self.project(c); changed = true }
            if let b = r.gitBranch, !b.isEmpty, b != sentBranch { sentBranch = b; m.gitBranch = b; changed = true }
            if let md = model, md != "<synthetic>", md != sentModel { sentModel = md; m.model = md; changed = true }
        }
        if changed { out.meta.append(m) }
    }

    static func project(_ cwd: String) -> String {
        let p = cwd.split(separator: "/").last.map(String.init) ?? cwd
        return p.isEmpty ? "/" : p
    }

    // MARK: decoding

    static let decoder = JSONDecoder()

    static func decode(_ line: UnsafeRawBufferPointer) -> ClaudeRecord? {
        try? decoder.decode(ClaudeRecord.self, from: Data(line))
    }

    /// Byte-scanner path. Returns nil if anything is unexpected, so the caller falls back to JSONDecoder.
    static func scan(_ line: UnsafeRawBufferPointer, wantText: Bool) -> ClaudeRecord? {
        var c = ByteScanner(line)
        var r = ClaudeRecord()
        var ok = true
        let parsed = c.object { c, k in
            if keyIs(k, "type") { r.type = c.string() }
            else if keyIs(k, "timestamp") { r.timestamp = c.string() }
            else if keyIs(k, "cwd") { r.cwd = c.string() }
            else if keyIs(k, "gitBranch") { r.gitBranch = c.string() }
            else if keyIs(k, "isMeta") { r.isMeta = c.bool() }
            else if keyIs(k, "isSidechain") { r.isSidechain = c.bool() }
            else if keyIs(k, "isCompactSummary") { r.isCompactSummary = c.bool() }
            else if keyIs(k, "isVisibleInTranscriptOnly") { r.isVisibleInTranscriptOnly = c.bool() }
            else if keyIs(k, "turnOrigin") { r.turnOrigin = c.string() }
            else if keyIs(k, "origin") {
                if c.peek != 0x7B { return false }
                var kind: String?
                ok = ok && c.object { c, k in
                    guard keyIs(k, "kind") else { return false }
                    kind = c.string()
                    return true
                }
                r.origin = ClaudeRecord.Origin(kind: kind)
            }
            else if keyIs(k, "customTitle") { r.customTitle = c.string() }
            else if keyIs(k, "agentName") { r.agentName = c.string() }
            else if keyIs(k, "aiTitle") { r.aiTitle = c.string() }
            else if keyIs(k, "message") {
                if c.peek != 0x7B { return false }
                var m = ClaudeRecord.Message()
                ok = ok && c.object { c, k in
                    if keyIs(k, "id") { m.id = c.string() }
                    else if keyIs(k, "model") { m.model = c.string() }
                    else if keyIs(k, "usage") {
                        var u = ClaudeRecord.Usage()
                        ok = ok && c.object { c, k in
                            if keyIs(k, "input_tokens") { u.input_tokens = c.int() }
                            else if keyIs(k, "output_tokens") { u.output_tokens = c.int() }
                            else if keyIs(k, "cache_read_input_tokens") { u.cache_read_input_tokens = c.int() }
                            else if keyIs(k, "cache_creation_input_tokens") { u.cache_creation_input_tokens = c.int() }
                            else { return false }
                            return true
                        }
                        m.usage = u
                    } else if keyIs(k, "content") {
                        if c.peek == 0x22 { m.text = wantText ? c.string(limit: textLimit) : (c.rawString() != nil ? "" : nil); return true }
                        var bs: [ClaudeRecord.Block] = []
                        ok = ok && c.array { c in
                            var b = ClaudeRecord.Block()
                            let r = c.object { c, k in
                                if keyIs(k, "type") { b.type = c.string() }
                                else if keyIs(k, "name") { b.name = c.string() }
                                else if keyIs(k, "id") { b.id = c.string() }
                                else if keyIs(k, "text") { b.text = wantText ? c.string(limit: textLimit) : nil; if !wantText { return false } }
                                else { return false }
                                return true
                            }
                            bs.append(b)
                            return r
                        }
                        m.blocks = bs
                    } else { return false }
                    return true
                }
                r.message = m
            } else { return false }
            return true
        }
        return parsed && ok && c.atEnd ? r : nil
    }
}
