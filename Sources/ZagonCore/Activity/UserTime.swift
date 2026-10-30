/// Which user actions are the human's. A message typed in session W at `t` (`user_action.kind = 'msg'`) was sent by
/// another session when one of them typed into a terminal (`relay`) in [t - relayBefore, t + relayAfter]: workers
/// driven over `tmux send-keys` look exactly like a human at the keyboard in their transcripts, and their messages land
/// 0–26 s after the driver's call. When W has a name (`claude --name`, `/rename`: a Claude title of rank >= agent
/// name) only a relay aimed at it counts (its `-t` target equals W's name or one is a prefix of the other, letters and
/// digits compared); a relay with no plain target (`$s`, `%3`, none) counts for any session. Channel messages
/// (Telegram…) are always the human's. The `read` action before a relayed message goes with it.
enum UserTime {
    static let relayBefore = 30.0, relayAfter = 5.0

    /// Points that make your time (sorted) and the number of human messages per session, over this host's sessions.
    static func humanActions(_ db: SQLite, host: String) throws -> (points: [Timestamp], messages: [String: Int]) {
        var relays: [(ts: Timestamp, session: String, target: String)] = []
        try db.query("SELECT ts, session_id, target FROM relay ORDER BY ts") {
            relays.append(($0.real(0), $0.text(1) ?? "", norm($0.text(2) ?? "")))
        }
        var names: [String: String] = [:]
        if !relays.isEmpty {
            try db.query("SELECT id, title FROM session WHERE tool = 'claude' AND title_rank >= ?",
                         [.int(Int64(TitleRank.agentName))]) {
                if let id = $0.text(0), let n = $0.text(1).map(norm), !n.isEmpty { names[id] = n }
            }
        }
        func relayed(_ session: String, _ t: Timestamp) -> Bool {
            var lo = 0, hi = relays.count
            while lo < hi { let m = (lo + hi) / 2; if relays[m].ts < t - relayBefore { lo = m + 1 } else { hi = m } }
            let name = names[session]
            while lo < relays.count, relays[lo].ts <= t + relayAfter {
                let r = relays[lo]; lo += 1
                guard r.session != session else { continue }
                guard let name, !r.target.isEmpty else { return true }
                if name.hasPrefix(r.target) || r.target.hasPrefix(name) { return true }
            }
            return false
        }
        var acts: [(session: String, ts: Timestamp, kind: String)] = []
        try db.query("""
            SELECT a.session_id, a.ts, a.kind FROM user_action a LEFT JOIN session s ON s.id = a.session_id
            WHERE coalesce(s.host, ?1) = ?1 ORDER BY a.session_id, a.ts
            """, [.text(host)]) { acts.append(($0.text(0) ?? "", $0.real(1), $0.text(2) ?? "")) }
        var points: [Timestamp] = [], messages: [String: Int] = [:]
        var session = "", nextRelayed = false  // walking back: whether the session's next action was relayed
        for a in acts.reversed() {
            if a.session != session { session = a.session; nextRelayed = false }
            switch a.kind {
            case "msg":
                nextRelayed = relayed(a.session, a.ts)
                if !nextRelayed { points.append(a.ts); messages[a.session, default: 0] += 1 }
            case "channel":
                nextRelayed = false
                points.append(a.ts); messages[a.session, default: 0] += 1
            case "read":
                if !nextRelayed { points.append(a.ts) }
            default:
                points.append(a.ts)
            }
        }
        return (points.sorted(), messages)
    }

    /// Lower-case letters and digits: `LB-web` and `lbweb` are one name.
    static func norm(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }
}
