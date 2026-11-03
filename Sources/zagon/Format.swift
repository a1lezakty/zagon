import ZagonCore

/// Compact terminal output.
enum Fmt {
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return one(d / 1e3) + "k"
        case ..<1_000_000_000: return one(d / 1e6) + "M"
        default: return one(d / 1e9) + "B"
        }
    }
    static func one(_ d: Double) -> String { let v = (d * 10).rounded() / 10; return v >= 100 ? "\(Int(v))" : "\(v)" }
    static func bytes(_ n: Int) -> String { n < 1 << 20 ? "\(n / 1024) KB" : one(Double(n) / 1048576) + " MB" }
    static func secs(_ s: Double) -> String { s < 10 ? "\((s * 100).rounded() / 100) s" : "\(Int(s)) s" }
    static func dur(_ s: Double) -> String {
        let m = Int((s / 60).rounded())
        return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60 < 10 ? "0" : "")\(m % 60)m"
    }
    static func pad(_ s: String, _ w: Int) -> String {
        let c = s.count
        return c >= w ? String(s.prefix(w)) : s + String(repeating: " ", count: w - c)
    }
    static func lpad(_ s: String, _ w: Int) -> String { s.count >= w ? s : String(repeating: " ", count: w - s.count) + s }
    /// USD at API prices; `unpriced` tokens (models with no known price) add "?": "$ ?" when nothing was priced,
    /// "$12+?" when part was.
    static func usd(_ x: Double, unpriced: Int = 0) -> String {
        let s = x > 0 && x < 1 ? "<$1" : "$\(Int(x.rounded()))"
        return unpriced == 0 ? s : x == 0 ? "$ ?" : s + "+?"
    }
    static let apiNote = "at API prices (for comparison; a subscription is billed differently)"
    static func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "" : "\(Int((Double(a) / Double(b) * 100).rounded()))%" }

    static let bars: [Character] = [" ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
    static func spark(_ xs: [Int]) -> String {
        let m = xs.max() ?? 0
        guard m > 0 else { return String(repeating: "·", count: xs.count) }
        return String(xs.map { $0 == 0 ? "·" : bars[max(1, Int((Double($0) / Double(m) * 8).rounded()))] })
    }

    /// "; no price: model-a, model-b" for the models left out of the cost.
    static func unpricedNote(_ r: DayReport) -> String {
        var xs = r.models.filter { $0.unpriced > 0 }.map(\.model)
        if r.models.reduce(0, { $0 + $1.unpriced }) < r.unpriced { xs.append("(no model)") }
        return xs.isEmpty ? "" : "; no price: " + xs.joined(separator: ", ")
    }

    static func tokenLine(_ t: TokenTotals) -> String {
        "\(tokens(t.total)) tokens · in \(tokens(t.input)) · out \(tokens(t.output)) · cache read \(tokens(t.cacheRead))"
            + " · cache write \(tokens(t.cacheWrite)) · \(t.requests) requests"
    }

    static func day(_ r: DayReport) {
        print("\(r.day)   \(tokenLine(r.tokens))")
        print("cost       \(usd(r.cost, unpriced: r.unpriced)) \(apiNote)" + unpricedNote(r))
        print("time       sessions \(dur(r.sessionSec)) · you \(dur(r.userSec)) · \(r.toolCalls) tool calls")
        print("hours      |\(spark(r.hours))|  0h…23h")
        if !r.models.isEmpty {
            print("models")
            for m in r.models.prefix(6) {
                print("  \(pad(m.model, 32)) \(lpad(tokens(m.tokens.total), 7)) \(lpad(pct(m.tokens.total, r.tokens.total), 4))"
                      + " \(lpad(usd(m.cost, unpriced: m.unpriced), 7))")
            }
        }
        if !r.projects.isEmpty {
            print("projects")
            for p in r.projects.prefix(8) {
                print("  \(pad(p.project.isEmpty ? "?" : p.project, 32)) \(lpad(tokens(p.tokens.total), 7)) \(lpad(dur(p.sessionSec), 8))"
                      + " \(lpad(usd(p.cost, unpriced: p.unpriced), 7))")
            }
        }
        if !r.tools.isEmpty {
            print("tools      " + r.tools.prefix(8).map { "\($0.name) \($0.count)" }.joined(separator: " · "))
        }
        if !r.sessions.isEmpty {
            print("sessions")
            sessionRows(r.sessions.prefix(10))
        }
    }

    static func sessionRows<S: Sequence>(_ xs: S) where S.Element == SessionLine {
        for s in xs {
            let id = s.id.split(separator: ":").last.map { String($0.prefix(8)) } ?? s.id
            let title = (s.title ?? s.project ?? "-") + Accounts.tag(s.account)
            var state = (s.status.map { "  \($0)" } ?? "") + (s.statusDetail.map { " (\($0))" } ?? "")
            if s.status == "waiting_input", let d = s.drivenBy {  // driven over tmux: waits for that session, not you
                state += " (waits for " + (d.isEmpty ? "another session" : "session " + d) + ")"
            }
            print("  \(id)  \(pad(title, 40)) \(pad(s.project ?? "", 16)) \(lpad(tokens(s.tokens.total), 7)) \(lpad(dur(s.workingSec), 8))"
                  + " \(lpad(usd(s.cost, unpriced: s.unpriced), 7))" + state)
        }
    }

    static func sessions(_ xs: [SessionLine]) {
        if xs.isEmpty { print("no sessions"); return }
        print("  id        \(pad("title", 40)) \(pad("project", 16)) \(lpad("tokens", 7)) \(lpad("working", 8)) \(lpad("$", 7))")
        sessionRows(xs)
        print("$ \(apiNote)" + (xs.contains { $0.unpriced > 0 } ? "; ? = tokens of models with no known price" : ""))
    }

    static func week(_ r: WeekReport) {
        print("\(r.from) … \(r.to)   \(tokenLine(r.tokens))")
        print("cost       \(usd(r.cost, unpriced: r.unpriced)) \(apiNote); previous 7 days "
              + usd(r.previousCost, unpriced: r.previousUnpriced)
              + (r.unpriced + r.previousUnpriced > 0 ? "; ? = tokens of models with no known price" : ""))
        print("time       sessions \(dur(r.sessionSec)) · you \(dur(r.userSec))   (previous 7 days: \(tokens(r.previous.total)) tokens, "
              + "sessions \(dur(r.previousSessionSec)), you \(dur(r.previousUserSec)))")
        let m = r.days.map { $0.tokens.total }.max() ?? 0
        for d in r.days {
            let w = m == 0 ? 0 : Int((Double(d.tokens.total) / Double(m) * 30).rounded())
            print("  \(d.day)  \(pad(String(repeating: "█", count: w), 30)) \(lpad(tokens(d.tokens.total), 7))"
                  + "  sessions \(lpad(dur(d.sessionSec), 7))  you \(lpad(dur(d.userSec), 7))"
                  + "  \(lpad(usd(d.cost, unpriced: d.unpriced), 7))")
        }
        if !r.projects.isEmpty {
            print("top projects")
            for p in r.projects.prefix(5) {
                print("  \(pad(p.project.isEmpty ? "?" : p.project, 32)) \(lpad(tokens(p.tokens.total), 7)) \(lpad(dur(p.sessionSec), 8))"
                      + " \(lpad(usd(p.cost, unpriced: p.unpriced), 7))")
            }
        }
    }
}
