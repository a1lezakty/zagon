import SwiftUI
import ZagonUIModel

/// Settings → Jira: this Mac's `[jira]` (the CLI inside Zagon.app reads it, as on a server) and, read only, what each
/// checked server says of its own.
struct JiraCard: View {
    @EnvironmentObject private var app: AppState
    /// What is typed; nil = the saved value. The token is never filled in from its file.
    @State private var url: String?
    @State private var email: String?
    @State private var token = ""
    @State private var checking = false
    @State private var result: (ok: Bool, text: String)?
    @State private var confirmOff = false

    var body: some View {
        let f = app.f, saved = app.jira, servers = app.remoteHosts
        let u = Binding(get: { url ?? saved?.url ?? "" }, set: { url = $0; result = nil })
        let e = Binding(get: { email ?? saved?.email ?? "" }, set: { email = $0; result = nil })
        let t = Binding(get: { token }, set: { token = $0; result = nil })
        Card(spacing: 12) {
            Text(f.t("settings.jira")).font(.system(size: 15, weight: .semibold))
            Text(f.t("settings.jira.note")).font(.system(size: 13)).foregroundColor(Z.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !servers.isEmpty {
                ForEach(servers, id: \.self) { h in
                    let s = app.serverJira[h]
                    HStack(spacing: 8) {
                        Dot(color: s == .on ? Z.working : s == nil || s == .off ? Z.faint : Z.bad, size: 7)
                        Text(Self.server(h, s, f)).lineLimit(2).truncationMode(.middle)
                    }
                }
                Text(f.t("settings.jira.servers")).font(.system(size: 12)).foregroundColor(Z.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Caps(text: f.t("source.local")).padding(.top, 6)
            }
            HStack(spacing: 8) {
                Dot(color: saved == nil ? Z.faint : saved?.ready == true ? Z.working : Z.bad, size: 7)
                Text(saved.map { f.t($0.ready ? "settings.jira.on" : "settings.jira.broken", URL(string: $0.url)?.host ?? $0.url, $0.email) }
                     ?? f.t("settings.jira.none"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Not while a check runs: its answer is about what was typed when it started.
            Group {
                row(f.t("settings.jira.url")) { Field(placeholder: "https://your-team.atlassian.net", text: u, height: 30) }
                row(f.t("settings.jira.email")) { Field(placeholder: "you@example.com", text: e, height: 30) }
                row(f.t("settings.jira.token")) {
                    Field(placeholder: saved?.ready == true ? f.t("settings.jira.tokenKept") : "", text: t, height: 30, secure: true)
                }
            }
            .disabled(checking)
            HStack(spacing: 8) {
                PillButton(title: f.t("settings.jira.check"), busy: checking) { check(f, u.wrappedValue, e.wrappedValue) }
                PillButton(title: f.t("settings.jira.save"), primary: true) { save(f, u.wrappedValue, e.wrappedValue) }
                if saved != nil { PillButton(title: f.t("settings.jira.off")) { confirmOff = true } }
            }
            .disabled(checking)
            if let r = result {
                Text(r.text).font(.system(size: 12)).foregroundColor(r.ok ? Z.working : Z.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 13)).foregroundColor(Z.text)
        .frame(maxWidth: 640, alignment: .leading)
        .confirmationDialog(f.t("settings.jira.offConfirm"), isPresented: $confirmOff) {
            Button(f.t("settings.jira.off"), role: .destructive) { disconnect(f) }
        } message: {
            Text(f.t("settings.jira.offNote"))
        }
        .task(id: servers) { app.loadServerJira(servers) }
    }

    func row<V: View>(_ title: String, @ViewBuilder _ field: () -> V) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13)).foregroundColor(Z.body).frame(width: 90, alignment: .leading)
            field().frame(maxWidth: 360).accessibilityLabel(title)
        }
    }

    static func server(_ host: String, _ s: JiraSettings.Server?, _ f: Fmt) -> String {
        switch s {
        case .on: f.t("settings.jira.server.on", host)
        case .off: f.t("settings.jira.server.off", host)
        case .failed(let why): f.t("settings.jira.server.failed", host, why)
        case nil: f.t("settings.jira.server.asking", host)
        }
    }

    /// The form as it is to be checked or saved, or why it cannot be.
    func form(_ f: Fmt, _ url: String, _ email: String) -> (url: String, email: String, token: String)? {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines), t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = JiraSettings.problem(url: u, email: e, token: t, saved: app.jira?.ready == true) {
            result = (false, f.t(p))
            return nil
        }
        return (u, e, t)
    }

    /// A real request with what is typed (the saved token when the field is empty); nothing is saved.
    func check(_ f: Fmt, _ url: String, _ email: String) {
        guard let v = form(f, url, email), app.store != nil else { return }  // the samples send nothing
        let saved = app.jira
        checking = true
        result = nil
        Task.detached {
            let r = Result { try JiraSettings.check(url: v.url, email: v.email, token: v.token, saved: saved) }
            await MainActor.run {
                checking = false
                switch r {
                case .success: result = (true, f.t("settings.jira.ok"))
                case .failure(let e):
                    result = (false, JiraSettings.why(e, f))
                    Log.shared.write("jira check failed: \(Log.scrub(String(describing: e)))")
                }
            }
        }
    }

    func save(_ f: Fmt, _ url: String, _ email: String) {
        guard let v = form(f, url, email), app.store != nil else { return }  // the samples write nothing
        // Whatever happened, the card shows what the file says now.
        defer { app.jiraChanged() }
        do {
            try JiraSettings.save(url: v.url, email: v.email, token: v.token, saved: app.jira, configPath: NotifySettings.configPath,
                                  tokenPath: JiraSettings.tokenPath)
            self.url = nil; self.email = nil; token = ""
            result = (true, f.t("settings.jira.saved"))
            Log.shared.write("jira saved")
        } catch {
            result = (false, f.t("settings.jira.notSaved", Log.scrub(String(describing: error))))
        }
    }

    func disconnect(_ f: Fmt) {
        guard app.store != nil else { return }
        defer { app.jiraChanged() }
        do {
            try JiraSettings.disconnect(configPath: NotifySettings.configPath, tokenPath: JiraSettings.tokenPath)
            url = nil; email = nil; token = ""
            result = (true, f.t("settings.jira.removed"))
            Log.shared.write("jira disconnected")
        } catch {
            result = (false, f.t("settings.jira.notSaved", Log.scrub(String(describing: error))))
        }
    }
}

extension AppState {
    /// After this Mac's Jira changed: read it again; this Mac's tasks load anew when shown (with or without Jira).
    func jiraChanged() {
        jira = JiraSettings.load(NotifySettings.configPath)
        guard var c = taskCache[.local] else { return }
        c.list = nil; c.drafts = nil; c.cards = [:]; c.plans = [:]
        taskCache[.local] = c
    }

    /// Asks each server's zagon whether its Jira is connected (off the main thread).
    func loadServerJira(_ hosts: [String]) {
        guard let make = taskBackend else { return }
        for h in hosts {
            let b = make(.server(h))
            Task.detached {
                let s = JiraSettings.server(b)
                await MainActor.run { self.serverJira[h] = s }
            }
        }
    }

    /// Jira is known not to work where `s` keeps its tasks.
    func jiraOff(_ s: TaskBackend.Source) -> Bool {
        if case .server(let h) = s { return serverJira[h] == .off }
        return jira?.ready != true
    }

    /// The page of issue `key` when the tasks come from this Mac and its Jira is connected.
    // ponytail: a server's Jira address is not known here; add when its CLI sends it.
    func jiraPage(_ key: String) -> URL? {
        currentTaskSource == .local ? jira?.browse(key) : nil
    }
}
