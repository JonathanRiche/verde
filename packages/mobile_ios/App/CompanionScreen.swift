import SwiftUI
import UIKit

/// The Companion sheet opened from the floating bubble: who it is and how it's doing, what needs
/// the user across every workspace, its crew, and its conversation (the ordinary chat transcript
/// and composer on its thread). Rows open their chat in the main navigation via `open`.
struct CompanionSheet: View {
    let model: CompanionModel
    let browse: BrowseModel
    let voice: CompanionVoice
    let live: LiveVoice
    let open: (BrowseRoute) -> Void
    let onHosts: () -> Void
    @State private var settings = false
    /// A prompt typed or picked before the companion's chat existed; sent once it opens.
    @State private var pendingPrompt: String?

    var body: some View {
        Group {
            if let active = model.active {
                content(active)
            } else {
                VStack(spacing: 12) {
                    if let notice = model.notice { Text(notice).foregroundStyle(VerdeTheme.warning) }
                    else { ProgressView("Loading your companion…") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(VerdeTheme.background)
        .tint(VerdeTheme.accent)
        .foregroundStyle(VerdeTheme.text)
        .font(VerdeTheme.ui())
        .sheet(isPresented: $settings) { CompanionSettings(model: model, browse: browse) }
    }

    private func content(_ active: RosterEntry) -> some View {
        VStack(spacing: 0) {
            CompanionHeader(model: model, live: live, entry: active, presence: model.presence) { settings = true }
            if live.active {
                LiveVoicePanel(live: live)
            } else if let failure = live.failure {
                Text(failure).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 6)
            }
            CompanionBoard(needsYou: model.needsYou, crew: model.crew, open: open)
            Divider().overlay(VerdeTheme.border)
            if let conversation = model.conversation {
                CompanionConversation(browse: browse, voice: voice, name: active.name, workspaceID: conversation.workspace,
                                      threadID: conversation.thread, pendingPrompt: $pendingPrompt, onHosts: onHosts)
                    .id(conversation.workspace + "/" + conversation.thread)
            } else {
                CompanionStarter(busy: model.creatingThread, name: active.name, voice: voice, send: { prompt in
                    pendingPrompt = prompt
                    Task { if await model.ensureConversation() == nil { pendingPrompt = nil } }
                }, sendVoice: { transcript in
                    voice.pendingPrompt = transcript
                    Task { if await model.ensureConversation() == nil { voice.pendingPrompt = nil } }
                })
            }
        }
    }
}

/// Compact header: avatar, name, status, companion switcher and settings.
private struct CompanionHeader: View {
    let model: CompanionModel
    let live: LiveVoice
    let entry: RosterEntry
    let presence: CompanionPresence
    let openSettings: () -> Void
    @AppStorage(CompanionBubbleStore.hiddenKey) private var bubbleHidden = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            CompanionAvatar(character: entry.character, pose: presence.pose, failure: presence.failure, width: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(VerdeTheme.ui(16, bold: true)).lineLimit(1)
                HStack(spacing: 6) {
                    StatusPip(active: presence.pose == .working, attention: presence.pose == .approval, failed: presence.failure)
                    Text(presence.status).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted).lineLimit(1)
                }
                if let notice = model.notice { Text(notice).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.warning).lineLimit(2) }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            let companions = model.roster?.companions ?? []
            Button { live.toggle() } label: {
                Image(systemName: live.active ? "waveform.circle.fill" : "waveform").frame(width: 44, height: 44)
            }
            .accessibilityLabel(live.active ? "End live conversation" : "Talk live")
            .accessibilityHint(live.active ? "" : "Starts a real-time voice conversation with \(entry.name).")
            .accessibilityIdentifier("companion-live")
            if companions.count > 1 {
                Menu {
                    ForEach(companions) { other in
                        Button { Task { await model.select(other.id) } } label: {
                            if other.id == entry.id { Label(other.name, systemImage: "checkmark") } else { Text(other.name) }
                        }
                    }
                } label: { Image(systemName: "person.2").frame(width: 44, height: 44) }
                .disabled(model.saving)
                .accessibilityLabel("Switch companion")
            }
            Menu {
                Button(action: openSettings) { Label("Settings", systemImage: "slider.horizontal.3") }
                if bubbleHidden {
                    Button { bubbleHidden = false } label: { Label("Show bubble", systemImage: "eye") }
                } else {
                    Button(role: .destructive) { bubbleHidden = true } label: { Label("Hide bubble", systemImage: "eye.slash") }
                }
            } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                .accessibilityLabel("Companion options")
                .accessibilityIdentifier("companion-settings")
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.top, 14).padding(.bottom, 6)
    }
}

/// "Needs you" and "Crew", kept short so the conversation keeps most of the screen.
private struct CompanionBoard: View {
    static let visibleNeeds = 3
    let needsYou: [NeedsYouItem]
    let crew: [CrewLink]
    let open: (BrowseRoute) -> Void

    var body: some View {
        if !needsYou.isEmpty || !crew.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !needsYou.isEmpty {
                    BoardTitle(text: "Needs you", count: needsYou.count)
                    ForEach(needsYou.prefix(Self.visibleNeeds)) { item in
                        Button { open(.thread(workspace: item.workspaceID, thread: item.threadID)) } label: {
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
                        Text("\(needsYou.count - Self.visibleNeeds) more on Home").font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted)
                    }
                }
                if !crew.isEmpty {
                    BoardTitle(text: "Crew", count: crew.count)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) { ForEach(crew) { link in CrewChip(link: link) { open(.thread(workspace: link.workspace_id, thread: link.local_thread_id)) } } }
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
    let open: () -> Void
    var body: some View {
        let attention = link.attention
        Button(action: open) {
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
    let voice: CompanionVoice
    let send: (String) -> Void
    let sendVoice: (String) -> Void
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
            CompanionVoiceBar(voice: voice, name: name, send: sendVoice).disabled(busy)
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
    let voice: CompanionVoice
    let name: String
    let workspaceID: String
    let threadID: String
    @Binding var pendingPrompt: String?
    let onHosts: () -> Void
    @State private var model: TranscriptModel?
    @AppStorage(CompanionVoiceStore.readAloudKey) private var readAloud = ""

    var body: some View {
        VStack(spacing: 0) {
            if let model {
                TranscriptBody(model: model, browse: browse, onHosts: onHosts,
                               accessory: AnyView(CompanionVoiceBar(voice: voice, name: name) { sendVoice($0, model) }))
                    .overlay(alignment: .top) {
                        if let thread = model.thread, thread.rows.isEmpty, !thread.page.loading, thread.error == nil {
                            SuggestionList(enabled: true) { model.input.ask($0) }.padding(16)
                        }
                    }
                    // Reads new replies aloud per the read-aloud setting, sentence by sentence.
                    .onChange(of: readKey(model), initial: true) { _, _ in
                        voice.observe(rows: model.thread?.rows ?? [], turnActive: model.state.turn != nil,
                                      policy: effectiveReadAloud(stored: readAloud, voiceOverRunning: UIAccessibility.isVoiceOverRunning))
                    }
                    .onChange(of: voice.pendingPrompt, initial: true) { _, _ in takeVoicePrompt() }
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
            takeVoicePrompt()
        }
        .onDisappear {
            model?.setVisible(false)
            // Leaving the companion stops listening and speaking.
            voice.cancel()
            voice.leave()
        }
    }

    /// A transcript handed over from the bubble (or the starter) goes out as a voice turn.
    private func takeVoicePrompt() {
        guard let model, let prompt = voice.pendingPrompt else { return }
        voice.pendingPrompt = nil
        sendVoice(prompt, model)
    }

    private func sendVoice(_ text: String, _ model: TranscriptModel) {
        voice.noteVoiceSend()
        model.input.ask(text, voice: true)
    }

    private func readKey(_ model: TranscriptModel) -> String {
        let last = model.thread?.rows.last { $0.role == "assistant" && $0.kind == "message" }
        return (last?.id ?? "") + "#" + String(last?.body.utf16.count ?? 0) + "#" + String(model.state.turn != nil)
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
    @AppStorage(CompanionBubbleStore.hiddenKey) private var bubbleHidden = false

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
                CompanionVoiceSettings()
                LiveVoiceSettings(browse: browse)
                roster
                Section {
                    Toggle("Show the floating bubble", isOn: Binding(get: { !bubbleHidden }, set: { bubbleHidden = !$0 }))
                } footer: { Text("Long-press the bubble to hide it; turn it back on here or in Settings.") }
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
