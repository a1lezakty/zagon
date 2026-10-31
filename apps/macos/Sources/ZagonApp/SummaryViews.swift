import SwiftUI
import ZagonUIModel

/// Summaries of a day or a period are written by `zagon summary` of the task source (the first checked server, else
/// this Mac), off the main thread; what it answers is kept in this Mac's store and shows at once.
extension AppState {
    func summaryJob(_ key: String) -> SummaryJob { summaries.jobs[key] ?? SummaryJob() }

    /// The store's summary, or the last answer when that is newer (the pull has not brought it yet).
    func keptSummary(_ key: String) -> KeptSummary? { SummaryJob.newest(provider.summary(key), summaries.jobs[key]?.result) }

    enum SummaryOutcome { case kept(KeptSummary), confirm(SummaryPlan) }

    /// A day: written now (or again, `refresh`). A period: its plan first; days without a summary are confirmed, then
    /// written one by one with progress, then the period.
    func writeSummary(from: String, to: String, refresh: Bool) {
        if from == to {
            runSummary(from) { b, f, _ in .kept(try b.summary(day: from, refresh: refresh, lang: f.lang.rawValue)) }
            return
        }
        runSummary(SummaryJob.key(from, to)) { b, f, say in
            let plan = try b.summaryPlan(from: from, to: to)
            if plan.needsConfirm { return .confirm(plan) }
            return .kept(try await b.writePeriod(plan, lang: f.lang.rawValue) { await say(Self.progress($0, f)) })
        }
    }

    /// The yes to "N days without a summary".
    func confirmSummary(_ plan: SummaryPlan) {
        summaries.jobs[plan.key]?.confirm = nil
        runSummary(plan.key) { b, f, say in
            .kept(try await b.writePeriod(plan, lang: f.lang.rawValue) { await say(Self.progress($0, f)) })
        }
    }

    func cancelSummary(_ key: String) { summaries.jobs[key]?.confirm = nil }

    /// "Cancel" while writing: the call under way stops, there too; the days written before stay.
    func stopSummary(_ key: String) {
        guard let t = summaries.jobs[key]?.task, summaries.jobs[key]?.stopping == false else { return }
        t.cancel()
        summaries.jobs[key]?.stopping = true
        summaries.jobs[key]?.progress = f.t("sum.stopping")
    }

    nonisolated static func progress(_ s: TaskBackend.SummaryStep, _ f: Fmt) -> String {
        switch s {
        case .day(let n, let of): f.t("sum.progress", String(n), String(of))
        case .period: f.t("sum.writing")
        }
    }

    private func runSummary(_ key: String,
                            _ job: @escaping (TaskBackend, Fmt, _ say: @escaping (String) async -> Void) async throws -> SummaryOutcome) {
        guard !summaryJob(key).running else { return }
        let f = self.f
        guard let s = currentTaskSource, let backend = taskBackend?(s) else {
            summaries.jobs[key, default: SummaryJob()].error = f.t("sum.noSource")
            return
        }
        // "this Mac" / "server build-box", as the answers name it.
        let source = s == .local ? f.t("sum.src.local") : f.t("sum.src.server", sourceName(s)), period = key.contains("..")
        var j = summaryJob(key)
        j.running = true; j.stopping = false; j.error = nil; j.notice = nil; j.confirm = nil; j.progress = f.t("sum.writing")
        summaries.jobs[key] = j
        let store = provider as? StoreDataProvider
        let task = Task.detached {
            let outcome: Result<SummaryOutcome, Error>
            do {
                outcome = .success(try await job(backend, f) { text in
                    await MainActor.run { if self.summaries.jobs[key]?.stopping == false { self.summaries.jobs[key]?.progress = text } }
                })
            } catch {
                outcome = .failure(error)
            }
            let stopped = Task.isCancelled
            if case .success(.kept(let k)) = outcome { store?.keep(k) }
            await MainActor.run {
                var j = self.summaryJob(key)
                j.running = false; j.progress = nil; j.task = nil; j.stopping = false
                switch outcome {
                case .success(.kept(let k)):
                    j.result = k
                    if k.doc.items.isEmpty { j.error = f.t(period ? "sum.noCards.period" : "sum.noCards", source) }
                    if let e = k.noCli { j.notice = f.t("sum.noCLI", e, source) }
                    else if let e = k.aiError {
                        j.notice = f.t(k.engine == "none" ? "sum.aiFailed" : "sum.aiFailed.kept", Remote.scrubHomes(e), source)
                    }
                case .success(.confirm(let p)) where !stopped: j.confirm = p
                case .success(.confirm), .failure where stopped:
                    j.notice = f.t(period ? "sum.stopped.period" : "sum.stopped")
                    Log.shared.write("summary \(key): cancelled")
                case .failure(let e):
                    j.error = Remote.scrubHomes(String(describing: e))
                    Log.shared.write("summary \(key): \(j.error ?? "")")
                }
                self.summaries.jobs[key] = j
            }
        }
        // Set before the task's end can run on the main actor.
        summaries.jobs[key]?.task = task
    }

    /// `[summary] time` in this Mac's config.toml, then `zagon summary --at` on every checked server.
    func setSummaryTime(_ minutes: Int?) {
        editNotify { $0.summaryAt = minutes }
        summaries.atMessage = nil
        guard notifyError == nil, let make = taskBackend, !remoteHosts.isEmpty else { return }
        let backends = remoteHosts.map { ($0, make(.server($0))) }, at = minutes.map(NotifySettings.clock), f = self.f
        Task.detached {
            var sent: [String] = [], failed: [String] = []
            for (h, b) in backends {
                do { try b.setSummaryTime(at); sent.append(h) } catch {
                    failed.append(f.t("settings.summary.notSent", h, Remote.scrubHomes(String(describing: error))))
                }
            }
            let message = ((sent.isEmpty ? [] : [f.t("settings.summary.sent", sent.joined(separator: ", "))]) + failed).joined(separator: "\n")
            await MainActor.run { [sent] in
                self.summaries.atMessage = message
                for h in sent { self.summaries.serverAt[h] = at ?? "off" }
            }
        }
    }

    /// `[summary] time` of every checked server not asked yet (the settings show it): one call at a time per server,
    /// and one that did not answer is asked again only when the settings are opened again.
    func loadSummaryTimes() {
        guard let make = taskBackend else { return }
        let hosts = summaries.toAsk(remoteHosts)
        guard !hosts.isEmpty else { return }
        summaries.asking.formUnion(hosts)
        let ask = hosts.map { ($0, make(.server($0))) }
        Task.detached {
            for (h, b) in ask {
                let at = try? b.summaryTime()
                await MainActor.run {
                    self.summaries.asking.remove(h)
                    guard let at else { self.summaries.unanswered.insert(h); return }
                    // A time sent meanwhile is newer than this answer.
                    if self.summaries.serverAt[h] == nil { self.summaries.serverAt[h] = at }
                }
            }
        }
    }
}

/// "Write a summary" / "Refresh" with the progress next to it and a short error line under it; a period asks first
/// when its days need AI calls.
struct SummaryButton: View {
    @EnvironmentObject private var app: AppState
    let from: String
    let to: String
    let has: Bool

    var body: some View {
        let f = app.f, key = SummaryJob.key(from, to), job = app.summaryJob(key)
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 10) {
                if job.running, let p = job.progress {
                    Text(p).font(.system(size: 12)).foregroundColor(Z.muted).lineLimit(1)
                }
                if job.running {
                    PillButton(title: f.t("sum.stop"), height: 30, radius: 8, fontSize: 12) { app.stopSummary(key) }
                        .disabled(job.stopping || job.task == nil)
                        .opacity(job.stopping ? 0.5 : 1)
                } else {
                    PillButton(title: f.t(has ? "sum.refresh" : "sum.make"), primary: !has, height: 30, radius: 8, fontSize: 12) {
                        app.writeSummary(from: from, to: to, refresh: has)
                    }
                }
            }
            if let e = job.error {
                Text(f.t("sum.failed", e)).font(.system(size: 12)).foregroundColor(Z.bad).multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let n = job.notice {
                Text(n).font(.system(size: 12)).foregroundColor(Z.muted).multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert(job.confirm.map { f.t.plural("sum.confirm", $0.missing.count, String($0.calls)) } ?? "",
               isPresented: Binding(get: { app.summaryJob(key).confirm != nil }, set: { if !$0 { app.cancelSummary(key) } }),
               presenting: job.confirm) { plan in
            Button(f.t("sum.confirm.go")) { app.confirmSummary(plan) }
            Button(f.t("sum.cancel"), role: .cancel) { app.cancelSummary(key) }
        } message: { _ in
            Text(f.t("sum.confirm.note"))
        }
    }
}

/// The overview, the main points of a period and one card per line of work; a click on a card's title folds it.
struct SummaryCards: View {
    let vm: SummaryVM
    /// The day screen shows its own note (with the weekly share when known).
    var note = true
    @State private var folded: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(vm.overview).font(.system(size: 13)).foregroundColor(Z.text).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if !vm.main.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(vm.mainLabel).font(.system(size: 13, weight: .semibold)).foregroundColor(Z.text)
                    ForEach(vm.main.indices, id: \.self) { bullet(vm.main[$0]) }
                }
            }
            ForEach(vm.cards.indices, id: \.self) { card($0) }
            if note { Text(vm.note).font(.system(size: 12)).foregroundColor(Z.muted).fixedSize(horizontal: false, vertical: true) }
        }
    }

    func card(_ i: Int) -> some View {
        let c = vm.cards[i], open = !folded.contains(i)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if open { folded.insert(i) } else { folded.remove(i) }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Z.muted).frame(width: 10).padding(.top, 4)
                    Dot(color: Color(hex: c.color)).padding(.top, 5)
                    Text(c.title).font(.system(size: 13, weight: .semibold)).foregroundColor(Z.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    if let was = c.was { labeled(vm.wasLabel, was) }
                    if !c.done.isEmpty {
                        Text(vm.doneLabel + ":").font(.system(size: 13, weight: .medium)).foregroundColor(Z.secondary)
                        ForEach(c.done.indices, id: \.self) { bullet(c.done[$0]) }
                    }
                    if let left = c.left { labeled(vm.leftLabel, left) }
                }
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Z.inset))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Z.border))
    }

    func labeled(_ label: String, _ text: String) -> some View {
        (Text(label + ": ").fontWeight(.medium).foregroundColor(Z.secondary) + Text(text).foregroundColor(Z.body))
            .font(.system(size: 13)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }

    func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundColor(Z.muted)
            Text(text).foregroundColor(Z.body).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
    }
}

/// "Week summary" / "Month summary" / a chosen range: the cards when written, else the button to write it.
struct PeriodSummaryCard<Extra: View>: View {
    @EnvironmentObject private var app: AppState
    let title: String
    let from: String
    let to: String
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        let f = app.f, key = SummaryJob.key(from, to), kept = app.keptSummary(key)
        Card(spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                H2(text: title)
                Spacer(minLength: 0)
                extra()
                // Days that have not come yet have nothing to sum up.
                if from <= StoreDataProvider.day(f.now, app.zone) { SummaryButton(from: from, to: to, has: kept != nil) }
            }
            if let kept {
                SummaryCards(vm: SummaryVM(kept, period: true, sources: (kept.doc.hosts ?? []).map(app.provider.hostName), f)).id(key)
            } else {
                Text(f.t("sum.none")).font(.system(size: 13)).foregroundColor(Z.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension PeriodSummaryCard where Extra == EmptyView {
    init(title: String, from: String, to: String) { self.init(title: title, from: from, to: to) { EmptyView() } }
}

/// Two dates for "Summary for a period…".
struct RangeSheet: View {
    @EnvironmentObject private var app: AppState
    @Binding var shown: Bool
    let pick: (Date, Date) -> Void
    @State private var from = Date()
    @State private var to = Date()

    var body: some View {
        let f = app.f
        VStack(alignment: .leading, spacing: 14) {
            H2(text: f.t("sum.period").replacingOccurrences(of: "…", with: ""))
            DatePicker(f.t("sum.from"), selection: $from, in: ...to, displayedComponents: .date)
            DatePicker(f.t("sum.to"), selection: $to, in: from...max(from, f.now), displayedComponents: .date)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                PillButton(title: f.t("sum.cancel"), height: 30, radius: 8, fontSize: 12) { shown = false }
                PillButton(title: f.t("sum.show"), primary: true, height: 30, radius: 8, fontSize: 12) {
                    pick(from, to)
                    shown = false
                }
            }
        }
        .padding(20)
        .frame(width: 360)
        .environment(\.timeZone, app.zone)
        .onAppear {
            to = f.startOfDay(f.now)
            from = f.addDays(-6, to: to)
        }
    }
}
