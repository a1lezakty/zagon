/// MCP server over stdio (`zagon mcp`): JSON-RPC 2.0, one message per line. stdout carries only protocol
/// messages; anything else goes to stderr through `log`.
public final class MCPServer {
    /// Newest first; `initialize` answers with the client's version if listed here, else with the first one.
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    public let tools: [MCPTool]
    public let prompts: [MCPPrompt]
    let log: (String) -> Void

    public init(tools: [MCPTool], prompts: [MCPPrompt] = [], log: @escaping (String) -> Void = { _ in }) {
        self.tools = tools; self.prompts = prompts; self.log = log
    }

    static let instructions = """
        Zagon tracks the user's Claude Code and Codex CLI sessions on this machine: subscription limits, live \
        sessions, tokens and time per day, search over past sessions. Answers are short and carry numbers. Days \
        are local YYYY-MM-DD. Call worklog_commit only when the user explicitly asks to write worklogs to Jira, and \
        task_create_in_jira with confirm only after the user explicitly said to create that issue.
        """

    /// Serves until end of input.
    public func run(readLine: () -> String?, write: (String) -> Void) {
        while let line = readLine() {
            if let out = handle(line) { write(out) }
        }
    }

    /// One input line → one output line, or nil (notification, client response, blank line).
    public func handle(_ line: String) -> String? {
        guard line.contains(where: { !$0.isWhitespace }) else { return nil }
        guard let msg = JValue.parse(line) else { return Self.error(.null, -32700, "Parse error").compact }
        if case .array(let batch) = msg {   // JSON-RPC batches (protocol 2025-03-26)
            if batch.isEmpty { return Self.error(.null, -32600, "Invalid Request: empty batch").compact }
            let out = batch.compactMap(respond)
            return out.isEmpty ? nil : JValue.array(out).compact
        }
        return respond(msg)?.compact
    }

    func respond(_ m: JValue) -> JValue? {
        guard case .object = m else { return Self.error(.null, -32600, "Invalid Request") }
        let id = m["id"]
        guard m["jsonrpc"]?.string == "2.0", let method = m["method"]?.string else {
            // A response to a request we never send: drop it.
            if m["method"] == nil, m["result"] != nil || m["error"] != nil { return nil }
            return Self.error(Self.validId(id) ? id! : .null, -32600, "Invalid Request")
        }
        guard let id else { return nil }   // notifications: initialized, cancelled, … — nothing to answer
        guard Self.validId(id) else { return Self.error(.null, -32600, "Invalid Request: id must be a string or number") }
        let params = m["params"] ?? .object([])
        guard case .object = params else { return Self.error(id, -32602, "Invalid params: expected an object") }
        do {
            let result = try call(method, params)
            return ["jsonrpc": "2.0", "id": id, "result": result]
        } catch let e as RPCError {
            return Self.error(id, e.code, e.message)
        } catch {
            log("mcp: \(method): \(error)")
            return Self.error(id, -32603, "Internal error: \(error)")
        }
    }

    func call(_ method: String, _ p: JValue) throws -> JValue {
        switch method {
        case "initialize":
            let asked = p["protocolVersion"]?.string ?? ""
            let v = Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]
            return ["protocolVersion": .string(v),
                    "capabilities": ["tools": ["listChanged": false], "prompts": ["listChanged": false]],
                    "serverInfo": ["name": "zagon", "version": .string(zagonVersion)],
                    "instructions": .string(Self.instructions)]
        case "ping":
            return .object([])
        case "tools/list":
            return ["tools": .array(tools.map(\.descriptor))]
        case "tools/call":
            guard let name = p["name"]?.string else { throw RPCError(-32602, "Invalid params: name is required") }
            guard let tool = tools.first(where: { $0.name == name }) else { throw RPCError(-32602, "Unknown tool: \(name)") }
            let a = p["arguments"] ?? .object([])
            guard case .object = a else { throw RPCError(-32602, "Invalid params: arguments must be an object") }
            // Tool failures (bad arguments, missing data, not built in) go back to the model as isError results.
            do {
                return Self.text(try tool.run(MCPArgs(a)), isError: false)
            } catch let e as MCPToolError {
                return Self.text(e.message, isError: true)
            } catch {
                log("mcp: \(name): \(error)")
                return Self.text("\(name) failed: \(error)", isError: true)
            }
        case "prompts/list":
            return ["prompts": .array(prompts.map(\.descriptor))]
        case "prompts/get":
            guard let name = p["name"]?.string else { throw RPCError(-32602, "Invalid params: name is required") }
            guard let prompt = prompts.first(where: { $0.name == name }) else { throw RPCError(-32602, "Unknown prompt: \(name)") }
            let a = p["arguments"] ?? .object([])
            guard case .object = a else { throw RPCError(-32602, "Invalid params: arguments must be an object") }
            do {
                let text = try prompt.run(MCPArgs(a))
                return ["description": .string(prompt.description),
                        "messages": [["role": "user", "content": ["type": "text", "text": .string(text)]]]]
            } catch let e as MCPToolError {
                throw RPCError(-32602, e.message)
            }
        default:
            throw RPCError(-32601, "Method not found: \(method)")
        }
    }

    /// A string or a JSON number (JValue also takes `+1` / `.5`, which would be echoed back as invalid JSON).
    static func validId(_ id: JValue?) -> Bool {
        switch id {
        case .string?: return true
        case .number(let n)?: return n.first.map { $0 == "-" || $0.isASCII && $0.isNumber } ?? false
        default: return false
        }
    }

    static func error(_ id: JValue, _ code: Int, _ message: String) -> JValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number("\(code)"), "message": .string(message)]]
    }

    static func text(_ s: String, isError: Bool) -> JValue {
        ["content": [["type": "text", "text": .string(s)]], "isError": .bool(isError)]
    }
}

struct RPCError: Error {
    let code: Int, message: String
    init(_ code: Int, _ message: String) { self.code = code; self.message = message }
}

/// A failure the model should see as a tool result with `isError: true` (and can fix by changing arguments).
public struct MCPToolError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct MCPTool {
    public var name: String, title: String, description: String
    /// JSON Schema of `arguments`.
    public var inputSchema: JValue
    public var readOnly: Bool
    public var run: (MCPArgs) throws -> String

    public init(name: String, title: String, description: String, inputSchema: JValue = MCPSchema.object([:]),
                readOnly: Bool = true, run: @escaping (MCPArgs) throws -> String) {
        self.name = name; self.title = title; self.description = description; self.inputSchema = inputSchema
        self.readOnly = readOnly; self.run = run
    }

    var descriptor: JValue {
        ["name": .string(name), "title": .string(title), "description": .string(description), "inputSchema": inputSchema,
         // Writes here add files or records, never delete: not destructive (the spec default for writes is).
         "annotations": readOnly ? ["readOnlyHint": true] : ["readOnlyHint": false, "destructiveHint": false]]
    }
}

public struct MCPPrompt {
    public struct Argument {
        public var name: String, description: String, required: Bool
        public init(name: String, description: String, required: Bool) {
            self.name = name; self.description = description; self.required = required
        }
    }
    public var name: String, description: String
    public var arguments: [Argument]
    public var run: (MCPArgs) throws -> String

    public init(name: String, description: String, arguments: [Argument], run: @escaping (MCPArgs) throws -> String) {
        self.name = name; self.description = description; self.arguments = arguments; self.run = run
    }

    var descriptor: JValue {
        ["name": .string(name), "description": .string(description),
         "arguments": .array(arguments.map {
             ["name": .string($0.name), "description": .string($0.description), "required": .bool($0.required)]
         })]
    }
}

/// Typed access to tool arguments; a wrong type or value throws `MCPToolError` naming the argument.
public struct MCPArgs {
    public let value: JValue
    public init(_ value: JValue) { self.value = value }

    /// An empty string counts as not given (clients send "" for prompt arguments left blank).
    public func string(_ k: String) throws -> String? {
        switch value[k] {
        case nil, .null?: return nil
        case .string(let s)?: return s.isEmpty ? nil : s
        default: throw MCPToolError("\(k) must be a string")
        }
    }

    public func required(_ k: String) throws -> String {
        guard let s = try string(k) else { throw MCPToolError("\(k) is required") }
        return s
    }

    public func int(_ k: String) throws -> Int? {
        switch value[k] {
        case nil, .null?: return nil
        case .number(let n)?:
            guard let d = Double(n), d == d.rounded(), abs(d) < 1e15 else { throw MCPToolError("\(k) must be an integer") }
            return Int(d)
        default: throw MCPToolError("\(k) must be an integer")
        }
    }

    public func bool(_ k: String) throws -> Bool? {
        switch value[k] {
        case nil, .null?: return nil
        case .bool(let b)?: return b
        default: throw MCPToolError("\(k) must be true or false")
        }
    }

    public func ints(_ k: String) throws -> [Int]? {
        switch value[k] {
        case nil, .null?: return nil
        case .array(let a)?:
            return try a.map {
                guard case .number(let n) = $0, let i = Int(n) else { throw MCPToolError("\(k) must be a list of integers") }
                return i
            }
        default: throw MCPToolError("\(k) must be a list of integers")
        }
    }

    /// A local day `YYYY-MM-DD`; `today` / `yesterday` are accepted too.
    public func day(_ k: String) throws -> String? {
        guard let s = try string(k) else { return nil }
        switch s.lowercased() {
        case "today": return Time.dayString(Time.now())
        case "yesterday": return Time.addDays(Time.dayString(Time.now()), -1)
        default:
            // addDays(…, 0) normalizes the form; a different day of month means the date does not exist (02-31).
            guard let p = Time.parseDay(s), let d = Time.addDays(s, 0), Time.parseDay(d)?.2 == p.2 else {
                throw MCPToolError("\(k) must be a date YYYY-MM-DD")
            }
            return d
        }
    }
}

/// Small JSON Schema builders for `inputSchema`.
public enum MCPSchema {
    public static func object(_ props: KeyValuePairs<String, JValue>, required: [String] = []) -> JValue {
        var o: JValue = ["type": "object", "properties": .object(props.map { JValue.Member($0.key, $0.value) })]
        if !required.isEmpty { o["required"] = .array(required.map(JValue.string)) }
        o["additionalProperties"] = false
        return o
    }
    public static func string(_ d: String, enum values: [String]? = nil) -> JValue {
        var o: JValue = ["type": "string", "description": .string(d)]
        if let values { o["enum"] = .array(values.map(JValue.string)) }
        return o
    }
    public static func day(_ d: String) -> JValue {
        ["type": "string", "description": .string(d + " (YYYY-MM-DD, local; today / yesterday also work)")]
    }
    public static func integer(_ d: String, min: Int? = nil, max: Int? = nil) -> JValue {
        var o: JValue = ["type": "integer", "description": .string(d)]
        if let min { o["minimum"] = .number("\(min)") }
        if let max { o["maximum"] = .number("\(max)") }
        return o
    }
    public static func boolean(_ d: String) -> JValue { ["type": "boolean", "description": .string(d)] }
}

extension JValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral,
                  ExpressibleByDictionaryLiteral {
    public init(stringLiteral v: String) { self = .string(v) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(arrayLiteral v: JValue...) { self = .array(v) }
    public init(dictionaryLiteral v: (String, JValue)...) { self = .object(v.map { Member($0.0, $0.1) }) }
}
