#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Claude Code transcripts: `~/.claude/projects/<project>/<session>.jsonl` (main thread) and
/// `<project>/<session>/subagents/**/agent-*.jsonl` (sub-agents, counted under the parent session).
/// `account`: the Claude Code account whose `projects` folder `root` is (`Accounts.claudeRoots`); its sessions carry it.
public enum ClaudeSource {
    public static func spec(root: String, indexPrompts: Bool = true, account: String? = nil) -> SourceSpec {
        SourceSpec(tool: .claude, root: root, accepts: { layout($0) != nil }, makeParser: { _, rel, _ in
            let l = layout(rel)!
            return ClaudeParser(sessionId: "claude:" + l.session, agent: l.agent, indexPrompts: indexPrompts, account: account)
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
    var attachment: Attachment?
    /// What a tool call returned; only the keys that launch or stop a background task are read.
    var toolUseResult: ToolResult?
    /// `queue-operation` records: `enqueue` with `content` = a message queued for the agent (task notifications).
    var operation: LenientString?
    var content: LenientString?
    /// `history-suppression` records: `cause` (`fork_inherit` = a fork's copy of the history follows) and their time `ts`.
    var cause: LenientString?
    var ts: LenientString?

    struct LenientString: Decodable {
        var value: String?
        init(_ v: String?) { value = v }
        init(from d: Decoder) throws { value = try? d.singleValueContainer().decode(String.self) }
    }
    /// Background Bash: `backgroundTaskId`; async Agent: `isAsync` + `agentId`; Monitor: `taskId` + `persistent`
    /// (+ `timeoutMs`); TaskStop: `task_id` + `task_type`.
    struct ToolResult: Decodable {
        var backgroundTaskId: String?, isAsync: Bool?, agentId: String?, taskId: String?, persistent: Bool?
        var timeoutMs: Int?, task_id: String?, task_type: String?
        enum K: String, CodingKey { case backgroundTaskId, isAsync, agentId, taskId, persistent, timeoutMs, task_id, task_type }
        init() {}
        // lenient: most tools return a string or another shape here
        init(from d: Decoder) throws {
            guard let c = try? d.container(keyedBy: K.self) else { return }
            backgroundTaskId = try? c.decodeIfPresent(String.self, forKey: .backgroundTaskId)
            isAsync = try? c.decodeIfPresent(Bool.self, forKey: .isAsync)
            agentId = try? c.decodeIfPresent(String.self, forKey: .agentId)
            taskId = try? c.decodeIfPresent(String.self, forKey: .taskId)
            persistent = try? c.decodeIfPresent(Bool.self, forKey: .persistent)
            timeoutMs = try? c.decodeIfPresent(Int.self, forKey: .timeoutMs)
            task_id = try? c.decodeIfPresent(String.self, forKey: .task_id)
            task_type = try? c.decodeIfPresent(String.self, forKey: .task_type)
        }
    }

    struct Origin: Decodable {
        var kind: String?
        init(kind: String?) { self.kind = kind }
        // lenient: another shape of `origin` must not make the whole record unreadable
        init(from d: Decoder) throws { kind = try? d.container(keyedBy: K.self).decode(String.self, forKey: .kind) }
        enum K: String, CodingKey { case kind }
    }
    struct Usage: Decodable {
        var input_tokens: Int?, output_tokens: Int?, cache_read_input_tokens: Int?, cache_creation_input_tokens: Int?
        var cache_creation: CacheCreation?
    }
    /// Cache writes by lifetime; their sum is `cache_creation_input_tokens`.
    struct CacheCreation: Decodable { var ephemeral_1h_input_tokens: Int?, ephemeral_5m_input_tokens: Int? }
    struct Block: Decodable {
        var type: String?; var name: String?; var id: String?; var text: String?
        /// `input.command` of a tool call, kept only when it types into a terminal (see `ClaudeParser.relayTargets`).
        var command: String?
        enum CodingKeys: String, CodingKey { case type, name, id, text, input }
        struct Input: Decodable {
            var command: String?
            init(from d: Decoder) throws { command = try? d.container(keyedBy: K.self).decode(String.self, forKey: .command) }
            enum K: String, CodingKey { case command }
        }
        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            type = try? c.decodeIfPresent(String.self, forKey: .type); name = try? c.decodeIfPresent(String.self, forKey: .name)
            id = try? c.decodeIfPresent(String.self, forKey: .id); text = try? c.decodeIfPresent(String.self, forKey: .text)
            command = (try? c.decodeIfPresent(Input.self, forKey: .input))?.command.flatMap { ClaudeParser.typesKeys($0) ? $0 : nil }
        }
    }
    /// `attachment` records; only `queued_command` is read (a message sent while the agent was working).
    struct Attachment: Decodable {
        var type: String?, commandMode: String?, origin: Origin?
        var text: String?, blocks: [Block]?   // `prompt` as a plain string or as blocks
        enum CodingKeys: String, CodingKey { case type, commandMode, origin, prompt }
        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            commandMode = try? c.decodeIfPresent(String.self, forKey: .commandMode)
            origin = try? c.decodeIfPresent(Origin.self, forKey: .origin)
            if let s = try? c.decodeIfPresent(String.self, forKey: .prompt) { text = s }
            else { blocks = try? c.decodeIfPresent([Block].self, forKey: .prompt) }
        }
    }
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
    let account: String?
    var isSub: Bool { !agent.isEmpty }
    // Last values sent as SessionMeta; per pass only, so a new pass re-sends them once (merge is idempotent).
    var sentCwd: String?, sentBranch: String?, sentModel: String?, sentTitle: String?
    var started = false
    static let textLimit = 2000

    public init(sessionId: String, agent: String, indexPrompts: Bool, account: String? = nil) {
        self.sessionId = sessionId; self.agent = agent; self.indexPrompts = indexPrompts; self.account = account
    }

    public func saveState() -> String? { nil }

    public mutating func parse(line: UnsafeRawBufferPointer, into out: inout ParseOutput) {
        // Cheap prefilter: most lines (attachments, snapshots, api-request blobs) are irrelevant.
        let isAssistant = contains(line, "\"type\":\"assistant\"")
        let isUser = !isAssistant && contains(line, "\"type\":\"user\"")
        let isQueued = !isAssistant && !isUser && !isSub && contains(line, "\"queued_command\"")
        let isQueueOp = !isAssistant && !isUser && !isQueued && !isSub && contains(line, "\"queue-operation\"")
            && contains(line, "<task-notification>")
        let isFork = !isAssistant && !isUser && !isSub && contains(line, "\"history-suppression\"")
            && contains(line, "\"fork_inherit\"")
        let isTitle = !isAssistant && !isUser && !isQueued && !isQueueOp && !isFork && !isSub &&
            (contains(line, "\"customTitle\"") || contains(line, "\"agentName\"") || contains(line, "\"aiTitle\""))
        guard isAssistant || isUser || isQueued || isQueueOp || isFork || isTitle else {
            // JSON written with spaces (`"type": "user"`) never matches the checks above: compact it and look again.
            // Only lines whose first separator has a space pay for this (none in any version seen so far).
            if Self.spaced(line) {
                let b = Self.compacted(line)
                if b.withUnsafeBytes({ !Self.spaced($0) }) { b.withUnsafeBytes { parse(line: $0, into: &out) } }
            }
            return
        }
        // The text is needed even without indexing: it tells notifications from typed messages.
        let wantText = (isUser || isQueued) && !isSub
        guard let r = Self.scan(line, wantText: wantText) ?? Self.decode(line) else { out.badLines += 1; return }
        handle(r, into: &out)
    }

    mutating func handle(_ r: ClaudeRecord, into out: inout ParseOutput) {
        let ts = r.timestamp.flatMap { Time.parseISO($0) }
        switch r.type {
        case "assistant":
            if r.message?.usage == nil { out.noUsage += 1 }  // a renamed `usage` would silently count no tokens
            guard let ts, let m = r.message else { return }
            meta(r, model: m.model, into: &out)
            if let u = m.usage {
                out.usage.append(UsageRecord(sessionId: sessionId, agent: agent, ts: ts, model: m.model ?? "?",
                    input: u.input_tokens ?? 0, output: u.output_tokens ?? 0, cacheRead: u.cache_read_input_tokens ?? 0,
                    cacheWrite: u.cache_creation_input_tokens ?? 0, cacheWrite1h: u.cache_creation?.ephemeral_1h_input_tokens ?? 0,
                    messageId: m.id, cwd: r.cwd))
            }
            for b in m.blocks ?? [] where b.type == "tool_use" {
                out.tools.append(ToolCall(sessionId: sessionId, ts: ts, name: b.name ?? "?", callId: b.id))
                if b.name == "Bash", let cmd = b.command, case let targets = Self.relayTargets(cmd), !targets.isEmpty {
                    out.relays.append(Relay(sessionId: sessionId, ts: ts, targets: targets))
                }
            }
            out.events.append(ActivityEvent(sessionId: sessionId, ts: ts, cwd: r.cwd))
        case "user":
            guard let ts else { return }
            meta(r, model: nil, into: &out)
            if !isSub, let t = r.toolUseResult, let b = Self.background(t, sessionId: sessionId, ts: ts) { out.background.append(b) }
            if !isSub, let text = humanText(r) {
                // The text also feeds task keys; Ingest indexes it only when prompts are indexed.
                out.userMessages.append(UserMessage(sessionId: sessionId, ts: ts, text: text, cwd: r.cwd,
                                                    channel: r.origin?.kind == "channel"))
            } else {
                out.events.append(ActivityEvent(sessionId: sessionId, ts: ts, cwd: r.cwd))
            }
        case "attachment":
            // Sent while the agent was working: Claude Code queues it and hands it over mid-turn; it never becomes a
            // `user` record of its own.
            guard !isSub, let ts, let a = r.attachment, a.type == "queued_command", a.commandMode == "prompt" else { return }
            let kind = a.origin?.kind
            guard kind == "human" || kind == "channel" || kind == nil else { return }  // not `peer`, `task-notification`
            var text = a.text ?? a.blocks.map(Self.typedText) ?? ""
            if kind == nil, Self.markers.contains(where: { text.hasPrefix($0) }) { return }
            if kind == "channel" { text = Self.channelBody(text) }
            out.userMessages.append(UserMessage(sessionId: sessionId, ts: ts, text: Self.clip(text), cwd: r.cwd,
                                                channel: kind == "channel"))
        case "queue-operation":
            // A task notification is queued the moment its task ends, whether or not the agent is busy.
            guard !isSub, let ts, r.operation?.value == "enqueue", let text = r.content?.value else { return }
            for id in Self.finishedTasks(text) {
                out.background.append(BackgroundTask(sessionId: sessionId, id: id, ts: ts, until: nil))
            }
        case "history-suppression":
            // A fork: the history copied after this record keeps its launches but none of their ends.
            guard !isSub, r.cause?.value == "fork_inherit", let t = (r.ts?.value).flatMap({ Time.parseISO($0) }) else { return }
            out.background.append(BackgroundTask(sessionId: sessionId, id: "", ts: t, until: nil))
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

    /// A background task launched (`until` = when it stops counting) or stopped (TaskStop: `until` nil) by a tool call.
    static func background(_ t: ClaudeRecord.ToolResult, sessionId: String, ts: Timestamp) -> BackgroundTask? {
        if let id = t.task_id, t.task_type != nil { return BackgroundTask(sessionId: sessionId, id: id, ts: ts, until: nil) }
        // ponytail: a task of a process that died never reports; after this long it stops counting (a new process
        // clears them earlier, `SpoolIngest`). Per-kind caps if long jobs outlive it.
        let cap = ts + UserTime.driverIdle
        if let id = t.backgroundTaskId { return BackgroundTask(sessionId: sessionId, id: id, ts: ts, until: cap) }
        if t.isAsync == true, let id = t.agentId { return BackgroundTask(sessionId: sessionId, id: id, ts: ts, until: cap) }
        // A non-persistent Monitor counts until its `timeoutMs`; a `taskId` without `persistent` (Workflow and other
        // tools) is not counted.
        if let id = t.taskId, let persistent = t.persistent {
            let ends = !persistent ? t.timeoutMs.map { ts + Double($0) / 1000 } : nil
            return BackgroundTask(sessionId: sessionId, id: id, ts: ts, until: min(cap, ends ?? cap))
        }
        return nil
    }

    /// Ids of the tasks a queued message reports as finished: each `<task-notification>` with a `<status>` (a
    /// monitor's `<event>` without one is not an end).
    static func finishedTasks(_ s: String) -> [String] {
        var out: [String] = []
        var rest = s[...]
        while let open = rest.firstRange(of: "<task-notification>") {
            rest = rest[open.upperBound...]
            let n = rest.firstRange(of: "</task-notification>").map { rest[..<$0.lowerBound] } ?? rest
            guard n.firstRange(of: "<status>") != nil, let a = n.firstRange(of: "<task-id>"),
                  let b = n[a.upperBound...].firstRange(of: "</task-id>") else { continue }
            let id = String(n[a.upperBound..<b.lowerBound])
            if !id.isEmpty, !out.contains(id) { out.append(id) }
        }
        return out
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
            guard bs.contains(where: { $0.type == "text" }) else { return bs.isEmpty ? nil : "" }
            text = Self.typedText(bs)
        } else { return nil }
        if r.turnOrigin == nil && !channel, Self.markers.contains(where: { text.hasPrefix($0) }) { return nil }
        if channel { text = Self.channelBody(text) }
        return Self.clip(text)
    }

    /// The first text block that is not editor context: the VS Code / Cursor extension sends the open file, the
    /// selection, a terminal or browser as text blocks of their own (each wrapped in its tag) before the typed text.
    /// Matched by the opening tag only: a long block is clipped before its closing one. "" when there is none.
    static func typedText(_ bs: [ClaudeRecord.Block]) -> String {
        bs.first { b in b.type == "text" && !editorContext.contains { (b.text ?? "").hasPrefix($0) } }?.text ?? ""
    }

    static let editorContext = ["<ide_", "<terminal name=\"", "<browser tabGroupId=\"", "<browser_instruction>"]

    /// Prefixes of generated user records in versions that do not say who started the turn.
    static let markers = ["<task-notification", "<local-command-stdout", "<local-command-caveat", "<system-reminder", "<channel"]

    /// `<channel source=… user=…>text</channel>` -> `text`.
    static func channelBody(_ s: String) -> String {
        guard s.hasPrefix("<channel"), let open = s.firstIndex(of: ">") else { return s }
        var text = String(s[s.index(after: open)...])
        if text.hasSuffix("</channel>") { text = String(text.dropLast(10)) }
        if text.hasPrefix("\n") { text.removeFirst() }
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    static func clip(_ text: String) -> String {
        text.utf8.count > textLimit ? String(decoding: text.utf8.prefix(textLimit), as: UTF8.self) : text
    }

    /// A shell command that may type into a terminal pane (`relayTargets` decides).
    static func typesKeys(_ cmd: String) -> Bool { cmd.contains("tmux") }

    /// Targets of every `tmux send-keys` / `send` / `paste-buffer` call in a shell command (tmux's own options, then the
    /// command, then its options up to the first argument, as tmux reads them): the session name of `-t name`,
    /// `-t =name`, `-t name:window.pane`, lower-cased; "" for a call without `-t` or with a target that is not a plain
    /// name (`$s`, `%3`, `"$(…)"`). Empty: the command only mentions them (`rg send-keys`).
    static func relayTargets(_ cmd: String) -> [String] {
        var out: [String] = []
        for seg in cmd.split(whereSeparator: { ";|&\n".contains($0) }) {
            let w = seg.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { w -> Substring in
                var w = w
                while let q = w.first, q == "'" || q == "\"" || q == "(" { w.removeFirst() }
                while let q = w.last, q == "'" || q == "\"" || q == ")" { w.removeLast() }
                return w
            }
            guard var i = w.firstIndex(where: { $0 == "tmux" || $0.hasSuffix("/tmux") }) else { continue }
            /// Skips the options at `i`; returns the value of `-t` if any. `withArg`: the letters that take a value.
            func options(_ withArg: String) -> Substring? {
                var t: Substring?
                i += 1
                while i < w.count, w[i].hasPrefix("-"), w[i].count > 1, w[i] != "--" {
                    var letters = w[i].dropFirst()
                    while let ch = letters.popFirst() {
                        guard withArg.contains(ch) else { continue }
                        let value = letters.isEmpty ? (i + 1 < w.count ? w[i + 1] : "") : letters
                        if letters.isEmpty { i += 1 }
                        if ch == "t" { t = value }
                        break
                    }
                    i += 1
                }
                return t
            }
            _ = options("cfLST")
            guard i < w.count, ["send-keys", "send", "paste-buffer", "pasteb"].contains(w[i]) else { continue }
            var target = options("tNcbs") ?? ""
            if target.hasPrefix("=") { target.removeFirst() }
            target = target.prefix { $0 != ":" && $0 != "." }
            if target.contains(where: { "$%`(){}*?".contains($0) }) { target = "" }
            let t = target.lowercased()
            if !out.contains(t) { out.append(t) }
        }
        return out
    }

    mutating func meta(_ r: ClaudeRecord, model: String?, into out: inout ParseOutput) {
        var m = SessionMeta(id: sessionId, tool: .claude, account: account)
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

    /// A JSON object with whitespace after `{` or around its first key's colon (`{ "type"`, `{"type": "user"`).
    /// Looks at the first key only, so it costs nothing on compact lines.
    static func spaced(_ l: UnsafeRawBufferPointer) -> Bool {
        func ws(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0D || b == 0x0A }
        guard l.count > 3, l[0] == 0x7B else { return false }
        if ws(l[1]) { return true }
        guard l[1] == 0x22 else { return false }
        var i = 2
        while i < min(l.count, 256), l[i] != 0x22 { i += 1 }  // the first key's closing quote
        guard i + 2 < l.count else { return false }
        return ws(l[i + 1]) || (l[i + 1] == 0x3A && ws(l[i + 2]))
    }

    /// The line without whitespace outside strings.
    static func compacted(_ l: UnsafeRawBufferPointer) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(l.count)
        var inString = false, escaped = false
        for b in l {
            if inString {
                if escaped { escaped = false } else if b == 0x5C { escaped = true } else if b == 0x22 { inString = false }
            } else if b == 0x22 {
                inString = true
            } else if b == 0x20 || b == 0x09 || b == 0x0D || b == 0x0A {
                continue
            }
            out.append(b)
        }
        return out
    }

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
            else if keyIs(k, "cause") || keyIs(k, "ts") {
                guard r.type == "history-suppression", c.peek == 0x22 else { return false }
                let v = ClaudeRecord.LenientString(c.string())
                if keyIs(k, "ts") { r.ts = v } else { r.cause = v }
            }
            else if keyIs(k, "operation") {
                guard c.peek == 0x22 else { return false }
                r.operation = ClaudeRecord.LenientString(c.string())
            }
            else if keyIs(k, "content") {
                guard r.type == "queue-operation", c.peek == 0x22 else { return false }
                r.content = ClaudeRecord.LenientString(c.string(limit: 1 << 16))
            }
            else if keyIs(k, "toolUseResult") {
                guard c.peek == 0x7B else { return false }
                var t = ClaudeRecord.ToolResult()
                ok = ok && c.object { c, k in
                    if keyIs(k, "backgroundTaskId") { t.backgroundTaskId = c.string() }
                    else if keyIs(k, "isAsync") { t.isAsync = c.bool() }
                    else if keyIs(k, "agentId") { t.agentId = c.string() }
                    else if keyIs(k, "taskId") { t.taskId = c.string() }
                    else if keyIs(k, "persistent") { t.persistent = c.bool() }
                    else if keyIs(k, "timeoutMs") { t.timeoutMs = c.int() }
                    else if keyIs(k, "task_id") { t.task_id = c.string() }
                    else if keyIs(k, "task_type") { t.task_type = c.string() }
                    else { return false }
                    return true
                }
                r.toolUseResult = t
            }
            else if keyIs(k, "attachment") {
                if c.peek != 0x7B { return false }
                var a = ClaudeRecord.Attachment()
                ok = ok && c.object { c, k in
                    if keyIs(k, "type") { a.type = c.string() }
                    else if keyIs(k, "commandMode") { a.commandMode = c.string() }
                    else if keyIs(k, "origin") {
                        if c.peek != 0x7B { return false }
                        var kind: String?
                        ok = ok && c.object { c, k in
                            guard keyIs(k, "kind") else { return false }
                            kind = c.string()
                            return true
                        }
                        a.origin = ClaudeRecord.Origin(kind: kind)
                    } else if keyIs(k, "prompt") {
                        if c.peek == 0x22 { a.text = wantText ? c.string(limit: textLimit) : nil; return wantText }
                        guard wantText, let bs = blocks(&c, wantText: true) else { return false }
                        a.blocks = bs
                    } else { return false }
                    return true
                }
                r.attachment = a
            }
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
                            else if keyIs(k, "cache_creation") {
                                var cc = ClaudeRecord.CacheCreation()
                                ok = ok && c.object { c, k in
                                    if keyIs(k, "ephemeral_1h_input_tokens") { cc.ephemeral_1h_input_tokens = c.int() }
                                    else if keyIs(k, "ephemeral_5m_input_tokens") { cc.ephemeral_5m_input_tokens = c.int() }
                                    else { return false }
                                    return true
                                }
                                u.cache_creation = cc
                            }
                            else { return false }
                            return true
                        }
                        m.usage = u
                    } else if keyIs(k, "content") {
                        if c.peek == 0x22 { m.text = wantText ? c.string(limit: textLimit) : (c.rawString() != nil ? "" : nil); return true }
                        guard let bs = blocks(&c, wantText: wantText) else { ok = false; return true }
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

    /// A content block array; nil on anything unexpected.
    static func blocks(_ c: inout ByteScanner, wantText: Bool) -> [ClaudeRecord.Block]? {
        var bs: [ClaudeRecord.Block] = []
        var ok = true
        let parsed = c.array { c in
            var b = ClaudeRecord.Block()
            let r = c.object { c, k in
                if keyIs(k, "type") { b.type = c.string() }
                else if keyIs(k, "name") { b.name = c.string() }
                else if keyIs(k, "id") { b.id = c.string() }
                else if keyIs(k, "text") { b.text = wantText ? c.string(limit: textLimit) : nil; if !wantText { return false } }
                else if keyIs(k, "input") {
                    if c.peek != 0x7B { return false }
                    ok = ok && c.object { c, k in
                        guard keyIs(k, "command"), let raw = c.rawString() else { return false }
                        // Decoded only for the rare command that types into a terminal.
                        if contains(raw, "tmux") {
                            guard let s = ByteScanner.unescape(raw, limit: .max) else { ok = false; return true }
                            b.command = s
                        }
                        return true
                    }
                }
                else { return false }
                return true
            }
            bs.append(b)
            return r
        }
        return parsed && ok ? bs : nil
    }
}
