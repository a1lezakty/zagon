#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// The summary of a week, a month or any range, made from the summaries of its days.
extension DaySummary {
    static let maxPeriodDigest = 40000
    public static let maxDays = 366

    /// `from...to` day by day (at most `maxDays`).
    public static func range(_ from: String, _ to: String) -> [String] {
        var out: [String] = [], d = from
        while d <= to, out.count < maxDays {
            out.append(d)
            guard let n = Time.addDays(d, 1) else { break }
            d = n
        }
        return out
    }

    /// Monday to Sunday of the week of `day`.
    public static func week(of day: String) -> (from: String, to: String)? {
        guard let (s, _) = Time.dayBounds(day) else { return nil }
        var t = time_t(s + 12 * 3600), v = tm()
        localtime_r(&t, &v)
        guard let monday = Time.addDays(day, -Int((v.tm_wday + 6) % 7)), let sunday = Time.addDays(monday, 6) else { return nil }
        return (monday, sunday)
    }

    /// The first and the last day of `YYYY-MM`.
    public static func month(_ ym: String) -> (from: String, to: String)? {
        let p = ym.split(separator: "-")
        guard p.count == 2, p[0].count == 4, p[1].count == 2, let y = Int(p[0]), let m = Int(p[1]), (1...12).contains(m) else { return nil }
        func pad(_ x: Int) -> String { x < 10 ? "0\(x)" : "\(x)" }
        let first = "\(y)-\(pad(m))-01", next = m == 12 ? "\(y + 1)-01-01" : "\(y)-\(pad(m + 1))-01"
        guard Time.parseDay(first) != nil, let last = Time.addDays(next, -1) else { return nil }
        return (first, last)
    }

    /// Days of the range with sessions, and those of them without a summary written by an AI (without any, when the
    /// engine is off): what `period(make: true)` writes first, one AI call each.
    public func days(_ from: String, _ to: String) throws -> (worked: [String], missing: [String]) {
        let all = DaySummary.range(from, to)
        guard !all.isEmpty else { return ([], []) }
        let hours = try Query(store: store).hours(from: from, count: all.count)
        let worked = zip(all, hours).filter { $0.1 > 0 }.map(\.0)
        let ai = engineCLI != nil
        var missing: [String] = []
        for d in worked {
            let k = try kept(d)
            if k == nil || (k!.engine == "none" && ai) { missing.append(d) }
        }
        return (worked, missing)
    }

    /// AI calls `period(make: true)` would make: one per missing day and one for the period (none with the engine off
    /// or its CLI not installed).
    public func calls(missing: Int) -> Int { engineCLI != nil ? missing + 1 : 0 }

    /// The summary of `from...to` from its days' summaries: the missing ones are written first when `make` (one AI
    /// call each, `progress(n, of, day)` before each), else left out. One more AI call turns the days' cards into the
    /// period's, with its main points; without AI the cards of one project and task are merged. Kept under `from..to`.
    @discardableResult
    public func period(_ from: String, _ to: String, make: Bool, progress: (Int, Int, String) -> Void = { _, _, _ in },
                       now: Double = Sys.now()) throws -> (doc: SummaryDoc, engine: String) {
        let (worked, missing) = try days(from, to)
        if make { for (i, d) in missing.enumerated() { progress(i + 1, missing.count, d); try self.make(d, now: now) } }
        var docs: [SummaryDoc] = []
        for d in worked { if let k = try kept(d) { docs.append(k.doc) } }
        let w = words
        // "Sessions worked": wall-clock summed over the days (the cards' times add up parallel sessions).
        let wall = try Query(store: store).hours(from: from, count: DaySummary.range(from, to).count).reduce(0, +) * 3600
        var doc = DaySummary.merge(docs, from: from, to: to, w, worked: wall), engine = "none"
        if !docs.isEmpty,
           let r = complete(DaySummary.periodInstruction(w) + DaySummary.periodDigest(docs, from: from, to: to, w), what: "period summary") {
            let all = docs.flatMap(\.items)
            var tasks: [String: String] = [:]
            for i in all { if let k = i.key { tasks[k] = i.title } }
            if case (var d, let unused)? = SummaryDoc.parse(answer: r.text, refs: all.map {
                .init(project: $0.project, sec: $0.sec, cost: $0.cost, keys: $0.key.map { [$0] } ?? []) },
                                                  tasks: tasks, lang: w.en ? "en" : "ru", from: from, to: to) {
                // Cards the AI left out keep their own (from 5 minutes of work, as for a day).
                let rest = unused.map { all[$0] }.filter { $0.sec >= 300 }
                if !rest.isEmpty {
                    d.items += DaySummary.merge([SummaryDoc(lang: d.lang, from: from, to: to, overview: "", items: rest)],
                                                from: from, to: to, w).items
                }
                if d.overview.isEmpty { d.overview = doc.overview }
                (doc, engine) = (d, r.engine)
            } else { failure.reason = "the \(r.engine) answer has no cards"; log("period summary: " + failure.reason!) }
        }
        let hosts = Set(docs.flatMap { $0.hosts ?? [] })
        doc.hosts = hosts.isEmpty ? nil : hosts.sorted()
        try save(doc, engine: engine, why: engine == "none" ? noAIReason(asked: !docs.isEmpty) : nil, now: now)
        return (doc, engine)
    }

    /// The days' cards without AI: one per project and task (or theme), time and price added up, the latest points.
    /// `worked`: the period's wall-clock session time for the overview (nil = the cards' times added up).
    static func merge(_ docs: [SummaryDoc], from: String, to: String, _ w: Words, worked: Double? = nil) -> SummaryDoc {
        var items: [SummaryDoc.Item] = []
        for i in docs.flatMap(\.items) {
            guard let j = items.firstIndex(where: { $0.project == i.project && ($0.key ?? $0.title) == (i.key ?? i.title) }) else {
                items.append(i); continue
            }
            items[j].sec += i.sec; items[j].cost += i.cost
            for x in i.done where !items[j].done.contains(x) { items[j].done.append(x) }
            items[j].left = i.left ?? items[j].left
        }
        for j in items.indices { items[j].done = Array(items[j].done.suffix(SummaryDoc.maxDone)) }
        items.sort { ($0.sec, $1.heading) > ($1.sec, $0.heading) }
        let sec = worked ?? items.reduce(0) { $0 + $1.sec }
        let overview = docs.isEmpty ? w.t("За период сессий не было.", "No sessions in this period.")
            : w.t("Дней с работой: \(docs.count), сессии работали \(w.dur(sec)), направлений: \(items.count).",
                  "Days with work: \(docs.count), sessions worked \(w.dur(sec)), lines of work: \(items.count).")
        return SummaryDoc(lang: w.en ? "en" : "ru", from: from, to: to, overview: overview,
                          main: items.prefix(3).map { "\($0.project) · \($0.heading) — \(w.dur($0.sec))" }, items: items)
    }

    /// The days' summaries for the AI, cards numbered `[1]…` across the days, at most `maxPeriodDigest` characters:
    /// when not every day fits (a month), the cards are cut to their title, time and first points, then to the title
    /// and time; days that still do not fit are left out (their cards come back as unused refs).
    static func periodDigest(_ docs: [SummaryDoc], from: String, to: String, _ w: Words) -> String {
        let head = w.t("Период: \(w.date(from)) — \(w.date(to)). Дней с работой: \(docs.count).\n",
                       "Period: \(w.date(from)) to \(w.date(to)). Days with work: \(docs.count).\n")
        /// level 0: all of it; 1: no overviews, what it was and what is left, two points; 2: titles and time.
        func render(_ level: Int) -> (text: String, complete: Bool) {
            var out = head, n = 0
            for d in docs {
                var b = "\n" + w.t("День ", "Day ") + w.date(d.from) + (level == 0 ? ": " + d.overview : "")
                for i in d.items {
                    n += 1
                    b += "\n  [\(n)] \(i.project) · \(i.heading) — \(w.dur(i.sec))."
                    if level == 0, let was = i.was { b += w.t(" Было: ", " Was: ") + was }
                    if level < 2, !i.done.isEmpty {
                        b += w.t(" Сделано: ", " Done: ") + i.done.prefix(level == 0 ? SummaryDoc.maxDone : 2).joined(separator: "; ")
                    }
                    if level == 0, let left = i.left { b += w.t(" Осталось: ", " Left: ") + left }
                }
                if out.count + b.count > maxPeriodDigest { return (out, false) }
                out += b
            }
            return (out, true)
        }
        for level in 0..<2 { let r = render(level); if r.complete { return r.text } }
        return render(2).text
    }

    static func periodInstruction(_ w: Words) -> String {
        w.t("""
            Ниже сводки рабочих дней разработчика за период: итог каждого дня и карточки направлений с номерами [N] \
            (проект, задача или тема, время, что было, что сделано, что осталось). Сведи их в сводку периода: \
            направления по проектам и задачам (одна задача за несколько дней — одна карточка, refs — номера всех её \
            карточек), что было, что сделано (2–5 пунктов о сути), что осталось (только если видно). Сверху итог \
            периода в 2–3 строки и main — 3–5 главных результатов периода. Пиши по-русски. Не добавляй того, чего нет \
            в сводках. Ответь только JSON без пояснений, по образцу:
            \(SummaryDoc.answerShape(w, period: true))

            Сводки дней:

            """, """
            Below are a developer's day summaries for a period: each day's overview and cards of its lines of work \
            numbered [N] (project, task or theme, time, what it was, what was done, what is left). Turn them into the \
            period's summary: lines of work by project and task (one task over several days is one card, refs = the \
            numbers of all its cards), what it was, what was done (2-5 points about the substance), what is left (only \
            when it shows). On top, the period in 2-3 lines and main: the 3-5 main results of the period. Write in \
            English. Do not add anything that is not in the summaries. Answer with JSON only, no comments, shaped like:
            \(SummaryDoc.answerShape(w, period: true))

            Day summaries:

            """)
    }
}
