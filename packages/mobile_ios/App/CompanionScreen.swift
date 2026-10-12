import SwiftUI
import UIKit

/// The Companion sheet opened from the floating bubble: a one-row header, a summary strip of
/// what needs the user and what the crew is doing (expanding to compact lists), and the companion
/// conversation with a dense transcript and single-row composer. Rows open their chat in the main
/// navigation via `open`.
struct CompanionSheet: View {
    let model: CompanionModel
    let browse: BrowseModel
    let voice: CompanionVoice
    let live: LiveVoice
    let open: (BrowseRoute) -> Void
    /// Closes the sheet and shows Home (all activity).
    let showHome: () -> Void
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
            CompanionHeader(model: model, live: live, entry: active, showHome: showHome) { settings = true }
            if let notice = model.notice {
                Text(notice).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 4)
            }
            if live.active {
                LiveVoicePanel(live: live)
            } else if let failure = live.failure {
                Text(failure).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 4)
            }
            CompanionSummary(model: model, open: open)
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

func summaryColor(_ tone: SummaryTone) -> Color {
    switch tone {
    case .attention: return VerdeTheme.warning
    case .busy: return VerdeTheme.accent
    case .failure: return VerdeTheme.danger
    case .quiet: return VerdeTheme.subtle
    }
}

/// One ~44pt row: avatar, name with a colored status suffix, Live, and a menu.
private struct CompanionHeader: View {
    let model: CompanionModel
    let live: LiveVoice
    let entry: RosterEntry
    let showHome: () -> Void
    let openSettings: () -> Void
    @AppStorage(CompanionBubbleStore.hiddenKey) private var bubbleHidden = false

    var body: some View {
        let presence = model.presence
        let suffix = companionStatusSuffix(needsYou: model.badgeCount,
                                           crewRunning: model.crew.filter { $0.attention == .running }.count,
                                           working: presence.pose == .working && model.crew.allSatisfy { $0.attention != .running },
                                           failed: presence.failure, connected: presence.pose != .paused)
        let companions = model.roster?.companions ?? []
        HStack(spacing: 8) {
            CompanionAvatar(character: entry.character, pose: presence.pose, failure: presence.failure, width: 28)
            (Text(entry.name).font(VerdeTheme.ui(16, bold: true))
                + Text(" · " + suffix.text).font(VerdeTheme.ui(12)).foregroundStyle(summaryColor(suffix.tone)))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("\(entry.name), \(presence.status)")
                .accessibilityAddTraits(.isHeader)
            Button { live.toggle() } label: {
                Image(systemName: live.active ? "waveform.circle.fill" : "waveform")
                    .font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel(live.active ? "End live conversation" : "Talk live")
            .accessibilityHint(live.active ? "" : "Starts a real-time voice conversation with \(entry.name).")
            .accessibilityIdentifier("companion-live")
            Menu {
                Button(action: showHome) { Label("All activity", systemImage: "list.bullet.rectangle") }
                if companions.count > 1 {
                    Menu {
                        ForEach(companions) { other in
                            Button { Task { await model.select(other.id) } } label: {
                                if other.id == entry.id { Label(other.name, systemImage: "checkmark") } else { Text(other.name) }
                            }
                        }
                    } label: { Label("Switch companion", systemImage: "person.2") }
                    .disabled(model.saving)
                }
                Button(action: openSettings) { Label("Settings", systemImage: "slider.horizontal.3") }
                if bubbleHidden {
                    Button { bubbleHidden = false } label: { Label("Show bubble", systemImage: "eye") }
                } else {
                    Button(role: .destructive) { bubbleHidden = true } label: { Label("Hide bubble", systemImage: "eye.slash") }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Companion options")
            .accessibilityIdentifier("companion-settings")
        }
        .padding(.leading, 14).padding(.trailing, 4).padding(.top, 10)
        .frame(minHeight: 44)
    }
}

/// Two capsules ("3 need you", "2 running · 1 done"), each expanding to a compact list.
private struct CompanionSummary: View {
    enum Panel: Equatable { case needs, crew }
    let model: CompanionModel
    let open: (BrowseRoute) -> Void
    @State private var expanded: Panel?

    var body: some View {
        let needs = model.needsYou
        let crew = model.crew
        let needsText = needsSummary(needs.count)
        let crewText = crewSummary(crew)
        if needsText != nil || crewText != nil {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let needsText {
                        capsule(.needs, icon: "exclamationmark.triangle.fill", text: needsText, color: VerdeTheme.warning)
                    }
                    if let crewText {
                        capsule(.crew, icon: "circle.fill", text: crewText,
                                color: crew.contains { $0.attention == .running } ? VerdeTheme.accent : VerdeTheme.subtle)
                    }
                    Spacer(minLength: 0)
                }
                if expanded == .needs && !needs.isEmpty {
                    list(needs.map { item in
                        SummaryRow(id: item.id, color: VerdeTheme.warning, title: item.title,
                                   detail: item.workspaceLabel ?? item.reason, label: item.reason,
                                   route: .thread(workspace: item.workspaceID, thread: item.threadID))
                    })
                } else if expanded == .crew && !crew.isEmpty {
                    let labels = Dictionary((model.browse.state.workspaces?.items ?? []).map { ($0.workspace_id, $0.label) },
                                            uniquingKeysWith: { a, _ in a })
                    list(crew.map { link in
                        SummaryRow(id: link.id, color: crewColor(link.attention), title: link.displayTitle,
                                   detail: labels[link.workspace_id] ?? link.attention.label, label: link.attention.label,
                                   route: .thread(workspace: link.workspace_id, thread: link.local_thread_id))
                    })
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 6)
            .onChange(of: needsText == nil) { _, hidden in if hidden && expanded == .needs { expanded = nil } }
            .onChange(of: crewText == nil) { _, hidden in if hidden && expanded == .crew { expanded = nil } }
        }
    }

    private func capsule(_ section: Panel, icon: String, text: String, color: Color) -> some View {
        let isOpen = expanded == section
        return Button {
            withAnimation(AppearanceSettings.shared.reducedMotion ? nil : .easeOut(duration: 0.15)) { expanded = isOpen ? nil : section }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: section == .crew ? 7 : 10)).foregroundStyle(color)
                Text(text).font(VerdeTheme.ui(12, bold: true)).lineLimit(1)
                Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(VerdeTheme.subtle)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.14), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .accessibilityHint(isOpen ? "Hides the list." : "Shows the list.")
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
    }

    /// About four rows tall, then scrolls.
    private func list(_ rows: [SummaryRow]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    Button { open(row.route) } label: {
                        HStack(spacing: 8) {
                            Circle().fill(row.color).frame(width: 6, height: 6)
                            Text(row.title).font(VerdeTheme.ui(14)).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 6)
                            Text(row.detail).font(VerdeTheme.ui(11)).foregroundStyle(VerdeTheme.subtle).lineLimit(1)
                                .layoutPriority(-1)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(row.title), \(row.label)\(row.detail == row.label ? "" : ", " + row.detail)")
                    .accessibilityHint("Opens this chat.")
                }
            }
        }
        .frame(maxHeight: 180)
        .scrollBounceBehavior(.basedOnSize)
    }
}

private struct SummaryRow: Identifiable {
    let id: String
    let color: Color
    let title: String
    let detail: String
    let label: String
    let route: BrowseRoute
}

func crewColor(_ attention: CrewAttention) -> Color {
    switch attention {
    case .approval, .blocked: return VerdeTheme.warning
    case .failed: return VerdeTheme.danger
    case .running: return VerdeTheme.accent
    case .done, .idle: return VerdeTheme.subtle
    }
}

private struct SuggestionList: View {
    let enabled: Bool
    let pick: (String) -> Void
    var body: some View {
        VStack(spacing: 6) {
            ForEach(companionSuggestions, id: \.self) { suggestion in
                Button { pick(suggestion) } label: {
                    Text(suggestion).font(VerdeTheme.ui(14)).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 12)
                        .background(VerdeTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
            }
        }
    }
}

/// Before the companion's chat exists: suggestions and the same single-row composer shape.
/// Sending creates the chat in the companion's home workspace and hands the prompt over.
private struct CompanionStarter: View {
    let busy: Bool
    let name: String
    let voice: CompanionVoice
    let send: (String) -> Void
    let sendVoice: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ask \(name) to run or check anything across your workspaces.")
                        .font(VerdeTheme.ui(14)).foregroundStyle(VerdeTheme.muted)
                    SuggestionList(enabled: !busy) { send($0) }
                }.padding(14)
            }
            if let notice = voice.notice, !voice.listening {
                Text(notice).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
            }
            HStack(alignment: .bottom, spacing: 2) {
                Group {
                    if voice.listening {
                        HStack(spacing: 8) {
                            LevelMeter(level: voice.level)
                            Text(voice.partial.isEmpty ? "Listening…" : voice.partial).font(VerdeTheme.ui(15)).lineLimit(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        TextField("Message \(name)", text: $text, axis: .vertical)
                            .lineLimit(1...4)
                            .font(VerdeTheme.ui(15))
                            .accessibilityIdentifier("companion-starter-input")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(minHeight: 40)
                .background(VerdeTheme.alternate, in: RoundedRectangle(cornerRadius: 20))
                .padding(.vertical, 2)
                CompanionMicButton(voice: voice, name: name, send: sendVoice).disabled(busy)
                Button {
                    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !prompt.isEmpty else { return }
                    text = ""
                    send(prompt)
                } label: {
                    Group {
                        if busy { ProgressView() }
                        else {
                            Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(VerdeTheme.background)
                                .frame(width: 32, height: 32).background(VerdeTheme.accent, in: Circle())
                        }
                    }
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(VerdeTheme.panel)
            .overlay(alignment: .top) { Divider().overlay(VerdeTheme.border) }
        }
    }
}

/// The companion's chat: the regular transcript (dense) and the single-row composer with the mic.
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
                TranscriptBody(model: model, browse: browse, onHosts: onHosts, compactComposer: composer(model))
                    .environment(\.compactChat, true)
                    .overlay(alignment: .top) {
                        if let thread = model.thread, thread.rows.isEmpty, !thread.page.loading, thread.error == nil {
                            SuggestionList(enabled: true) { model.input.ask($0) }.padding(14)
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

    /// The live transcript replaces the field while listening; the mic sits next to send.
    private func composer(_ model: TranscriptModel) -> CompactComposer {
        CompactComposer(placeholder: "Message \(name)",
                        transcript: voice.listening ? voice.partial : nil,
                        level: voice.level,
                        notice: voice.listening ? nil : voice.notice,
                        trailing: AnyView(CompanionMicButton(voice: voice, name: name) { sendVoice($0, model) }))
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
