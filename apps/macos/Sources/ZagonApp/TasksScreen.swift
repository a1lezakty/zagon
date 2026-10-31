import SwiftUI
import ZagonUIModel

struct TasksScreen: View {
    @EnvironmentObject private var app: AppState
    @State private var filter: TaskFilter = .active
    @State private var selected: String?
    @State private var find = ""
    @State private var note = ""
    @State private var newTodo: String?
    /// The suggestion being made in Jira, with the projects shown when its sheet opened.
    @State private var jiraDraft: (draft: DraftVM, jira: TaskBackend.JiraProjects)?
    @Environment(\.isSnapshot) private var snapshot
    @Environment(\.openURL) private var openURL

    var body: some View {
        let f = app.f
        let cache = app.tasksNow
        let all = app.taskBackend == nil ? app.provider.tasks() : cache.list ?? []
        let shown = find.isEmpty ? all
            : all.filter { $0.key.localizedCaseInsensitiveContains(find) || $0.title.localizedCaseInsensitiveContains(find) }
        let vm = TasksVM(shown, filter: filter, f, cards: cache.cards)
        let detail = vm.detail(selected)
        HStack(alignment: .top, spacing: 0) {
            list(vm, current: detail?.key).frame(width: 320)
            Rectangle().fill(Z.divider).frame(width: 1).frame(maxHeight: .infinity)
            if let detail {
                self.detail(detail)
            } else {
                Text(f.t(all.isEmpty || all.contains(where: \.worked) ? "tasks.empty" : "tasks.noWork")).font(.system(size: 13)).foregroundColor(Z.secondary)
                    .padding(28).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        // A draft belongs to the task it was typed for.
        .onChange(of: detail?.key) { _ in note = ""; newTodo = nil }
        .sheet(isPresented: Binding { jiraDraft != nil } set: { if !$0 { jiraDraft = nil } }) {
            if let x = jiraDraft {
                let id = x.draft.id
                JiraCreateSheet(f: f, draft: x.draft, jira: x.jira, create: { project, title, text, done in
                    app.decideDraft(id, done: done) { try $0.createInJira(id, project: project, title: title, description: text) }
                }, typeOf: { await app.jiraType($0) }, close: { jiraDraft = nil })
            }
        }
        .task(id: "\(String(describing: app.currentTaskSource))|\(detail?.key ?? "")") {
            app.loadTasks(.list)
            app.loadTasks(.drafts)
            if case .server(let h) = app.currentTaskSource, app.serverJira[h] == nil { app.loadServerJira([h]) }
            if let key = detail?.key { app.loadTasks(.card(key)) }
        }
    }

    func list(_ vm: TasksVM, current: String?) -> some View {
        let f = app.f
        return Scrolling {
            VStack(alignment: .leading, spacing: 10) {
                SourceBar {
                    app.loadTasks(.list, force: true)
                    app.loadTasks(.drafts, force: true)
                    if let key = vm.detail(selected)?.key { app.loadTasks(.card(key), force: true) }
                    if case .server(let h) = app.currentTaskSource { app.loadServerJira([h]) }
                }
                limits(f)
                HStack(spacing: 8) {
                    Field(placeholder: f.t("tasks.find"), text: $find)
                    Button {} label: {
                        Text("+").font(.system(size: 18, weight: .semibold)).foregroundColor(Z.onAccent)
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Z.week))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(f.t("tasks.new"))
                }
                let c = app.tasksNow
                if app.taskBackend != nil, !(c.drafts ?? []).isEmpty || c.draftNote != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Caps(text: f.t("draft.caps"))
                        ForEach((c.drafts ?? []).map { TaskBackend.draft($0, f) }) { d in draft(d, jira: c.jira) }
                        if let note = c.draftNote {
                            Text(note).font(.system(size: 12)).foregroundColor(Z.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Flow(spacing: 6) {
                    ForEach(vm.filters.indices, id: \.self) { i in
                        Chip(title: vm.filters[i].label, selected: vm.filters[i].filter == filter, height: 26) {
                            filter = vm.filters[i].filter
                        }
                    }
                }
                ForEach(vm.rows) { r in row(r, selected: r.key == current) }
            }
            .padding(.vertical, 16).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// What the source cannot do: suggest with AI (no CLI of its engine), read Jira (with the way to connect it).
    @ViewBuilder
    func limits(_ f: Fmt) -> some View {
        if app.taskBackend != nil, let s = app.currentTaskSource {
            let place = s == .local ? f.t("sum.src.local") : f.t("sum.src.server", app.sourceName(s))
            if let e = app.tasksNow.noCli {
                Text(f.t("tasks.noCLI", e, place)).font(.system(size: 12)).foregroundColor(Z.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if app.jiraOff(s) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(f.t("tasks.jiraOff", place)).font(.system(size: 12)).foregroundColor(Z.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(f.t("tasks.jiraConnect")) { app.screen = .settings }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundColor(Z.week)
                }
            }
        }
    }

    /// A suggested new task: made here, in Jira (after its sheet), or dropped.
    func draft(_ d: DraftVM, jira: TaskBackend.JiraProjects?) -> some View {
        let f = app.f
        // Not while an answer is on its way: a second click would answer the same suggestion again.
        func decide(_ act: @escaping (TaskBackend) throws -> String) {
            if app.tasksNow.loading == 0 { app.decideDraft(d.id, act) }
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text(d.title).font(.system(size: 13, weight: .medium)).foregroundColor(Z.text).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(d.meta).font(.system(size: 11)).foregroundColor(Z.muted).lineLimit(2)
            Flow(spacing: 6, lineSpacing: 6) {
                PillButton(title: f.t("draft.create"), primary: true, height: 28, radius: 8, fontSize: 12) { decide { try $0.accept(d.id) } }
                if let jira, !jira.projects.isEmpty {
                    PillButton(title: f.t("draft.createJira"), height: 28, radius: 8, fontSize: 12) {
                        if app.tasksNow.loading == 0 { jiraDraft = (d, jira) }
                    }
                }
                PillButton(title: f.t("draft.reject"), height: 28, radius: 8, fontSize: 12) { decide { try $0.reject(d.id) } }
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Z.divider, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    func row(_ r: TaskRowVM, selected on: Bool) -> some View {
        Button { selected = r.key } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(r.key).font(code(11)).foregroundColor(Z.link)
                    Spacer(minLength: 0)
                    StateChip(text: r.status, state: r.state, height: 20, fontSize: 11)
                }
                Text(r.title).font(.system(size: 13, weight: .medium)).foregroundColor(Z.text)
                    .multilineTextAlignment(.leading).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text(r.time)
                    Text(r.sessions)
                    Text(r.sync)
                }
                .font(mono(11)).foregroundColor(Z.muted).lineLimit(1)
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? Z.focusFill : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? Z.focus : Z.divider))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func detail(_ d: TaskDetailVM) -> some View {
        let f = app.f
        let pad = EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16)
        return Page(spacing: 18, insets: EdgeInsets(top: 22, leading: 28, bottom: 36, trailing: 28)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(d.key).font(code(13)).foregroundColor(Z.link)
                    if app.taskBackend == nil || snapshot {
                        StateChip(text: d.status, state: d.state, height: 22, fontSize: 12)
                    } else {
                        Menu {
                            ForEach([TaskState.planned, .active, .review, .done], id: \.self) { s in
                                Button(f.t("state.\(s)")) { app.editTask(d.key, relist: true) { try $0.setStatus(d.key, s) } }
                            }
                        } label: {
                            StateChip(text: d.status, state: d.state, height: 22, fontSize: 12)
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel(f.t("task.status"))
                    }
                    Spacer(minLength: 0)
                    if let page = d.jiraKey.flatMap({ app.jiraPage($0) }) {
                        Button(f.t("task.openJira")) { openURL(page) }.buttonStyle(.plain).font(.system(size: 13)).foregroundColor(Z.week)
                    }
                }
                Text(d.title).font(.system(size: 22, weight: .bold)).foregroundColor(Z.text).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !d.description.isEmpty {
                    Text(d.description).font(.system(size: 14)).foregroundColor(Z.body).lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 620, alignment: .leading)
                }
            }
            StatsRow(stats: d.stats, size: 18, spacing: 10)
            VStack(alignment: .leading, spacing: 8) {
                Caps(text: f.t("task.jiraCheck"))
                ForEach(d.jiraLines.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 8) {
                        Dot(color: Color(hex: d.jiraLines[i].color)).padding(.top, 5)
                        Text(d.jiraLines[i].text).font(.system(size: 13)).foregroundColor(Z.text).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 12).padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Z.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Z.border))
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    Card(padding: pad, spacing: 8, stretch: true) {
                        H2(text: f.t("task.todo"), size: 15).padding(.bottom, 4)
                        ForEach(d.todo.indices, id: \.self) { i in
                            // Not while an answer is on its way: the box may still show the state before the last click.
                            Button {
                                if app.tasksNow.loading == 0 {
                                    app.editTask(d.key) { try $0.checkTodo(d.key, number: i + 1, done: !d.todo[i].done) }
                                }
                            } label: {
                                todo(d.todo[i])
                            }
                            .buttonStyle(.plain)
                        }
                        if let text = newTodo {
                            Field(placeholder: f.t("task.addPlaceholder"), text: Binding { text } set: { newTodo = $0 })
                                .onSubmit {
                                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if t.isEmpty { newTodo = nil } else {
                                        app.editTask(d.key, done: { if newTodo == text { newTodo = nil } }) { try $0.addTodo(d.key, t) }
                                    }
                                }
                        } else {
                            Button(f.t("task.addItem")) { newTodo = "" }.buttonStyle(.plain).font(.system(size: 13))
                                .foregroundColor(Z.link).padding(.vertical, 4)
                        }
                    }
                    Card(padding: pad, spacing: 10, stretch: true) {
                        H2(text: f.t("task.done"), size: 15).padding(.bottom, 2)
                        ForEach(d.done.indices, id: \.self) { i in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(d.done[i].day).font(.system(size: 12, weight: .semibold)).foregroundColor(Z.secondary)
                                Text(d.done[i].text).font(.system(size: 13)).foregroundColor(Z.soft).lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Text(f.t("task.doneNote")).font(.system(size: 12)).foregroundColor(Z.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 16) {
                    Card(padding: pad, spacing: 8, stretch: true) {
                        H2(text: f.t("task.sessions"), size: 15).padding(.bottom, 2)
                        ForEach(d.sessions.indices, id: \.self) { i in session(d.sessions[i]) }
                    }
                    Card(padding: pad, spacing: 10, stretch: true) {
                        H2(text: f.t("task.notes"), size: 15).padding(.bottom, 2)
                        ForEach(d.notes.indices, id: \.self) { i in
                            Text(d.notes[i]).font(.system(size: 13)).foregroundColor(Z.soft).lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 10).padding(.horizontal, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Z.inset))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(f.t("task.newNote")).font(.system(size: 12)).foregroundColor(Z.secondary)
                            NoteEditor(text: $note)
                            if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                PillButton(title: f.t("task.saveNote"), height: 30, radius: 8, fontSize: 13) {
                                    let typed = note, text = note.trimmingCharacters(in: .whitespacesAndNewlines)
                                    app.editTask(d.key, done: { if note == typed { note = "" } }) { try $0.addNote(d.key, text) }
                                }
                            }
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Flow(spacing: 8, lineSpacing: 8) {
                PillButton(title: f.t("task.continueClaude"), primary: true, height: 38, radius: 10, fontSize: 14) {}
                PillButton(title: f.t("task.continueCodex"), height: 38, radius: 10, fontSize: 14) {}
                CopyButton(title: f.t("task.copySummary"), height: 38, radius: 10, fontSize: 14) {
                    ([d.key + " " + d.title, d.description] + d.done.map { "\($0.day): \($0.text)" })
                        .filter { !$0.isEmpty }.joined(separator: "\n\n")
                }
            }
            .padding(.top, 4)
        }
    }

    func todo(_ t: TodoItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 4)
                .fill(t.done ? Z.week : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(t.done ? Color.clear : Z.muted))
                .overlay {
                    if t.done {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundColor(Z.onAccent)
                    }
                }
                .frame(width: 16, height: 16)
                .padding(.top, 1)
            Text(t.text).font(.system(size: 13)).foregroundColor(t.done ? Z.muted : Z.text).strikethrough(t.done)
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
    }

    func session(_ s: TaskSessionVM) -> some View {
        HStack(spacing: 10) {
            Text(s.tool).font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: s.codex ? 0x8CC8FF : 0xF5B27A))
                .padding(.horizontal, 8).frame(minWidth: 52, minHeight: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: s.codex ? 0x1F2E3A : 0x3A2A1F)))
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title).font(.system(size: 13, weight: .medium)).foregroundColor(Z.text).lineLimit(1)
                Text(s.meta).font(.system(size: 11)).foregroundColor(Z.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(s.time).font(mono(12)).foregroundColor(Z.secondary).lineLimit(1)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .top) { Divider1() }
    }
}

struct StateChip: View {
    let text: String
    let state: TaskState
    var height: CGFloat = 22
    var fontSize: CGFloat = 12
    var colors: (bg: UInt32, fg: UInt32) {
        switch state {
        case .active: return (0x1E3A33, 0x5FD9B8)
        case .review: return (0x3A2F1A, 0xF5C46A)
        case .done: return (0x2A2A2E, 0xA9A9B0)
        case .planned: return (0x1F2E46, 0x9CC3FF)
        }
    }

    var body: some View {
        let (bg, fg) = colors
        Text(text).font(.system(size: fontSize)).foregroundColor(Color(hex: fg)).lineLimit(1)
            .padding(.horizontal, height >= 22 ? 9 : 8).frame(height: height)
            .background(Capsule().fill(Color(hex: bg)))
    }
}

struct NoteEditor: View {
    @Binding var text: String
    @Environment(\.isSnapshot) private var snapshot
    var body: some View {
        Group {
            if snapshot {
                Color.clear
            } else {
                TextEditor(text: $text).font(.system(size: 13)).scrollContentBackground(.hidden).padding(4)
            }
        }
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 9).fill(Z.inset))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Z.control))
    }
}

/// What will be made in Jira, editable; nothing is written before Create.
struct JiraCreateSheet: View {
    let f: Fmt
    let draft: DraftVM
    let jira: TaskBackend.JiraProjects
    /// Makes it; `done` gets the failure (nil: made).
    let create: (_ project: String, _ title: String, _ description: String, _ done: @escaping (String?) -> Void) -> Void
    /// The issue type the task gets in a project (nil: not known).
    let typeOf: (String) async -> String?
    let close: () -> Void
    @State private var project: String
    @State private var title: String
    @State private var text: String
    @State private var running = false
    @State private var error: String?
    @State private var type: String?

    init(f: Fmt, draft: DraftVM, jira: TaskBackend.JiraProjects,
         create: @escaping (String, String, String, @escaping (String?) -> Void) -> Void,
         typeOf: @escaping (String) async -> String?, close: @escaping () -> Void) {
        self.f = f; self.draft = draft; self.jira = jira; self.create = create; self.typeOf = typeOf; self.close = close
        // No guess: without a last-used (or most-used) project the user picks one.
        _project = State(initialValue: jira.default.flatMap { d in jira.projects.contains { $0.key == d } ? d : nil } ?? "")
        _title = State(initialValue: draft.name)
        _text = State(initialValue: draft.description)
    }

    var body: some View {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 12) {
            H2(text: f.t("draft.jiraTitle"), size: 17)
            Picker(f.t("draft.project"), selection: $project) {
                if project.isEmpty { Text("—").tag("") }
                ForEach(jira.projects, id: \.key) { p in Text(p.key + " · " + p.name).tag(p.key) }
            }
            if !project.isEmpty { Text(f.t("draft.type", type ?? "…")).font(.system(size: 13)).foregroundColor(Z.secondary) }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(f.t("draft.name")).foregroundColor(Z.secondary)
                    Spacer(minLength: 0)
                    // Jira lists cut long titles.
                    Text("\(name.count)/70").foregroundColor(name.count > 70 ? Z.bad : Z.muted)
                }
                .font(.system(size: 12))
                Field(placeholder: draft.name, text: $title)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(f.t("draft.description")).font(.system(size: 12)).foregroundColor(Z.secondary)
                TextEditor(text: $text).font(.system(size: 13)).scrollContentBackground(.hidden).padding(4)
                    .frame(height: 160)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Z.inset))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Z.control))
            }
            Text(f.t("draft.links", draft.worked)).font(.system(size: 12)).foregroundColor(Z.muted)
            if let error {
                Text(error).font(.system(size: 12)).foregroundColor(Z.bad).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(f.t("common.cancel"), action: close).keyboardShortcut(.cancelAction).disabled(running)
                // No Return shortcut: a newline in the description must not write to Jira.
                Button(running ? f.t("draft.creating") : f.t("draft.create")) {
                    running = true
                    error = nil
                    create(project, name, text.trimmingCharacters(in: .whitespacesAndNewlines)) { why in
                        running = false
                        if let why { error = why } else { close() }
                    }
                }
                .disabled(running || project.isEmpty || name.isEmpty)
            }
        }
        .padding(20).frame(width: 520)
        .background(Z.popover)
        .interactiveDismissDisabled(running)
        // The type Jira gives a task differs by project (and its language).
        .task(id: project) {
            type = nil
            guard !project.isEmpty else { return }
            let t = await typeOf(project)
            if !Task.isCancelled { type = t ?? "—" }
        }
    }
}
