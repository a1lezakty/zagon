// Contract between source parsers and the shared ingest pipeline (see docs/dev/contracts.md).

/// Everything a parser produced from a run of complete lines of one file. Ingest drains it into the Store.
public struct ParseOutput: Sendable {
    public var meta: [SessionMeta] = []
    public var usage: [UsageRecord] = []
    public var tools: [ToolCall] = []
    public var events: [ActivityEvent] = []
    public var userMessages: [UserMessage] = []
    public var limits: [LimitSnapshot] = []
    /// Lines that looked relevant but could not be parsed (for `doctor`); never fatal.
    public var badLines = 0
    public init() {}
    public var isEmpty: Bool {
        meta.isEmpty && usage.isEmpty && tools.isEmpty && events.isEmpty && userMessages.isEmpty && limits.isEmpty
    }
}

/// A per-file, line-oriented parser. One instance lives for one ingest pass over one file.
public protocol LineParser {
    /// Called once per complete line (without the trailing newline). Must not throw or crash on any input.
    mutating func parse(line: UnsafeRawBufferPointer, into out: inout ParseOutput)
    /// Small opaque state to resume this file later (e.g. JSON); `nil` = nothing to keep.
    func saveState() -> String?
}

/// Where a tool keeps its line-oriented logs and how to parse them.
public struct SourceSpec: Sendable {
    public var tool: ToolKind
    /// Absolute directory that is walked recursively.
    public var root: String
    /// Filter on the path relative to `root`, e.g. `-proj/abc.jsonl`.
    public var accepts: @Sendable (_ relativePath: String) -> Bool
    /// Creates the parser for a file. `state` is what `saveState()` returned last time (nil for a new or reset file).
    public var makeParser: @Sendable (_ path: String, _ relativePath: String, _ state: String?) -> any LineParser

    public init(tool: ToolKind, root: String, accepts: @escaping @Sendable (String) -> Bool,
                makeParser: @escaping @Sendable (String, String, String?) -> any LineParser) {
        self.tool = tool; self.root = root; self.accepts = accepts; self.makeParser = makeParser
    }
}
