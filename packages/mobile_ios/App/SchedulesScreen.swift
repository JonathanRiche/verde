import SwiftUI
import UIKit

/// What the form edits.
enum ScheduleFormSubject: Identifiable {
    case new
    /// The empty state's example, prefilled.
    case example
    case edit(ScheduleEntry)

    var id: String {
        switch self {
        case .new: return "new"
        case .example: return "example"
        case .edit(let entry): return "edit:" + entry.id
        }
    }
}

func scheduleStatusColor(_ tone: ScheduleStatusTone) -> Color {
    switch tone {
    case .quiet, .ok: return VerdeTheme.subtle
    case .attention: return VerdeTheme.warning
    case .failure: return VerdeTheme.danger
    }
}

/// The companion sheet's "Scheduled" screen: every scheduled task on the host with its repeat,
/// next run and last result, an enable toggle, Run now and delete. Tapping a row shows its
/// prompt (selectable) and Edit. Refreshes on open and every ~15 s while visible.
struct ScheduledScreen: View {
    let model: ScheduleModel
    let companion: CompanionModel
    let browse: BrowseModel
    /// Opens the chat a run used (the caller closes the sheets).
    let openChat: (_ workspace: String, _ thread: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var expanded: Set<String> = []
    @State private var form: ScheduleFormSubject?
    @State private var deleting: ScheduleEntry?

    private var companionName: String { companion.active?.name ?? "your companion" }
    private var pollKey: String { (browse.hostID ?? "") + "/" + String(scenePhase == .active) }

    var body: some View {
        let view = model.view
        let canEdit = view?.can_edit ?? false
        NavigationStack {
            Group {
                if view?.supported == false {
                    message(icon: "clock.badge.exclamationmark", title: "Scheduled tasks need a newer verde",
                            detail: "Update verde on the computer to schedule tasks from your phone.")
                } else if let view, view.loaded {
                    if view.schedules.isEmpty { empty(view) } else { list(view) }
                } else if let error = view?.error {
                    message(icon: "exclamationmark.triangle", title: "Couldn't load scheduled tasks", detail: error.message)
                } else {
                    ProgressView("Loading scheduled tasks…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(VerdeTheme.background)
            .navigationTitle("Scheduled")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { form = .new } label: { Image(systemName: "plus") }
                        .disabled(!canEdit)
                        .keyboardShortcut("n", modifiers: .command)
                        .accessibilityLabel("New scheduled task")
                        .accessibilityIdentifier("schedule-new")
                }
            }
            .sheet(item: $form) { subject in
                ScheduleForm(model: model, companion: companion, browse: browse, subject: subject)
            }
            .confirmationDialog("Delete this scheduled task?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { entry in
                Button("Delete \u{201C}\(scheduleTitle(entry))\u{201D}", role: .destructive) {
                    Task { await model.delete(entry.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("It stops running. Chats it already sent to stay as they are.")
            }
        }
        .tint(VerdeTheme.accent)
        .foregroundStyle(VerdeTheme.text)
        .font(VerdeTheme.ui())
        .task(id: pollKey) {
            guard scenePhase == .active else { return }
            await model.poll()
        }
    }

    // MARK: Sections

    private func list(_ view: SchedulesView) -> some View {
        let now = model.hostNow()
        return List {
            if let notice = model.notice ?? view.error?.message {
                Text(notice).font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.warning).textSelection(.enabled)
                    .listRowBackground(Color.clear)
            }
            if !view.can_edit { readOnlyNote.listRowBackground(Color.clear) }
            Section {
                ForEach(view.schedules, id: \.id) { entry in
                    row(entry, view: view, now: now)
                        .listRowBackground(VerdeTheme.panel)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { deleting = entry } label: { Label("Delete", systemImage: "trash") }
                                .tint(VerdeTheme.danger)
                                .disabled(!view.can_edit)
                        }
                        .contextMenu { menu(entry, canEdit: view.can_edit) }
                }
            } footer: {
                Text("Your computer runs these on its own clock, even while this phone is away.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await model.refresh(wait: true) }
    }

    private func row(_ entry: ScheduleEntry, view: SchedulesView, now: Int64) -> some View {
        let busy = view.busy_ids.contains(entry.id)
        let run = model.lastRun(entry.id)
        return ScheduleRow(entry: entry, nowMs: now, expanded: expanded.contains(entry.id), busy: busy, canEdit: view.can_edit,
                           target: targetText(entry), hasRunChat: run != nil,
                           toggle: { toggleExpanded(entry.id) },
                           setEnabled: { on in Task { await model.setEnabled(entry.id, on) } },
                           run: { Task { await model.run(entry.id) } },
                           edit: { form = .edit(entry) },
                           delete: { deleting = entry },
                           openRunChat: { if let run { openChat(run.workspace_id, run.thread_id) } })
    }

    private func toggleExpanded(_ id: String) {
        var next = expanded
        if next.contains(id) {
            next.remove(id)
        } else {
            next.insert(id)
        }
        withAnimation(AppearanceSettings.shared.reducedMotion ? nil : .easeOut(duration: 0.15)) { expanded = next }
    }

    @ViewBuilder private func menu(_ entry: ScheduleEntry, canEdit: Bool) -> some View {
        Button { Task { await model.run(entry.id) } } label: { Label("Run now", systemImage: "play") }
            .disabled(!canEdit)
        Button { form = .edit(entry) } label: { Label("Edit", systemImage: "pencil") }
            .disabled(!canEdit)
        Button { UIPasteboard.general.string = entry.prompt } label: { Label("Copy prompt", systemImage: "doc.on.doc") }
        Button(role: .destructive) { deleting = entry } label: { Label("Delete…", systemImage: "trash") }
            .disabled(!canEdit)
    }

    private func empty(_ view: SchedulesView) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 40)).foregroundStyle(VerdeTheme.accent)
                    .accessibilityHidden(true)
                Text("No scheduled tasks yet").font(VerdeTheme.ui(18, bold: true)).accessibilityAddTraits(.isHeader)
                Text("A scheduled task sends a prompt later or on repeat, to \(companionName)'s chat or a new chat in a workspace. Your computer runs it, even while this phone is away.")
                    .font(VerdeTheme.ui(14)).foregroundStyle(VerdeTheme.muted).multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 4) {
                    Text("For example").font(VerdeTheme.ui(12, bold: true)).foregroundStyle(VerdeTheme.subtle)
                    Text("\u{201C}Check CI for every workspace and tell me what failed.\u{201D}").font(VerdeTheme.ui(14))
                    Text("Weekdays at 09:00").font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted)
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(VerdeTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                Button { form = .new } label: {
                    Label("New scheduled task", systemImage: "plus").font(VerdeTheme.ui(15, bold: true))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!view.can_edit)
                .accessibilityIdentifier("schedule-empty-new")
                Button("Use this example") { form = .example }
                    .frame(minHeight: 44)
                    .disabled(!view.can_edit)
                if !view.can_edit { readOnlyNote }
                if let notice = model.notice ?? view.error?.message {
                    Text(notice).font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.warning).textSelection(.enabled)
                }
            }
            .padding(20)
        }
        .refreshable { await model.refresh(wait: true) }
    }

    private var readOnlyNote: some View {
        Text("Changes are off: this phone is offline or can only read chats on this host.")
            .font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted)
    }

    private func message(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(VerdeTheme.subtle).accessibilityHidden(true)
            Text(title).font(VerdeTheme.ui(16, bold: true)).multilineTextAlignment(.center)
            Text(detail).font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.muted).multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "Sends to Wren's chat", "Starts a new Claude chat in api each run", …
    private func targetText(_ entry: ScheduleEntry) -> String {
        let workspaces = browse.state.workspaces?.items ?? []
        let workspace = workspaces.first(where: { $0.workspace_id == entry.target_workspace_id })
        let runs = entry.run_count == 0 ? "" : entry.run_count == 1 ? " · 1 run" : " · \(entry.run_count) runs"
        if entry.target_kind == "new_chat" {
            let provider = entry.target_provider.isEmpty ? "" : providerDisplayName(entry.target_provider) + " "
            return "Starts a new \(provider)chat in \(workspace?.label ?? "a workspace") each run" + runs
        }
        if let chat = companion.conversation, chat.workspace == entry.target_workspace_id, chat.thread == entry.target_thread_id {
            return "Sends to \(companionName)'s chat" + runs
        }
        let title = workspace?.threads.first(where: { $0.thread_id == entry.target_thread_id })?.title ?? ""
        if !title.isEmpty { return "Sends to \u{201C}\(title)\u{201D}" + (workspace.map { " in " + $0.label } ?? "") + runs }
        return "Sends to an existing chat" + runs
    }
}

/// One task: title, repeat, next run and last result, with Run now and the enable toggle.
/// Expanded, it shows the prompt as selectable text and Edit/Delete.
private struct ScheduleRow: View {
    let entry: ScheduleEntry
    let nowMs: Int64
    let expanded: Bool
    let busy: Bool
    let canEdit: Bool
    let target: String
    let hasRunChat: Bool
    let toggle: () -> Void
    let setEnabled: (Bool) -> Void
    let run: () -> Void
    let edit: () -> Void
    let delete: () -> Void
    let openRunChat: () -> Void

    var body: some View {
        let title = scheduleTitle(entry)
        let repeatText = scheduleRepeatText(entry)
        let next = scheduleNextText(enabled: entry.enabled, nextMs: entry.next_run_ms, nowMs: nowMs)
        let status = scheduleStatusText(entry, nowMs: nowMs)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 4) {
                Button(action: toggle) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(VerdeTheme.ui(15, bold: true)).lineLimit(expanded ? 3 : 1)
                            .foregroundStyle(entry.enabled ? VerdeTheme.text : VerdeTheme.muted)
                        Text(repeatText).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted).lineLimit(1)
                        HStack(spacing: 4) {
                            Text(next).foregroundStyle(entry.enabled ? VerdeTheme.accent : VerdeTheme.subtle)
                            Text("·").foregroundStyle(VerdeTheme.subtle)
                            Text(status.text).foregroundStyle(scheduleStatusColor(status.tone))
                        }
                        .font(VerdeTheme.ui(12)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(repeatText), \(next), \(status.text)")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint(expanded ? "Hides the prompt." : "Shows the prompt.")
                .accessibilityIdentifier("schedule-row")
                Group {
                    if busy {
                        ProgressView()
                    } else {
                        Button(action: run) {
                            Image(systemName: "play.circle").font(.system(size: 20, weight: .regular))
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .disabled(!canEdit)
                        .accessibilityLabel("Run now")
                        .accessibilityHint("Sends the prompt now without changing the schedule.")
                    }
                }
                .frame(width: 44, height: 44)
                Toggle("Enabled", isOn: Binding(get: { entry.enabled }, set: { setEnabled($0) }))
                    .labelsHidden()
                    .disabled(!canEdit || busy)
                    .accessibilityLabel("\(title) enabled")
            }
            if expanded {
                Text(entry.prompt)
                    .font(VerdeTheme.ui(14))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(VerdeTheme.alternate, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("schedule-prompt-text")
                Text(target).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted)
                if let error = entry.last_error, !error.isEmpty {
                    Text(error).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.danger).textSelection(.enabled)
                }
                HStack(spacing: 18) {
                    Button(action: edit) { Label("Edit", systemImage: "pencil") }
                        .disabled(!canEdit)
                        .accessibilityIdentifier("schedule-edit")
                    Button(action: run) { Label("Run now", systemImage: "play") }
                        .disabled(!canEdit || busy)
                    Spacer(minLength: 0)
                    Button(role: .destructive, action: delete) { Label("Delete", systemImage: "trash") }
                        .disabled(!canEdit || busy)
                }
                .buttonStyle(.borderless)
                .font(VerdeTheme.ui(14))
                .frame(minHeight: 44)
            }
            if hasRunChat {
                Button(action: openRunChat) { Label("Open chat", systemImage: "arrow.up.right.square") }
                    .buttonStyle(.borderless)
                    .font(VerdeTheme.ui(14))
                    .frame(minHeight: 44)
                    .accessibilityHint("Opens the chat this run used.")
                    .accessibilityIdentifier("schedule-open-chat")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Form

/// "New scheduled task" and Edit: prompt, optional name, where it goes and when it repeats.
/// The core validates every field with the daemon's rules; its message is shown here.
struct ScheduleForm: View {
    let model: ScheduleModel
    let companion: CompanionModel
    let browse: BrowseModel
    let subject: ScheduleFormSubject
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ScheduleDraft()
    @State private var original = ScheduleDraft()
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?
    @State private var manage: ManageModel?
    @FocusState private var promptFocused: Bool

    private var companionName: String { companion.active?.name ?? "Companion" }
    private var editing: ScheduleEntry? {
        if case .edit(let entry) = subject { return entry }
        return nil
    }
    private var workspaces: [Workspace] { (browse.state.workspaces?.items ?? []).filter(\.open) }
    /// The new-chat catalog for the chosen workspace.
    private var catalog: ManageNewChat? {
        guard let chat = manage?.view?.new_chat, chat.workspace_id == draft.workspaceID else { return nil }
        return chat
    }
    private var catalogKey: String { draft.sendTo == .newChat ? "new:" + draft.workspaceID : "" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What should it do?", text: $draft.prompt, axis: .vertical)
                        .lineLimit(3...12)
                        .font(VerdeTheme.ui(15))
                        .focused($promptFocused)
                        .accessibilityLabel("Prompt")
                        .accessibilityIdentifier("schedule-prompt")
                    TextField("Name (optional)", text: $draft.name)
                        .font(VerdeTheme.ui(15))
                        .accessibilityIdentifier("schedule-name")
                } header: { Text("Task") } footer: {
                    Text("Without a name, the first line of the prompt is used.")
                }
                sendTo
                repeatSection
                Section {
                    Toggle("Enabled", isOn: $draft.enabled)
                }
                if let error {
                    Section {
                        Text(error).font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.danger).textSelection(.enabled)
                            .accessibilityIdentifier("schedule-error")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(VerdeTheme.background)
            .navigationTitle(editing == nil ? "New scheduled task" : "Edit scheduled task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: {
                        if saving { ProgressView() } else { Text("Save").bold() }
                    }
                    .disabled(saving || !draft.canSave || !model.canEdit)
                    .keyboardShortcut("s", modifiers: .command)
                    .accessibilityLabel("Save")
                    .accessibilityIdentifier("schedule-save")
                }
            }
            .onAppear { load() }
            .task(id: catalogKey) { await loadCatalog() }
            .onChange(of: draft.unit) { old, new in draft.every = scheduleConvertEvery(draft.every, from: old, to: new) }
            .onChange(of: draft.name) { _, value in
                let clipped = utf8Prefix(value, 120)
                if clipped != value { draft.name = clipped }
            }
        }
        .tint(VerdeTheme.accent)
        .interactiveDismissDisabled(saving || draft != original)
    }

    // MARK: Sections

    private var sendTo: some View {
        Section {
            Picker("Send to", selection: $draft.sendTo) {
                Text("\(companionName)'s chat").tag(ScheduleSendTo.companion)
                if original.sendTo == .existing { Text("Its current chat").tag(ScheduleSendTo.existing) }
                Text("A new chat in a workspace").tag(ScheduleSendTo.newChat)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .accessibilityIdentifier("schedule-send-to")
            if draft.sendTo == .newChat {
                Picker("Workspace", selection: $draft.workspaceID) {
                    if draft.workspaceID.isEmpty { Text("Choose…").tag("") }
                    ForEach(workspaces, id: \.workspace_id) { Text($0.label).tag($0.workspace_id) }
                }
                choice("Provider", value: draft.provider, empty: "Choose…", choices: catalog?.providers ?? []) { id in
                    draft.provider = id
                    draft.model = ""
                    Task { await selectCatalog() }
                }
                choice("Model", value: draft.model, empty: "Default", choices: catalog?.catalogs.models ?? [], allowsDefault: true) { id in
                    draft.model = id
                }
                if catalog?.loading == true { ProgressView("Loading models…") }
                if let notice = manage?.notice {
                    Text(notice).font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.warning).textSelection(.enabled)
                }
            }
        } header: { Text("Send to") } footer: {
            switch draft.sendTo {
            case .companion: Text("Each run arrives in \(companionName)'s chat as a new message.")
            case .existing: Text("Each run arrives in the chat this task already uses.")
            case .newChat: Text("Each run starts a fresh chat named after the task and reports back to \(companionName).")
            }
        }
    }

    private var repeatSection: some View {
        Section {
            Picker("Repeat", selection: $draft.repeatKind) {
                ForEach(ScheduleRepeatKind.allCases) { kind in Text(kind.label).tag(kind) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("schedule-repeat")
            switch draft.repeatKind {
            case .once:
                DatePicker("Run at", selection: $draft.at, displayedComponents: [.date, .hourAndMinute])
            case .interval:
                Stepper(value: $draft.every, in: draft.unit.range, step: draft.unit.step) {
                    Text("Every \(draft.every) \(draft.unit.noun(draft.every))")
                }
                Picker("Unit", selection: $draft.unit) {
                    ForEach(ScheduleIntervalUnit.allCases) { unit in Text(unit.title).tag(unit) }
                }
                .pickerStyle(.segmented)
            case .daily:
                DatePicker("At", selection: timeBinding, displayedComponents: .hourAndMinute)
                WeekdayChips(selection: $draft.weekdays)
            }
        } header: { Text("Repeat") } footer: {
            Text(draft.repeatText() + ". Times follow the computer's clock; the shortest repeat is 5 minutes.")
        }
    }

    /// The daily time as a phone clock value (only its hour and minute are used).
    private var timeBinding: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: draft.hour, minute: draft.minute, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            draft.hour = parts.hour ?? draft.hour
            draft.minute = parts.minute ?? draft.minute
        })
    }

    @ViewBuilder private func choice(_ title: String, value: String, empty: String, choices: [ChatChoice],
                                     allowsDefault: Bool = false, pick: @escaping (String) -> Void) -> some View {
        let shown = value.isEmpty ? empty : (choices.first(where: { $0.id == value })?.label ?? value)
        Menu {
            if allowsDefault {
                Button { pick("") } label: {
                    if value.isEmpty { Label("Default", systemImage: "checkmark") } else { Text("Default") }
                }
            }
            ForEach(choices, id: \.id) { item in
                Button { pick(item.id) } label: {
                    if item.id == value { Label(item.label, systemImage: "checkmark") } else { Text(item.label + (item.favorite ? " ★" : "")) }
                }
                .disabled(!item.enabled)
            }
        } label: {
            LabeledContent(title, value: shown).frame(minHeight: 44)
        }
        .disabled(choices.isEmpty)
    }

    // MARK: Effects

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch subject {
        case .new: draft = ScheduleDraft()
        case .example: draft = ScheduleDraft.example()
        case .edit(let entry): draft = ScheduleDraft(entry: entry, companionChat: companion.conversation)
        }
        original = draft
        if editing == nil && draft.prompt.isEmpty { promptFocused = true }
    }

    /// Loads the provider/model catalog New chat uses for the chosen workspace.
    private func loadCatalog() async {
        guard draft.sendTo == .newChat else { return }
        if draft.workspaceID.isEmpty {
            let home = companion.active?.home_workspace_id ?? ""
            let fallback: String? = workspaces.contains(where: { $0.workspace_id == home }) ? Optional(home) : mostRecentOpenWorkspace(workspaces)?.workspace_id
            // Changing the workspace restarts this task with the new key.
            if let fallback, !fallback.isEmpty { draft.workspaceID = fallback }
            return
        }
        if manage == nil {
            let next = ManageModel(browse: browse)
            await next.start()
            manage = next
        }
        await selectCatalog()
    }

    private func selectCatalog() async {
        guard let manage, !draft.workspaceID.isEmpty else { return }
        await manage.select(draft.workspaceID, ChatSelection(provider: draft.provider.isEmpty ? nil : draft.provider,
                                                             model: draft.model.isEmpty ? nil : draft.model))
        if draft.provider.isEmpty, let provider = catalog?.selection.provider, !provider.isEmpty { draft.provider = provider }
    }

    private func save() async {
        error = nil
        saving = true
        defer { saving = false }
        var chat = companion.conversation
        if draft.sendTo == .companion && chat == nil {
            // The companion's first scheduled task opens its chat, like its first message.
            chat = await companion.ensureConversation()
            guard chat != nil else {
                error = companion.notice ?? "Couldn't open \(companionName)'s chat. Try again."
                return
            }
        }
        let failure: String?
        if let entry = editing {
            guard let update = draft.updateEvent(intentID: "", id: entry.id, original: original, companionChat: chat) else {
                error = "Choose where this task should send its prompt."
                return
            }
            if scheduleUpdateIsEmpty(update) { dismiss(); return }
            failure = await model.save { id in
                var event = update
                event.intent_id = id
                return .schedule_update(event)
            }
        } else {
            guard let create = draft.createEvent(intentID: "", companionChat: chat) else {
                error = "Choose where this task should send its prompt."
                return
            }
            failure = await model.save { id in
                var event = create
                event.intent_id = id
                return .schedule_create(event)
            }
        }
        if let failure { error = failure } else { dismiss() }
    }
}

/// Mon…Sun toggles for a daily task; at least one day stays on (all seven means every day).
private struct WeekdayChips: View {
    @Binding var selection: Set<Int>

    var body: some View {
        HStack(spacing: 4) {
            ForEach(scheduleWeekOrder, id: \.self) { day in
                let on = selection.contains(day)
                Button { flip(day) } label: {
                    Text(scheduleWeekdayShort[day])
                        .font(VerdeTheme.ui(12, bold: on))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(on ? VerdeTheme.user : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? VerdeTheme.accent : VerdeTheme.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(scheduleWeekdayLong[day])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Days")
    }

    private func flip(_ day: Int) {
        var next = selection
        if !next.contains(day) {
            next.insert(day)
        } else if next.count > 1 {
            next.remove(day)
        }
        selection = next
    }
}
