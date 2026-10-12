import SwiftUI

/// The Companion home: who it is and how it's doing, what needs the user across every workspace,
/// its crew, and its conversation (the ordinary chat transcript and composer on its thread).
/// Until the roster has loaded (or with no workspace to home it in) the classic Home is shown.
struct CompanionHome: View {
    let model: CompanionModel
    let browse: BrowseModel
    let actions: BrowseActions
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings = false
    @State private var addingHost = false
    /// A prompt typed or picked before the companion's chat existed; sent once it opens.
    @State private var pendingPrompt: String?

    private var pollKey: String { (browse.hostID ?? "") + "/" + String(scenePhase == .active) }

    var body: some View {
        Group {
            if let active = model.active {
                content(active)
            } else {
                HomeScreen(model: browse, actions: actions)
            }
        }
        // Polls the roster and crew only while this screen is visible and the app is active.
        .task(id: pollKey) { if scenePhase == .active { await model.poll() } }
    }

    private func content(_ active: RosterEntry) -> some View {
        let presence = model.presence
        return VStack(spacing: 0) {
            CompanionHeader(entry: active, presence: presence, notice: model.notice) { settings = true }
            CompanionBoard(needsYou: model.needsYou, crew: model.crew)
            Divider().overlay(VerdeTheme.border)
            if let conversation = model.conversation {
                CompanionConversation(browse: browse, workspaceID: conversation.workspace, threadID: conversation.thread,
                                      pendingPrompt: $pendingPrompt, onHosts: actions.hosts)
                    .id(conversation.workspace + "/" + conversation.thread)
            } else {
                CompanionStarter(busy: model.creatingThread, name: active.name) { prompt in
                    pendingPrompt = prompt
                    Task { if await model.ensureConversation() == nil { pendingPrompt = nil } }
                }
            }
        }
        .background(VerdeTheme.background)
        .navigationTitle(active.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: BrowseRoute.activity) { Image(systemName: "list.bullet.rectangle") }
                    .accessibilityLabel("All activity")
            }
            ToolbarItem(placement: .topBarTrailing) { HostMenu(model: browse.hosts) { addingHost = true } }
        }
        .modifier(AddHostAlert(model: browse.hosts, isPresented: $addingHost))
        .sheet(isPresented: $settings) { CompanionSettings(model: model, browse: browse) }
    }
}

private struct CompanionHeader: View {
    let entry: RosterEntry
    let presence: CompanionPresence
    let notice: String?
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            CompanionAvatar(character: entry.character, pose: presence.pose, failure: presence.failure, width: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(VerdeTheme.display(22)).lineLimit(1)
                HStack(spacing: 6) {
                    StatusPip(active: presence.pose == .working, attention: presence.pose == .approval, failed: presence.failure)
                    Text(presence.status).font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.muted).lineLimit(1)
                }
                if let notice { Text(notice).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.warning).lineLimit(2) }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            Button(action: openSettings) { Image(systemName: "slider.horizontal.3").frame(width: 36, height: 36) }
                .accessibilityLabel("Companion settings")
                .accessibilityIdentifier("companion-settings")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

/// "Needs you" and "Crew", kept short so the conversation keeps most of the screen.
private struct CompanionBoard: View {
    static let visibleNeeds = 3
    let needsYou: [NeedsYouItem]
    let crew: [CrewLink]

    var body: some View {
        if !needsYou.isEmpty || !crew.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !needsYou.isEmpty {
                    BoardTitle(text: "Needs you", count: needsYou.count)
                    ForEach(needsYou.prefix(Self.visibleNeeds)) { item in
                        NavigationLink(value: BrowseRoute.thread(workspace: item.workspaceID, thread: item.threadID)) {
                            HStack(spacing: 10) {
                                Circle().fill(VerdeTheme.warning).frame(width: 6, height: 6)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(item.title).font(VerdeTheme.ui(14)).lineLimit(1)
                                    Text([item.reason, item.workspaceLabel].compactMap { $0 }.joined(separator: " · "))
                                        .font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(VerdeTheme.subtle)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if needsYou.count > Self.visibleNeeds {
                        NavigationLink("\(needsYou.count - Self.visibleNeeds) more", value: BrowseRoute.activity)
                            .font(VerdeTheme.ui(13, bold: true))
                    }
                }
                if !crew.isEmpty {
                    BoardTitle(text: "Crew", count: crew.count)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) { ForEach(crew) { CrewChip(link: $0) } }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 10)
        }
    }
}

private struct BoardTitle: View {
    let text: String
    let count: Int
    var body: some View {
        Text("\(text.uppercased()) · \(count)").font(VerdeTheme.ui(11, bold: true)).foregroundStyle(VerdeTheme.subtle)
            .accessibilityAddTraits(.isHeader)
    }
}

func crewColor(_ attention: CrewAttention) -> Color {
    switch attention {
    case .approval, .blocked: return VerdeTheme.warning
    case .failed: return VerdeTheme.danger
    case .running: return VerdeTheme.accent
    case .done, .idle: return VerdeTheme.subtle
    }
}

private struct CrewChip: View {
    let link: CrewLink
    var body: some View {
        let attention = link.attention
        NavigationLink(value: BrowseRoute.thread(workspace: link.workspace_id, thread: link.local_thread_id)) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ProviderGlyph(provider: link.provider.isEmpty ? nil : link.provider)
                    Text(link.displayTitle).font(VerdeTheme.ui(13, bold: true)).lineLimit(1)
                }
                Text(attention.label).font(VerdeTheme.ui(11, bold: true))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .foregroundStyle(crewColor(attention))
                    .background(crewColor(attention).opacity(0.16), in: Capsule())
                    .modifier(Pulse(active: attention == .running, minimum: 0.6))
                if let detail = link.detail {
                    Text(detail).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted).lineLimit(1)
                }
            }
            .frame(width: 180, alignment: .leading)
            .padding(10)
            .background(VerdeTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(attention.needsYou ? VerdeTheme.warning : VerdeTheme.border))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

private struct SuggestionList: View {
    let enabled: Bool
    let pick: (String) -> Void
    var body: some View {
        VStack(spacing: 8) {
            ForEach(companionSuggestions, id: \.self) { suggestion in
                Button { pick(suggestion) } label: {
                    Text(suggestion).font(VerdeTheme.ui(14)).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(VerdeTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(VerdeTheme.border))
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
            }
        }
    }
}

/// Before the companion's chat exists: suggestions and a plain prompt field. Sending creates the
/// chat in the companion's home workspace and hands the prompt to the real composer.
private struct CompanionStarter: View {
    let busy: Bool
    let name: String
    let send: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Ask \(name) to run or check anything across your workspaces.")
                        .font(VerdeTheme.ui(14)).foregroundStyle(VerdeTheme.muted)
                    SuggestionList(enabled: !busy) { send($0) }
                }.padding(16)
            }
            HStack(spacing: 8) {
                TextField("Message \(name)", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(VerdeTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(VerdeTheme.border))
                    .accessibilityIdentifier("companion-starter-input")
                Button {
                    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !prompt.isEmpty else { return }
                    text = ""
                    send(prompt)
                } label: {
                    if busy { ProgressView().frame(width: 40, height: 40) }
                    else { Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)).frame(width: 40, height: 40) }
                }
                .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
    }
}

/// The companion's chat: the regular transcript, approvals and composer, with empty-state suggestions.
private struct CompanionConversation: View {
    let browse: BrowseModel
    let workspaceID: String
    let threadID: String
    @Binding var pendingPrompt: String?
    let onHosts: () -> Void
    @State private var model: TranscriptModel?

    var body: some View {
        VStack(spacing: 0) {
            if let model {
                TranscriptBody(model: model, browse: browse, onHosts: onHosts)
                    .overlay(alignment: .top) {
                        if let thread = model.thread, thread.rows.isEmpty, !thread.page.loading, thread.error == nil {
                            SuggestionList(enabled: true) { model.input.ask($0) }.padding(16)
                        }
                    }
            } else {
                Spacer()
            }
        }
        .onAppear {
            if model == nil || model?.closed == true {
                let next = TranscriptModel(browse: browse, workspaceID: workspaceID, threadID: threadID)
                model = next
                next.start()
            }
            model?.setVisible(true)
            if let prompt = pendingPrompt {
                pendingPrompt = nil
                model?.input.ask(prompt)
            }
        }
        .onDisappear { model?.setVisible(false) }
    }
}

// MARK: - Settings

struct CompanionSettings: View {
    let model: CompanionModel
    let browse: BrowseModel
    @Environment(\.dismiss) private var dismiss
    @State private var editingID = ""
    @State private var name = ""
    @State private var character = CompanionCharacter.sprout
    @State private var orders = ""
    @State private var provider = ""
    @State private var brainModel = ""

    private var dirty: Bool {
        guard let active = model.active, active.id == editingID else { return false }
        let cleaned = cleanCompanionName(name)
        let renamed = !cleaned.isEmpty && cleaned != active.name
        let changed = character != active.character || orders != active.orders
        return renamed || changed || provider != active.provider || brainModel != active.model
    }

    var body: some View {
        NavigationStack {
            Form {
                if let notice = model.notice { Text(notice).foregroundStyle(VerdeTheme.warning) }
                identity
                Section {
                    TextEditor(text: $orders).frame(minHeight: 120).font(VerdeTheme.ui(14))
                        .accessibilityIdentifier("companion-orders")
                } header: { Text("Standing orders") } footer: {
                    Text("Sent with every turn, e.g. \u{201C}Always run the tests before calling work done.\u{201D}")
                }
                brain
                roster
            }
            .scrollContentBackground(.hidden)
            .background(VerdeTheme.background)
            .navigationTitle("Companion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { Task { if await save() { dismiss() } } }.disabled(model.saving)
                }
            }
            .onAppear(perform: load)
            .onChange(of: name) { _, value in let clipped = utf8Prefix(value, RosterEntry.nameLimit); if clipped != value { name = clipped } }
            .onChange(of: orders) { _, value in let clipped = utf8Prefix(value, RosterEntry.ordersLimit); if clipped != value { orders = clipped } }
        }
        .tint(VerdeTheme.accent)
    }

    private var identity: some View {
        Section("Identity") {
            TextField("Name", text: $name).accessibilityIdentifier("companion-name")
            HStack(spacing: 8) {
                ForEach(CompanionCharacter.allCases) { option in
                    Button { character = option } label: {
                        VStack(spacing: 4) {
                            CompanionAvatar(character: option, width: 34)
                            Text(option.displayName).font(VerdeTheme.ui(12, bold: option == character))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background(option == character ? VerdeTheme.user : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(option == character ? VerdeTheme.accent : VerdeTheme.border))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(option == character ? .isSelected : [])
                }
            }
            Text(character.tagline).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted)
        }
    }

    @ViewBuilder private var brain: some View {
        if let home = model.active?.home_workspace_id, !home.isEmpty {
            Section {
                ManageContainer(browse: browse) { manage in
                    BrainPicker(manage: manage, home: home, provider: $provider, model: $brainModel)
                }
            } header: { Text("Brain") } footer: {
                Text("Used when \(name.isEmpty ? "your companion" : name) starts a new chat; an existing chat keeps its model.")
            }
        }
    }

    private var roster: some View {
        Section {
            let entries = model.roster?.companions ?? []
            ForEach(entries) { entry in
                Button { Task { await switchTo(entry.id) } } label: {
                    HStack(spacing: 10) {
                        CompanionAvatar(character: entry.character, width: 26)
                        Text(entry.name)
                        Spacer()
                        if entry.id == model.active?.id { Image(systemName: "checkmark").foregroundStyle(VerdeTheme.accent) }
                    }
                }
                .disabled(model.saving)
            }
            .onDelete { offsets in
                let ids = offsets.map { entries[$0].id }
                Task {
                    await model.update { roster in ids.reduce(false) { removed, id in roster.remove(id) || removed } }
                    load()
                }
            }
            .deleteDisabled(entries.count <= 1)
            if entries.count < Roster.maxCompanions {
                Menu {
                    ForEach(CompanionCharacter.allCases) { option in
                        Button(option.displayName) { Task { await add(option) } }
                    }
                } label: { Label("Add companion", systemImage: "plus") }
                .disabled(model.saving || model.defaultHome == nil)
            }
        } header: { Text("Companions") } footer: {
            Text("Each companion has its own chat and crew. Swipe to remove one; you always keep at least one.")
        }
    }

    private func load() {
        guard let active = model.active else { return }
        editingID = active.id
        name = active.name
        character = active.character
        orders = active.orders
        provider = active.provider
        brainModel = active.model
    }

    /// Saves pending identity, orders and brain edits for the companion being edited.
    private func save() async -> Bool {
        guard dirty else { return true }
        let id = editingID, newName = name, newCharacter = character, newOrders = orders, newProvider = provider, newModel = brainModel
        return await model.update { roster in
            guard roster.companions.contains(where: { $0.id == id }) else { return false }
            if !cleanCompanionName(newName).isEmpty { roster.rename(id, to: newName) }
            roster.edit(id) { entry in
                entry.character = newCharacter
                entry.orders = newOrders
                entry.provider = newProvider
                entry.model = newModel
            }
            return true
        }
    }

    private func switchTo(_ id: String) async {
        guard id != model.active?.id, await save() else { return }
        await model.select(id)
        load()
    }

    private func add(_ character: CompanionCharacter) async {
        guard await save(), let home = model.defaultHome else { return }
        await model.update { $0.add(character, home: home) != nil }
        load()
    }
}

/// Provider and model menus from the host's new-chat catalog for the companion's home workspace.
private struct BrainPicker: View {
    let manage: ManageModel
    let home: String
    @Binding var provider: String
    @Binding var model: String

    var body: some View {
        let chat = manage.view?.new_chat
        let ready = chat?.workspace_id == home
        Group {
            menu("Provider", value: provider, choices: ready ? chat?.providers ?? [] : []) { value in
                provider = value
                model = ""
                Task { await manage.select(home, ChatSelection(provider: value.isEmpty ? nil : value)) }
            }
            menu("Model", value: model, choices: ready ? chat?.catalogs.models ?? [] : []) { value in model = value }
            if chat?.loading == true || !ready { ProgressView("Loading models…") }
            if ready, let error = chat?.error { Text(newChatModelMessage(error)).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.warning) }
        }
        .task(id: home) {
            await manage.select(home, ChatSelection(provider: provider.isEmpty ? nil : provider, model: model.isEmpty ? nil : model))
        }
    }

    @ViewBuilder private func menu(_ label: String, value: String, choices: [ChatChoice], pick: @escaping (String) -> Void) -> some View {
        Menu {
            Button("Default") { pick("") }
            ForEach(choices, id: \.id) { item in
                Button(item.label + (item.favorite ? " ★" : "")) { pick(item.id) }.disabled(!item.enabled)
            }
        } label: {
            LabeledContent(label, value: value.isEmpty ? "Default" : choices.first { $0.id == value }?.label ?? value)
        }
        .disabled(manage.busy)
    }
}
