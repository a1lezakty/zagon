/// `run_in_background` tool calls (Bash, Agent) in a Claude Code transcript and the task-notifications that name
/// them (`<tool-use-id>`), with their times. Reads only what was appended since the last update.
/// ponytail: the maps grow for the life of the daemon (ids only, a few thousand per busy day).
struct BackgroundCalls {
    var offset = 0
    var launched: [String: Double] = [:]
    var notified: [String: Double] = [:]

    mutating func update(_ path: String) {
        if (Sys.fileSize(path) ?? 0) < offset { self = BackgroundCalls() }  // truncated or replaced: read again
        offset = Lines.each(path, from: offset) { line in
            // Agent calls also carry it as the string "true".
            if line.has("\"run_in_background\":true") || line.has("\"run_in_background\":\"true\""), line.has("\"type\":\"assistant\""),
               let v = JValue.parse(Array(line)) {
                let ts = v["timestamp"]?.string.flatMap(Time.parseISO) ?? 0
                for b in v["message"]?["content"]?.array ?? [] where b["type"]?.string == "tool_use"
                    && [JValue.bool(true), .string("true")].contains(b["input"]?["run_in_background"] ?? .null) {
                    if let id = b["id"]?.string { launched[id] = ts }
                }
            }
            guard line.has("<tool-use-id>") else { return }
            // a queued or delivered task-notification; its time is the record's
            let text = String(decoding: line, as: UTF8.self)
            let ts = JValue.topLevelStrings(Array(line), keys: ["timestamp"])?["timestamp"].flatMap(Time.parseISO) ?? 0
            for part in text.split(separator: "<tool-use-id>").dropFirst() {
                if let id = part.split(separator: "<", maxSplits: 1).first, notified[String(id)] == nil { notified[String(id)] = ts }
            }
        }
    }

    /// Calls launched in [since, now] with no notification up to `now`.
    func pending(since: Double, now: Double) -> [String] {
        launched.filter { id, ts in ts >= since && ts <= now && !(notified[id].map { $0 <= now } ?? false) }.map(\.key)
    }
}
