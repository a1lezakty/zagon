/// What a handoff takes from one session log (Claude Code transcript or Codex rollout). Texts are kept raw, a little
/// longer than they can be shown; `redacted()` scrubs the few that are kept and only then cuts them, so a secret is
/// never cut in half before it is matched. Tool outputs are never kept, only the first line of a failed call.
public struct SessionDigest: Sendable {
    public struct Note: Sendable, Equatable { public var ts: Timestamp?; public var text: String }

    public var tool: ToolKind
    /// Native session id (without the `claude:` / `codex:` prefix).
    public var id: String
    public var path: String
    /// Where the session started (Claude Code records the shell's cwd after every `cd`; the first one is the project).
    public var cwd: String?
    public var branch: String?
    public var title: String?
    public var start: Timestamp?
    public var end: Timestamp?
    /// First and last typed messages (at most `keep` of each; enough for the largest rendering scale).
    public var firstUser: [Note] = []
    public var lastUser: [Note] = []
    /// The last answer of each turn (progress lines in between are dropped).
    public var assistant: [Note] = []
    var turnAnswer: Note?
    /// Edited files, most recent last, with the line of the first changed hunk when known.
    public var files: [(path: String, line: Int?)] = []
    public var errors: [Note] = []
    /// Unfinished items of the last plan (`TodoWrite`, Codex `update_plan`), with their status.
    public var todos: [String] = []

    static let keep = 12, textCap = 2500, shortCap = 500
    /// Raw texts are kept this much longer than shown: a secret on the raw cut is past the shown part.
    static let overshoot = 512

    public init(tool: ToolKind, id: String, path: String) { self.tool = tool; self.id = id; self.path = path }

    /// Reads a whole log (ponytail: in memory; stream it if multi-GB logs show up). Never fails: bad lines are skipped.
    public static func read(tool: ToolKind, id: String, path: String) -> SessionDigest {
        var d = SessionDigest(tool: tool, id: id, path: path)
        guard let bytes = Sys.readFile(path) else { return d }
        var claude = ClaudeState(), codex = CodexState()
        var start = 0
        for i in bytes.indices where bytes[i] == 0x0A {
            if i > start {
                let line = bytes[start..<i]
                if tool == .claude { Reader.claude(line, &claude, &d) } else { Reader.codex(line, &codex, &d) }
            }
            start = i + 1
        }
        d.endTurn()
        return d
    }

    // MARK: collecting

    static func trim(_ s: some StringProtocol) -> String {
        let ws: (Character) -> Bool = { $0.isWhitespace }
        guard let a = s.firstIndex(where: { !ws($0) }), let b = s.lastIndex(where: { !ws($0) }) else { return "" }
        return String(s[a...b])
    }

    /// Cut for display (after scrubbing), without terminal control sequences.
    static func clip(_ s: String, _ n: Int = textCap) -> String {
        let t = trim(plain(s))
        return t.count > n ? String(t.prefix(n)) + "…" : t
    }

    /// Drops ANSI escape sequences, other control characters (C0 but newline and tab, C1) and bidi overrides.
    static func plain(_ s: String) -> String {
        func ctl(_ c: Unicode.Scalar) -> Bool {
            (c.value < 0x20 && c != "\n" && c != "\t") || (0x7F...0x9F).contains(c.value)
                || (0x202A...0x202E).contains(c.value) || (0x2066...0x2069).contains(c.value)
        }
        guard s.unicodeScalars.contains(where: ctl) else { return s }
        var out = String.UnicodeScalarView(), it = s.unicodeScalars.makeIterator()
        while let c = it.next() {
            if c.value == 0x1B { // ESC [ … final byte
                if it.next() == "[" { while let x = it.next(), !(0x40...0x7E).contains(x.value) {} }
                continue
            }
            if !ctl(c) { out.append(c) }
        }
        return String(out)
    }

    /// Cut on the way in (before scrubbing): longer than any display cut, and never inside a word, so a secret on
    /// the cut is either whole or gone.
    static func raw(_ s: some StringProtocol, _ n: Int = textCap) -> String {
        let t = trim(s)
        guard t.count > n + overshoot else { return t }
        var cut = Substring(t.prefix(n + overshoot))
        while let l = cut.last, !l.isWhitespace { cut.removeLast() }
        return String(cut)
    }

    mutating func user(_ text: String, _ ts: Timestamp?) {
        endTurn()
        var text = Self.slashCommand(text)
        if text.hasPrefix("[Request interrupted by user") { return }
        // a session started from a handoff: do not nest the old one
        if text.contains("handoff: v1 |") { text = "(continued from a previous Zagon handoff)" }
        // `!command` in Claude Code: the output is not typed (and may be a file's content), the command is
        for p in ["<bash-stdout", "<bash-stderr", "<local-command-stdout", "<local-command-caveat"] where text.hasPrefix(p) { return }
        if text.hasPrefix("<bash-input>") { text = "!" + (Self.tag(text, "bash-input") ?? "") }
        let t = Self.raw(text)
        guard !t.isEmpty else { return }
        let n = Note(ts: ts, text: t)
        if firstUser.count < Self.keep { firstUser.append(n) } else { Self.push(&lastUser, n) }
    }

    mutating func answer(_ text: String, _ ts: Timestamp?) {
        let t = Self.raw(text)
        if !t.isEmpty { turnAnswer = Note(ts: ts, text: t) }
    }

    mutating func endTurn() {
        if let a = turnAnswer { Self.push(&assistant, a) }
        turnAnswer = nil
    }

    mutating func error(_ tool: String, _ output: String, sensitive: Bool, _ ts: Timestamp?) {
        let line = sensitive ? "(output of a call on a sensitive file omitted)" : Self.firstLine(String(output.prefix(4000)))
        guard let line else { return }
        Self.push(&errors, Note(ts: ts, text: tool + ": " + Self.raw(line, Self.shortCap)))
    }

    mutating func file(_ path: String, line: Int?) {
        files.removeAll { $0.path == path }
        files.append((path, Redact.isSensitivePath(path) ? nil : line))
    }

    static func push(_ a: inout [Note], _ n: Note) {
        a.append(n)
        if a.count > Self.keep { a.removeFirst() }
    }

    /// A copy with every kept text scrubbed (`Redact.clean`), then cut to its display length.
    public func redacted() -> SessionDigest {
        var d = self
        func c(_ s: String, _ n: Int) -> String { Self.clip(Redact.clean(Self.plain(s)), n) } // `\e[1mAKIA…` too
        func r(_ a: [Note], _ n: Int) -> [Note] { a.map { Note(ts: $0.ts, text: c($0.text, n)) } }
        d.firstUser = r(firstUser, Self.textCap); d.lastUser = r(lastUser, Self.textCap)
        d.assistant = r(assistant, Self.textCap); d.errors = r(errors, Self.shortCap)
        d.todos = todos.map { c($0, Self.shortCap) }; d.title = title.map { c($0, Self.shortCap) }
        return d
    }

    mutating func seen(_ ts: Timestamp?) {
        guard let ts else { return }
        if start == nil { start = ts }
        end = ts
    }

    /// `<command-name>/x</command-name>…<command-args>y</command-args>` → `/x y`; "" for a command without
    /// arguments (`/clear`, `/model`: nothing about the work).
    static func slashCommand(_ s: String) -> String {
        guard s.contains("<command-name>") else { return s }
        guard let args = tag(s, "command-args"), !trim(args).isEmpty else { return "" }
        return (tag(s, "command-name") ?? "") + " " + args
    }

    /// Text between `<t>` and `</t>`.
    static func tag(_ s: String, _ t: String) -> String? {
        guard let a = s.firstRange(of: "<\(t)>"), let b = s[a.upperBound...].firstRange(of: "</\(t)>") else { return nil }
        return String(s[a.upperBound..<b.lowerBound])
    }

    /// The first informative line of a failed tool call (status / timing lines of the tool wrappers skipped).
    static func firstLine(_ s: String) -> String? {
        let body = s.firstRange(of: "\nOutput:\n").map { String(s[$0.upperBound...]) } ?? s
        for raw in body.split(separator: "\n").prefix(20) {
            var l = trim(raw)
            for tag in ["<tool_use_error>", "</tool_use_error>", "<error>", "</error>"] { l = l.replacing(tag, with: "") }
            if l.isEmpty || noise.contains(where: { l.hasPrefix($0) }) { continue }
            return l
        }
        return nil
    }
    static let noise = ["Exit code", "Process exited with code", "Chunk ID:", "Wall time:", "Original token count:", "Output:"]

    static func exitCode(_ s: some StringProtocol) -> Int? {
        for marker in ["Process exited with code ", "Exit code: ", "Exit code "] {
            guard let r = s.firstRange(of: marker) else { continue }
            if let n = Int(s[r.upperBound...].prefix { $0 == "-" || $0.isNumber }) { return n }
        }
        return nil
    }

    /// Unfinished plan items: `[in progress] step`.
    static func plan(_ items: [JValue], text: String) -> [String] {
        items.compactMap { t in
            guard let st = t["status"]?.string, st != "completed", let c = t[text]?.string else { return nil }
            return "[\(st.replacing("_", with: " "))] " + raw(c, shortCap)
        }
    }
}

// MARK: readers

struct ClaudeState {
    /// tool_use id → (name, touches a sensitive file)
    var calls: [String: (String, Bool)] = [:]
    var titleRank = 0
    let human = ClaudeParser(sessionId: "", agent: "", indexPrompts: true)
}

struct CodexState {
    var calls: [String: (String, Bool)] = [:]
    var userKind: String?
}

enum Reader {
    static func has(_ b: ArraySlice<UInt8>, _ s: String) -> Bool {
        let n = Array(s.utf8)
        guard b.count >= n.count else { return false }
        var i = b.startIndex
        while i <= b.endIndex - n.count {
            if b[i] == n[0] {
                var j = 1
                while j < n.count && b[i + j] == n[j] { j += 1 }
                if j == n.count { return true }
            }
            i += 1
        }
        return false
    }

    static func int(_ v: JValue?) -> Int? { v?.double.flatMap { $0.isFinite && abs($0) < 1e9 ? Int($0) : nil } }

    // Claude Code: `{"type":"user"|"assistant", "message":{"content":…}, "cwd", "gitBranch", "timestamp", …}`.
    static func claude(_ b: ArraySlice<UInt8>, _ s: inout ClaudeState, _ d: inout SessionDigest) {
        let isA = has(b, "\"type\":\"assistant\""), isU = !isA && has(b, "\"type\":\"user\"")
        let isT = !isA && !isU && (has(b, "\"customTitle\"") || has(b, "\"aiTitle\"") || has(b, "\"agentName\""))
        guard isA || isU || isT, let o = JValue.parse(Array(b)), o["isSidechain"] != .bool(true) else { return }
        if isT {
            let t: (String?, Int) = o["customTitle"] != nil ? (o["customTitle"]?.string, 3)
                : o["agentName"] != nil ? (o["agentName"]?.string, 2) : (o["aiTitle"]?.string, 1)
            if let title = t.0, !title.isEmpty, t.1 >= s.titleRank {
                d.title = SessionDigest.raw(title, SessionDigest.shortCap); s.titleRank = t.1
            }
            return
        }
        let ts = o["timestamp"]?.string.flatMap(Time.parseISO)
        d.seen(ts)
        if d.cwd == nil, let c = o["cwd"]?.string, !c.isEmpty { d.cwd = c }
        if let g = o["gitBranch"]?.string, !g.isEmpty { d.branch = g }
        let blocks = o["message"]?["content"]?.array ?? []
        if isA {
            // Claude Code's own notices (API errors, usage limits) are not answers
            if o["isApiErrorMessage"] == .bool(true) || o["message"]?["model"]?.string == "<synthetic>" { return }
            for bl in blocks {
                switch bl["type"]?.string {
                case "text": d.answer(bl["text"]?.string ?? "", ts)
                case "tool_use":
                    let name = bl["name"]?.string ?? "?", input = bl["input"] ?? .object([])
                    let target = (input["file_path"] ?? input["notebook_path"] ?? input["path"])?.string
                    let sensitive = target.map(Redact.isSensitivePath) ?? false
                        || input["command"]?.string.map(Redact.mentionsSensitiveFile) ?? false
                    if let id = bl["id"]?.string { s.calls[id] = (name, sensitive) }
                    if name == "TodoWrite", let todos = input["todos"]?.array { d.todos = SessionDigest.plan(todos, text: "content") }
                    if ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(name), let p = target { d.file(p, line: nil) }
                default: break
                }
            }
            return
        }
        // user: a typed message (core's rule; its text is cut at 2000 bytes, so take the full one), or tool results
        if let r = b.withUnsafeBytes({ ClaudeParser.decode($0) }), s.human.humanText(r) != nil {
            let content = o["message"]?["content"]
            d.user(content?.string ?? blocks.first { $0["type"]?.string == "text" }?["text"]?.string ?? "", ts)
            return
        }
        for bl in blocks where bl["type"]?.string == "tool_result" && bl["is_error"] == .bool(true) {
            let (name, sensitive) = bl["tool_use_id"]?.string.flatMap { s.calls[$0] } ?? ("tool", false)
            let text = bl["content"]?.string
                ?? (bl["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
            d.error(name, text, sensitive: sensitive, ts)
        }
        if let r = o["toolUseResult"], let p = r["filePath"]?.string {
            let line = int(r["structuredPatch"]?.array?.first?["newStart"])
            d.file(p, line: line ?? (r["type"]?.string == "create" ? 1 : nil))
        }
    }

    // Codex: `{"timestamp", "type", "payload"}` (see CodexSource).
    static func codex(_ b: ArraySlice<UInt8>, _ s: inout CodexState, _ d: inout SessionDigest) {
        guard let o = JValue.parse(Array(b)), let type = o["type"]?.string else { return }
        let p = o["payload"] ?? .object([]), ptype = p["type"]?.string
        let ts = o["timestamp"]?.string.flatMap(Time.parseISO)
        switch type {
        case "session_meta":
            if d.cwd == nil, let c = p["cwd"]?.string { d.cwd = c }
            if let g = p["git"]?["branch"]?.string, !g.isEmpty { d.branch = g }
        case "turn_context":
            if d.cwd == nil, let c = p["cwd"]?.string { d.cwd = c }
        case "event_msg":
            d.seen(ts)
            switch ptype {
            case "task_started", "turn_started": s.userKind = nil
            case "user_message" where (p["kind"]?.string ?? "plain") == "plain":
                if s.userKind == nil { s.userKind = "user_message" }
                if s.userKind == "user_message" { d.user(p["message"]?.string ?? "", ts) }
            case "item_completed":
                guard let item = p["item"], item["type"]?.string == "UserMessage" else { return }
                if s.userKind == nil { s.userKind = "item_completed" }
                guard s.userKind == "item_completed" else { return }
                d.user((item["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n"), ts)
            default: break
            }
        case "response_item":
            d.seen(ts)
            switch ptype {
            case "message" where p["role"]?.string == "assistant":
                d.answer((p["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n"), ts)
            case "function_call", "custom_tool_call":
                let name = p["name"]?.string ?? "?"
                let raw = (p["arguments"] ?? p["input"])?.string ?? ""
                let args = JValue.parse(raw)
                let cmd = args?["cmd"] ?? args?["command"]
                let command = cmd?.string ?? (cmd?.array ?? []).compactMap(\.string).joined(separator: " ")
                let targets = name == "apply_patch" ? patchFiles(args?["input"]?.string ?? raw, &d) : []
                if let id = p["call_id"]?.string {
                    s.calls[id] = (name, Redact.mentionsSensitiveFile(command) || targets.contains(where: Redact.isSensitivePath))
                }
                if name == "update_plan", let plan = args?["plan"]?.array { d.todos = SessionDigest.plan(plan, text: "step") }
            case "function_call_output", "custom_tool_call_output":
                var out = p["output"]?.string ?? ""
                var code: Int?
                if let w = p["output"].flatMap({ $0.string == nil ? $0 : nil }) ?? (out.hasPrefix("{") ? JValue.parse(out) : nil) {
                    out = w["output"]?.string ?? ""
                    code = int(w["metadata"]?["exit_code"])
                }
                guard let c = code ?? SessionDigest.exitCode(out.prefix(400)), c != 0 else { return }
                let (name, sensitive) = p["call_id"]?.string.flatMap { s.calls[$0] } ?? ("tool", false)
                d.error(name, out, sensitive: sensitive, ts)
            default: break
            }
        default: break
        }
    }

    /// `*** Update File: <path>` / `*** Add File:` / `*** Delete File:` / `*** Move to:` lines of a Codex patch.
    /// Returns the paths.
    static func patchFiles(_ patch: String, _ d: inout SessionDigest) -> [String] {
        var paths: [String] = []
        for l in patch.split(separator: "\n") {
            for p in ["*** Update File: ", "*** Add File: ", "*** Delete File: ", "*** Move to: "] where l.hasPrefix(p) {
                let path = SessionDigest.trim(l.dropFirst(p.count))
                d.file(path, line: p == "*** Add File: " ? 1 : nil)
                paths.append(path)
            }
        }
        return paths
    }
}
