import SwiftUI

/// Companion settings → Brain: the provider, model, effort and speed behind the companion.
/// Model/effort/speed change the current chat in place (composer selection); provider changes go
/// through `switchCompanionProvider(provider:model:brief:)` and keep the conversation. Choices come from the
/// same host catalogs New chat uses. Nothing is sent to the agent.
struct CompanionBrainScreen: View {
    let model: CompanionModel
    let browse: BrowseModel
    @State private var manage: ManageModel?
    @State private var transcript: TranscriptModel?
    /// The provider picked on this screen ("" until loaded).
    @State private var provider = ""
    @State private var working = false
    @State private var confirming = false
    @State private var message: String?

    private var active: RosterEntry? { model.active }
    private var conversation: (workspace: String, thread: String)? { model.conversation }
    private var home: String? {
        if let conversation { return conversation.workspace }
        if let home = active?.home_workspace_id, !home.isEmpty { return home }
        return model.defaultHome
    }
    private var summary: ThreadSummary? {
        guard let conversation else { return nil }
        return browse.state.workspaces?.items.first { $0.workspace_id == conversation.workspace }?
            .threads.first { $0.thread_id == conversation.thread }
    }
    private var threadState: BrainThreadState {
        guard conversation != nil else { return .noChat }
        let committed = summary?.committed ?? true
        let rows = transcript?.thread?.rows.isEmpty == false
        return committed || rows ? .committed : .empty
    }
    /// The chat's provider (or the roster's before the first chat).
    private var currentProvider: String {
        transcript?.input.displayedSelection?.provider ?? summary?.provider ?? active?.provider ?? ""
    }
    /// Changes go straight to the current chat.
    private var inPlace: Bool { transcript != nil && provider == currentProvider }

    private var newChat: ManageNewChat? {
        guard let chat = manage?.view?.new_chat, chat.workspace_id == home else { return nil }
        return chat
    }
    private var providers: [ChatChoice] { newChat?.providers ?? [] }
    private var catalogs: ChatCatalogs? { inPlace ? transcript?.input.view?.catalogs : newChat?.catalogs }
    private var selection: ChatSelection? { inPlace ? transcript?.input.displayedSelection : newChat?.selection }

    private func label(_ choices: [ChatChoice]?, _ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return choices?.first { $0.id == value }?.label ?? value
    }

    private var currentLabel: String {
        let catalogs = transcript?.input.view?.catalogs
        let chosen = transcript?.input.displayedSelection
        return brainLabel(provider: providerDisplayName(currentProvider, choices: providers),
                          model: label(catalogs?.models, chosen?.model ?? summary?.model ?? active?.model),
                          effort: label(catalogs?.efforts, chosen?.effort))
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(currentLabel).font(VerdeTheme.ui(16, bold: true))
                    if let name = active?.name {
                        Text("\(name)'s brain does the real work; Live voice uses a separate voice provider.")
                            .font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            } header: { Text("Current brain") }

            Section("Provider") {
                if providers.isEmpty { ProgressView("Loading providers…") }
                ForEach(providers, id: \.id) { choice in
                    Button { Task { await pickProvider(choice.id) } } label: {
                        HStack(spacing: 10) {
                            ProviderGlyph(provider: choice.id)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(choice.label)
                                if let reason = choice.reason, !choice.enabled {
                                    Text(reason).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted)
                                } else if choice.id == currentProvider {
                                    Text("Current").font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted)
                                }
                            }
                            Spacer()
                            if choice.id == provider { Image(systemName: "checkmark").foregroundStyle(VerdeTheme.accent) }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!choice.enabled || working)
                    .accessibilityAddTraits(choice.id == provider ? .isSelected : [])
                }
            }

            Section {
                choice("Model", .model, catalogs?.models ?? [], selection?.model)
                if let efforts = catalogs?.efforts, !efforts.isEmpty { choice("Effort", .effort, efforts, selection?.effort) }
                if let speeds = catalogs?.speeds, speeds.count > 1 { choice("Speed", .speed, speeds, selection?.speed) }
                if newChat?.loading == true && !inPlace { ProgressView("Loading models…") }
            } header: { Text(inPlace ? "Settings" : "Settings for \(providerDisplayName(provider, choices: providers))") } footer: {
                if inPlace { Text("Applies to \(active?.name ?? "your companion")'s current conversation.") }
            }

            if !provider.isEmpty && provider != currentProvider && threadState != .noChat {
                Section {
                    Button { requestSwitch() } label: {
                        HStack { Spacer(); if working { ProgressView() } else { Text("Switch to \(providerDisplayName(provider, choices: providers))") }; Spacer() }
                    }
                    .disabled(working || model.brainSwitch?.inProgress == true)
                    .accessibilityIdentifier("brain-switch")
                } footer: {
                    if threadState == .committed {
                        Text("\(active?.name ?? "Your companion") keeps this conversation: the current brain writes a handoff brief, then the new one takes over.")
                    }
                }
            }
            if let message { Text(message).font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.warning) }
            if let notice = manage?.notice { Text(notice).font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.warning) }
        }
        .scrollContentBackground(.hidden)
        .background(VerdeTheme.background)
        .alert(brainSwitchTitle(name: active?.name ?? "Companion", provider: providerDisplayName(provider, choices: providers)),
               isPresented: $confirming) {
            Button("Switch") { Task { await switchCompanionProvider(provider: provider, model: newChat?.selection.model ?? "", brief: true) } }
            Button("Skip the brief") { Task { await switchCompanionProvider(provider: provider, model: newChat?.selection.model ?? "", brief: false) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(brainSwitchMessage(name: active?.name ?? "Your companion",
                                    from: providerDisplayName(currentProvider, choices: providers),
                                    to: providerDisplayName(provider, choices: providers)))
        }
        .navigationTitle("Brain")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: browse.hostID) { await load() }
        .onDisappear { transcript?.setVisible(false) }
    }

    @ViewBuilder private func choice(_ title: String, _ kind: ComposerPicker, _ choices: [ChatChoice], _ value: String?) -> some View {
        Menu {
            ForEach(choices, id: \.id) { item in
                Button { Task { await pick(kind, item.id) } } label: {
                    if item.id == value { Label(item.label, systemImage: "checkmark") } else { Text(item.label + (item.favorite ? " ★" : "")) }
                }
                .disabled(!item.enabled)
            }
        } label: {
            LabeledContent(title, value: label(choices, value) ?? "Default").frame(minHeight: 44)
        }
        .disabled(choices.isEmpty || working)
    }

    // MARK: Effects

    private func load() async {
        if let conversation, transcript == nil {
            let next = TranscriptModel(browse: browse, workspaceID: conversation.workspace, threadID: conversation.thread)
            next.start()
            next.setVisible(true)
            transcript = next
        }
        let next = ManageModel(browse: browse)
        await next.start()
        manage = next
        if provider.isEmpty { provider = currentProvider }
        if let home {
            await next.select(home, ChatSelection(provider: provider.isEmpty ? nil : provider,
                                                  model: active?.model.isEmpty == false ? active?.model : nil))
        }
    }

    private func pickProvider(_ id: String) async {
        message = nil
        provider = id
        guard let home, let manage else { return }
        // The catalog for that provider (models, efforts) comes from the New chat selection.
        await manage.select(home, ChatSelection(provider: id))
        if threadState == .noChat { await saveRoster(provider: id, model: "") }
    }

    private func pick(_ kind: ComposerPicker, _ value: String) async {
        message = nil
        if inPlace, let input = transcript?.input {
            input.select(kind, value)
            if kind == .model { await saveRoster(provider: currentProvider, model: value) }
            return
        }
        guard let home, let manage else { return }
        var next = newChat?.selection ?? ChatSelection(provider: provider)
        next.provider = provider
        switch kind {
        case .model: next.model = value; next.effort = nil; next.speed = nil
        case .effort: next.effort = value
        case .speed: next.speed = value
        case .access: next.access = value
        case .provider: next = ChatSelection(provider: value)
        }
        await manage.select(home, next)
        if threadState == .noChat, kind == .model { await saveRoster(provider: provider, model: value) }
    }

    private func requestSwitch() {
        switch classifyBrainChange(currentProvider: currentProvider, newProvider: provider, thread: threadState) {
        case .handoff: confirming = true
        default: Task { await switchCompanionProvider(provider: provider, model: newChat?.selection.model ?? "", brief: true) }
        }
    }

    /// The one place a provider change happens.
    /// - No chat yet: the roster only (the first chat uses it).
    /// - Otherwise the host switches the SAME conversation (`companion_brain_switch`): with `brief`,
    ///   the outgoing brain first writes a handoff brief there; the new brain starts with it and the
    ///   recent history. Nothing is lost and nothing is sent on the user's behalf.
    private func switchCompanionProvider(provider: String, model modelID: String, brief: Bool = true) async {
        message = nil
        if classifyBrainChange(currentProvider: currentProvider, newProvider: provider, thread: threadState) == .rosterOnly {
            await saveRoster(provider: provider, model: modelID)
            return
        }
        working = true
        defer { working = false }
        if let error = await model.switchBrain(provider: provider, model: modelID, brief: brief) {
            message = error
        } else {
            message = model.brainSwitch?.inProgress == true ? "Handing off to \(providerDisplayName(provider, choices: providers))…" : nil
        }
    }

    private func saveRoster(provider: String, model modelID: String) async {
        guard let id = active?.id else { return }
        await model.update { $0.setBrain(id, provider: provider, model: modelID) }
    }
}
