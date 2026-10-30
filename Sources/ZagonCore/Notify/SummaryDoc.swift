#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A written summary of a day or a period: an overview and one card per line of work (project → task or theme).
/// Kept as JSON in `summary.text` under the key of its days (`2026-10-30`, `2026-10-26..2026-11-01`); rows written
/// before it hold free text (`decode` gives nil for them).
public struct SummaryDoc: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var project: String
        /// Task key (registry or Jira) when the work is linked to one.
        public var key: String?
        /// The task's title, or a short name of the theme.
        public var title: String
        /// What it started from: the ask or the problem.
        public var was: String?
        public var done: [String]
        /// What is left or comes next, when it shows.
        public var left: String?
        /// Session time and API price of its sessions.
        public var sec: Double
        public var cost: Double

        public init(project: String, key: String? = nil, title: String, was: String? = nil, done: [String] = [],
                    left: String? = nil, sec: Double = 0, cost: Double = 0) {
            self.project = project; self.key = key; self.title = title; self.was = was; self.done = done; self.left = left
            self.sec = sec; self.cost = cost
        }

        /// `PROJ-1 Title`, or the theme.
        public var heading: String { key.map { title.isEmpty ? $0 : "\($0) \(title)" } ?? title }
    }

    /// `ru` | `en`: the language it is written in.
    public var lang: String
    public var from: String
    public var to: String
    /// The day (or the period) in two or three lines.
    public var overview: String
    /// The main points of a period; empty for a day.
    public var main: [String] = []
    public var items: [Item]

    public init(lang: String, from: String, to: String, overview: String, main: [String] = [], items: [Item]) {
        self.lang = lang; self.from = from; self.to = to; self.overview = overview; self.main = main; self.items = items
    }

    /// The `summary.day` of a range: the day itself, or `from..to`.
    public static func key(_ from: String, _ to: String) -> String { from == to ? from : from + ".." + to }
    public var key: String { Self.key(from, to) }

    /// A stored summary; nil for free text from before.
    public static func decode(_ text: String) -> SummaryDoc? {
        guard text.hasPrefix("{") else { return nil }
        return try? JSONDecoder().decode(SummaryDoc.self, from: Data(text.utf8))
    }

    /// One line of JSON, as stored.
    public var json: String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    var words: Words { lang == "en" ? .english : .ru }

    /// What a card says for a task's day ("what was done" of the task card and the worklog).
    public func taskText(_ i: Item) -> String {
        let w = words
        var out: [String] = []
        if let was = i.was { out.append(w.t("Было: ", "Was: ") + was) }
        if !i.done.isEmpty { out.append(w.t("Сделано: ", "Done: ") + i.done.joined(separator: "; ")) }
        if let left = i.left { out.append(w.t("Осталось: ", "Left: ") + left) }
        return out.joined(separator: "\n")
    }

    /// The summary as text: `markdown` for files and the Mac's export, plain for messages and the terminal.
    public func text(markdown: Bool = false) -> String {
        let w = words
        var out = [overview]
        if !main.isEmpty {
            out.append(markdown ? "**" + w.t("Главное за период", "Main points") + "**\n\n" + main.map { "- " + $0 }.joined(separator: "\n")
                                : w.t("Главное:", "Main points:") + "\n" + main.map { "• " + $0 }.joined(separator: "\n"))
        }
        for i in items {
            let numbers = [i.sec > 0 ? w.dur(i.sec) : nil, i.cost > 0 ? w.usd(i.cost) : nil].compactMap { $0 }.joined(separator: ", ")
            let head = (i.project.isEmpty ? "" : i.project + " · ") + i.heading + (numbers.isEmpty ? "" : " — " + numbers)
            var card = [markdown ? "### " + head : "▸ " + head]
            func label(_ ru: String, _ en: String) -> String { markdown ? "**" + w.t(ru, en) + ":**" : w.t(ru, en) + ":" }
            if let was = i.was { card.append(label("Что было", "What it was") + " " + was) }
            if !i.done.isEmpty {
                card.append(label("Что сделано", "What was done") + "\n" + i.done.map { (markdown ? "- " : "• ") + $0 }.joined(separator: "\n"))
            }
            if let left = i.left { card.append(label("Что осталось", "What is left") + " " + left) }
            out.append(card.joined(separator: markdown ? "\n\n" : "\n"))
        }
        return out.joined(separator: "\n\n")
    }

    // MARK: the AI's answer

    /// A numbered source of the digest (a session of the day, a card of a period's day): what its card counts.
    struct Ref { var project: String; var sec: Double; var cost: Double; var keys: [String] = [] }

    static let maxItems = 12, maxDone = 5

    /// Reads the AI's answer: one JSON object (code fences or words around it are dropped) with `overview`, `main`
    /// and `items` of `{project, task, title, refs, was, done, left}`. Time and price come from the numbered `refs`
    /// (a ref in several items is split between them), never from the AI; a task key counts only when it is one of
    /// `tasks` (key → title) and a ref of the card is linked to it, a project only when a ref or the digest has it.
    /// Returns the refs no item named. nil = no usable answer.
    static func parse(answer: String, refs: [Ref], tasks: [String: String], lang: String, from: String, to: String)
        -> (doc: SummaryDoc, unused: [Int])? {
        let a = Array(answer.utf8)
        guard let lo = a.firstIndex(of: UInt8(ascii: "{")), let hi = a.lastIndex(of: UInt8(ascii: "}")), lo < hi,
              let v = JValue.parse(Array(a[lo...hi])) else { return nil }
        func line(_ x: JValue?, _ max: Int) -> String? {
            guard let s = x?.string else { return nil }
            let t = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if t.isEmpty || t == "-" || t == "—" { return nil }
            return t.count > max ? String(t.prefix(max - 1)) + "…" : t
        }
        let projects = Set(refs.map(\.project))
        let upper = Dictionary(tasks.map { ($0.key.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var raw: [(item: Item, refs: [Int])] = []
        for x in v["items"]?.array ?? [] {
            var rs: [Int] = []
            // Numbers, or strings of them ("3", "3, 4"); anything out of range is ignored.
            for r in x["refs"]?.array ?? [] {
                let ns = r.double.map { [$0.isFinite && abs($0) < 1e6 ? Int($0) : 0] }
                    ?? (r.string ?? "").split(whereSeparator: { !$0.isNumber }).map { Int($0.prefix(6)) ?? 0 }
                for n in ns where n >= 1 && n <= refs.count && !rs.contains(n - 1) { rs.append(n - 1) }
            }
            let done = (x["done"]?.array ?? []).compactMap { line($0, 220) }.prefix(maxDone)
            let key = line(x["task"], 40).flatMap { upper[$0.uppercased()] }.flatMap { k in
                rs.contains { refs[$0].keys.contains { $0.uppercased() == k.key.uppercased() } } ? k : nil
            }
            guard !done.isEmpty, let title = line(x["title"], 120) ?? key.map({ $0.value }) else { continue }
            let named = line(x["project"], 80).flatMap { projects.contains($0) ? $0 : nil }
            guard let project = rs.first.map({ refs[$0].project }) ?? named else { continue }
            raw.append((Item(project: project, key: key?.key, title: key.map { title == $0.key ? $0.value : title } ?? title,
                             was: line(x["was"], 300), done: Array(done), left: line(x["left"], 300)), rs))
            if raw.count == maxItems { break }
        }
        guard !raw.isEmpty else { return nil }
        let overview = line(v["overview"], 600) ?? ""  // the caller puts its own in
        var share = [Int](repeating: 0, count: refs.count)
        for r in raw { for i in r.refs { share[i] += 1 } }
        var items = raw.map { r -> Item in
            var it = r.item
            for i in r.refs { it.sec += refs[i].sec / Double(share[i]); it.cost += refs[i].cost / Double(share[i]) }
            return it
        }
        // Sources no card named count for the first card of their project.
        var unused: [Int] = []
        for (i, n) in share.enumerated() where n == 0 {
            if let j = items.firstIndex(where: { $0.project == refs[i].project }) {
                items[j].sec += refs[i].sec; items[j].cost += refs[i].cost
            } else { unused.append(i) }
        }
        let main = (v["main"]?.array ?? []).compactMap { line($0, 220) }.prefix(6)
        return (SummaryDoc(lang: lang, from: from, to: to, overview: overview, main: Array(main), items: items), unused)
    }

    /// The JSON the AI is asked for (the prompt shows it).
    static func answerShape(_ w: Words, period: Bool) -> String {
        w.t("""
            {"overview": "итог \(period ? "периода" : "дня") в 2–3 строки",\(period ? "\n \"main\": [\"главное за период\", \"…\"]," : "")
             "items": [{"project": "проект как в выжимке", "task": "ключ задачи из выжимки или пусто", \
            "title": "название задачи или короткая тема", "refs": [номера из выжимки], "was": "с чем пришли, какая проблема", \
            "done": ["что сделано", "…"], "left": "что осталось или пусто"}]}
            """, """
            {"overview": "the \(period ? "period" : "day") in 2-3 lines",\(period ? "\n \"main\": [\"main point of the period\", \"…\"]," : "")
             "items": [{"project": "project as in the digest", "task": "task key from the digest or empty", \
            "title": "task title or a short theme", "refs": [numbers from the digest], "was": "what it started from, the problem", \
            "done": ["what was done", "…"], "left": "what is left, or empty"}]}
            """)
    }
}

extension Words {
    /// `<$1`, `$12` (API prices, as the CLI shows them).
    func usd(_ x: Double) -> String { x > 0 && x < 1 ? "<$1" : "$\(Int(x.rounded()))" }
}
