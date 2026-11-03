// Normalized records every source parser (Claude Code, Codex, hooks) emits. Keep small and stable:
// docs/dev/contracts.md describes them; changing a field is a contract change.

/// Seconds since the Unix epoch (UTC), fractional.
public typealias Timestamp = Double

public enum ToolKind: String, Sendable, Codable, CaseIterable {
    /// `cursor`: Cursor's agent, from its hooks, `agent-transcripts` and conversation list (sessions, time, tokens from
    /// hooks without a price; no limits).
    case claude, codex, cursor
}

/// Partial session description. `nil` fields mean "unknown here", never "clear".
public struct SessionMeta: Sendable, Equatable {
    /// `<tool>:<native session id>`, e.g. `claude:174a7d2d-...`.
    public var id: String
    public var tool: ToolKind
    public var project: String?
    public var cwd: String?
    public var gitBranch: String?
    public var title: String?
    /// Higher rank wins when several title sources exist (see `TitleRank`).
    public var titleRank: Int
    public var model: String?
    /// The source archived the session (Codex `archived_sessions/`, `threads.archived`): kept in history,
    /// hidden from the list of live sessions.
    public var archived: Bool?
    /// The Claude Code account the session runs on (`Accounts.name`: `default` = `~/.claude`, else the name of its
    /// `CLAUDE_CONFIG_DIR`); nil = not known here.
    public var account: String?

    public init(id: String, tool: ToolKind, project: String? = nil, cwd: String? = nil, gitBranch: String? = nil,
                title: String? = nil, titleRank: Int = 0, model: String? = nil, archived: Bool? = nil, account: String? = nil) {
        self.id = id; self.tool = tool; self.project = project; self.cwd = cwd; self.gitBranch = gitBranch
        self.title = title; self.titleRank = titleRank; self.model = model; self.archived = archived; self.account = account
    }
}

public enum TitleRank {
    public static let none = 0, aiTitle = 1, agentName = 2, customTitle = 3, external = 3
}

/// Token usage of one API request (or an additive delta for sources without request ids).
public struct UsageRecord: Sendable, Equatable {
    public var sessionId: String
    /// Sub-agent label inside the session (`agent-a1b2...`); empty for the main thread.
    public var agent: String
    public var ts: Timestamp
    public var model: String
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    /// All cache writes; `cacheWrite1h` of them are kept for an hour (priced higher), the rest for 5 minutes.
    public var cacheWrite: Int
    public var cacheWrite1h: Int
    /// Working directory of the request (the project it counts for); nil = unknown.
    public var cwd: String?
    /// When set, records with the same id are one request: the last one seen wins (dedup ledger).
    /// When nil, the record is added as is (the source already emits per-request deltas).
    public var messageId: String?

    public init(sessionId: String, agent: String = "", ts: Timestamp, model: String, input: Int = 0, output: Int = 0,
                cacheRead: Int = 0, cacheWrite: Int = 0, cacheWrite1h: Int = 0, messageId: String? = nil, cwd: String? = nil) {
        self.sessionId = sessionId; self.agent = agent; self.ts = ts; self.model = model
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h; self.messageId = messageId; self.cwd = cwd
    }
    public var total: Int { input + output + cacheRead + cacheWrite }
}

/// One tool invocation (`tool_use` block, Codex `function_call`).
public struct ToolCall: Sendable, Equatable {
    public var sessionId: String
    public var ts: Timestamp
    public var name: String
    /// Source id of the call (`toolu_...`); used to drop duplicates of re-written records. Optional.
    public var callId: String?
    public init(sessionId: String, ts: Timestamp, name: String, callId: String? = nil) {
        self.sessionId = sessionId; self.ts = ts; self.name = name; self.callId = callId
    }
}

/// A point in time when the agent did something (model output, tool result). Feeds `working` intervals.
public struct ActivityEvent: Sendable, Equatable {
    public enum Kind: String, Sendable { case agent }
    public var sessionId: String
    public var ts: Timestamp
    public var kind: Kind
    /// Working directory of the record (sub-agents often work elsewhere than their session); nil = unknown.
    public var cwd: String?
    public init(sessionId: String, ts: Timestamp, kind: Kind = .agent, cwd: String? = nil) {
        self.sessionId = sessionId; self.ts = ts; self.kind = kind; self.cwd = cwd
    }
}

/// A message typed by the human. Starts a `working` turn and counts as a user action for user time, unless another
/// session typed it (see `Relay`). `text` only feeds the search index (if enabled) and task key extraction; it is
/// never stored as plain text.
public struct UserMessage: Sendable, Equatable {
    public var sessionId: String
    public var ts: Timestamp
    public var text: String?
    public var cwd: String?
    /// Sent through a channel plugin (Telegram…): always the human's, never taken for a relay.
    public var channel: Bool
    public init(sessionId: String, ts: Timestamp, text: String? = nil, cwd: String? = nil, channel: Bool = false) {
        self.sessionId = sessionId; self.ts = ts; self.text = text; self.cwd = cwd; self.channel = channel
    }
}

/// The agent typed into a terminal (`tmux send-keys` / `paste-buffer`): a message that shows up in another session
/// right after is that session's driver talking, not the human.
public struct Relay: Sendable, Equatable {
    public var sessionId: String
    public var ts: Timestamp
    /// `-t` targets as tmux session names (lower case, window/pane cut off); "" = a target that is not a plain name
    /// (`$var`, `%pane`) or none given.
    public var targets: [String]
    public init(sessionId: String, ts: Timestamp, targets: [String]) {
        self.sessionId = sessionId; self.ts = ts; self.targets = targets
    }
}

/// Subscription limit reading (Claude status line `rate_limits`, Codex `token_count.rate_limits`).
public struct LimitSnapshot: Sendable, Equatable {
    public var tool: ToolKind
    /// `five_hour` / `seven_day` (Claude), `primary` / `secondary` (Codex main limit), `<limit_id>:primary` /
    /// `<limit_id>:secondary` (other Codex limits, e.g. `premium`).
    public var window: String
    public var usedPct: Double
    public var resetsAt: Timestamp?
    public var windowMinutes: Int?
    public var ts: Timestamp
    /// Whose subscription: `Accounts.defaultName` (no `CLAUDE_CONFIG_DIR`, Codex) or the account's name.
    public var account: String
    public init(tool: ToolKind, window: String, usedPct: Double, resetsAt: Timestamp? = nil, windowMinutes: Int? = nil,
                ts: Timestamp, account: String = Accounts.defaultName) {
        self.tool = tool; self.window = window; self.usedPct = usedPct; self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes; self.ts = ts; self.account = account
    }
}
