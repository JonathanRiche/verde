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
    /// Settings open on the Brain page.
    @State private var settingsBrain = false
    @State private var confirmNew = false
    @State private var conversations = false
    /// A prompt typed or picked before the companion's chat existed; sent once it opens.
    @State private var pendingPrompt: String?
    /// The summary strip's open panel; the header's count toggles it too.
    @State private var panel: CompanionPanel?
    @State private var scheduled = false
    /// Live voice: the full view instead of the floating pill, and the pill's captions card.
    @State private var liveExpanded = false
    @State private var liveCaptions = true

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
        .sheet(isPresented: $settings) { CompanionSettings(model: model, browse: browse, startAtBrain: settingsBrain) }
        .sheet(isPresented: $conversations) {
            CompanionConversations(model: model, browse: browse)
                .presentationDetents([.medium, .large])
        }
        .alert("Start a new conversation?", isPresented: $confirmNew) {
            Button("New conversation") { Task { await model.newConversation() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(newConversationMessage(name: model.active?.name ?? "Your companion"))
        }
        .sheet(isPresented: $scheduled) {
            ScheduledScreen(model: model.schedules, companion: model, browse: browse, openChat: { workspace, thread in
                scheduled = false
                // The companion's own chat is already under this sheet.
                if let chat = model.conversation, chat.workspace == workspace, chat.thread == thread { return }
                open(.thread(workspace: workspace, thread: thread))
            })
        }
        // The header's count of enabled tasks; the Scheduled screen keeps it fresh while open.
        .task(id: browse.hostID) { await model.schedules.refresh() }
    }

    private func content(_ active: RosterEntry) -> some View {
        VStack(spacing: 0) {
            CompanionHeader(model: model, live: live, entry: active, panel: $panel, showHome: showHome,
                            newConversation: { confirmNew = true }, showConversations: { conversations = true },
                            showScheduled: { scheduled = true }) {
                settingsBrain = false; settings = true
            }
            if let handoff = model.brainSwitchText {
                HStack(spacing: 8) {
                    if model.brainSwitch?.inProgress == true { ProgressView().controlSize(.small) }
                    Text(handoff).font(VerdeTheme.ui(12))
                        .foregroundStyle(model.brainSwitch?.status == "failed" ? VerdeTheme.warning : VerdeTheme.accent)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 4)
                .accessibilityElement(children: .combine)
            }
            if let notice = model.notice {
                Text(notice).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 4)
            }
            if !live.active, let failure = live.failure {
                Text(failure).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 4)
            }
            CompanionSummary(model: model, open: open, expanded: $panel)
            Divider().overlay(VerdeTheme.border)
            ZStack(alignment: .top) {
                if live.active && liveExpanded {
                    LiveVoiceFullView(live: live, name: active.name) { liveExpanded = false }
                } else {
                    conversationArea(active)
                }
                // Live floats over the conversation as a pill; it opens into the full view.
                if live.active && !liveExpanded {
                    LivePill(live: live, character: active.character, name: active.name, captionsShown: $liveCaptions,
                             expand: { liveExpanded = true }, openSettings: { settingsBrain = false; settings = true })
                        .padding(.top, 8)
                }
            }
            .onChange(of: live.active) { _, isActive in if !isActive { liveExpanded = false } }
        }
    }

    @ViewBuilder
    private func conversationArea(_ active: RosterEntry) -> some View {
        Group {
            if let conversation = model.conversation {
                CompanionConversation(browse: browse, voice: voice, name: active.name, workspaceID: conversation.workspace,
                                      threadID: conversation.thread, pendingPrompt: $pendingPrompt, onHosts: onHosts,
                                      openBrain: { settingsBrain = true; settings = true })
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
    @Binding var panel: CompanionPanel?
    let showHome: () -> Void
    let newConversation: () -> Void
    let showConversations: () -> Void
    let showScheduled: () -> Void
    let openSettings: () -> Void
    @AppStorage(CompanionBubbleStore.hiddenKey) private var bubbleHidden = false

    var body: some View {
        let presence = model.presence
        // Counts match the strip's capsules (needs list, machine-wide activity), so every count
        // in the header has a panel to open.
        let needs = model.needsYou.count
        let running = model.runningCount
        let working = presence.pose == .working && running == 0
        let connected = presence.pose != .paused
        // The companion's own approval shows inline in the conversation below, so it gets no count.
        let ownApproval = connected && needs == 0 && model.badgeCount > 0
        let suffix = ownApproval ? (text: "waiting on you", tone: SummaryTone.attention)
            : companionStatusSuffix(needsYou: needs, crewRunning: running, working: working,
                                    failed: presence.failure, connected: connected)
        let target: CompanionPanel? = ownApproval ? nil : companionHeaderPanel(needsYou: needs, running: running, working: working,
                                                                               failed: presence.failure, connected: connected)
        let companions = model.roster?.companions ?? []
        HStack(spacing: 8) {
            CompanionAvatar(character: entry.character, pose: presence.pose, failure: presence.failure, width: 28)
            HStack(spacing: 0) {
                Text(entry.name).font(VerdeTheme.ui(16, bold: true)).lineLimit(1)
                    .accessibilityLabel("\(entry.name), \(presence.status)")
                    .accessibilityAddTraits(.isHeader)
                if let target {
                    let isOpen = panel == target
                    Button {
                        withAnimation(AppearanceSettings.shared.reducedMotion ? nil : .easeOut(duration: 0.15)) { panel = isOpen ? nil : target }
                    } label: {
                        HStack(spacing: 3) {
                            Text(" · " + suffix.text).font(VerdeTheme.ui(12)).foregroundStyle(summaryColor(suffix.tone)).lineLimit(1)
                            Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                                .foregroundStyle(VerdeTheme.subtle)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(suffix.text)
                    .accessibilityHint(isOpen ? "Hides the list." : "Shows the list.")
                    .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
                    .accessibilityIdentifier("companion-header-status")
                } else {
                    Text(" · " + suffix.text).font(VerdeTheme.ui(12)).foregroundStyle(summaryColor(suffix.tone)).lineLimit(1)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.schedules.supported {
                let scheduledCount = model.schedules.enabledCount
                Button(action: showScheduled) {
                    HStack(spacing: 2) {
                        Image(systemName: "clock").font(.system(size: 16, weight: .semibold))
                        if scheduledCount > 0 {
                            Text("\(scheduledCount)").font(VerdeTheme.ui(12, bold: true)).monospacedDigit()
                        }
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(scheduledCount > 0 ? "Scheduled tasks, \(scheduledCount) on" : "Scheduled tasks")
                .accessibilityHint("Shows prompts \(entry.name) runs later or on repeat.")
                .accessibilityIdentifier("companion-scheduled")
            }
            Button { live.toggle() } label: {
                Image(systemName: live.active ? "waveform.circle.fill" : "waveform")
                    .font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel(live.active ? "End live conversation" : "Talk live")
            .accessibilityHint(live.active ? "" : "Starts a real-time voice conversation with \(entry.name).")
            .accessibilityIdentifier("companion-live")
            Menu {
                Button(action: newConversation) { Label("New conversation", systemImage: "square.and.pencil") }
                    .disabled(model.conversation == nil || model.saving)
                Button(action: showConversations) { Label("Conversations…", systemImage: "clock.arrow.circlepath") }
                Button(action: showScheduled) { Label("Scheduled tasks…", systemImage: "clock") }
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

/// Two capsules ("3 need you", "2 running · 1 done"), each expanding to a compact list. The
/// activity capsule lists the companion's crew plus every other chat running on the machine.
private struct CompanionSummary: View {
    let model: CompanionModel
    let open: (BrowseRoute) -> Void
    @Binding var expanded: CompanionPanel?

    var body: some View {
        let needs = model.needsYou
        let activity = model.activity
        let needsText = needsSummary(needs.count)
        let activityText = activitySummary(activity)
        Group {
            if needsText != nil || activityText != nil {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if let needsText {
                            capsule(.needs, icon: "exclamationmark.triangle.fill", text: needsText, color: VerdeTheme.warning)
                        }
                        if let activityText {
                            capsule(.activity, icon: "circle.fill", text: activityText,
                                    color: activity.contains { $0.attention == .running } ? VerdeTheme.accent : VerdeTheme.subtle)
                        }
                        Spacer(minLength: 0)
                    }
                    if expanded == .needs && !needs.isEmpty {
                        list(needs.map { item in
                            SummaryRow(id: item.id, color: VerdeTheme.warning, title: item.title,
                                       detail: item.workspaceLabel ?? item.reason, label: item.reason,
                                       route: .thread(workspace: item.workspaceID, thread: item.threadID))
                        })
                    } else if expanded == .activity && !activity.isEmpty {
                        let labels = Dictionary((model.browse.state.workspaces?.items ?? []).map { ($0.workspace_id, $0.label) },
                                                uniquingKeysWith: { a, _ in a })
                        list(activity.map { item in
                            SummaryRow(id: item.id, color: crewColor(item.attention), title: item.title,
                                       detail: labels[item.workspaceID] ?? item.attention.label, label: item.attention.label,
                                       route: .thread(workspace: item.workspaceID, thread: item.threadID))
                        })
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 6)
            }
        }
        // Outside the `if` so a panel whose capsule vanished closes even while the strip is gone.
        .onChange(of: needsText == nil) { _, hidden in if hidden && expanded == .needs { expanded = nil } }
        .onChange(of: activityText == nil) { _, hidden in if hidden && expanded == .activity { expanded = nil } }
    }

    private func capsule(_ section: CompanionPanel, icon: String, text: String, color: Color) -> some View {
        let isOpen = expanded == section
        return Button {
            withAnimation(AppearanceSettings.shared.reducedMotion ? nil : .easeOut(duration: 0.15)) { expanded = isOpen ? nil : section }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: section == .activity ? 7 : 10)).foregroundStyle(color)
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
            VStack(spacing: 2) {
                Group {
                    if voice.listening {
                        HStack(spacing: 8) {
                            LevelMeter(level: voice.level)
                            Text(voice.partial.isEmpty ? "Listening…" : voice.partial).font(VerdeTheme.ui(15)).lineLimit(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        TextField("Message \(name)…", text: $text, axis: .vertical)
                            .lineLimit(1...6)
                            .font(VerdeTheme.ui(15))
                            .accessibilityIdentifier("companion-starter-input")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(VerdeTheme.alternate, in: RoundedRectangle(cornerRadius: 18))
                HStack(spacing: 2) {
                    Spacer(minLength: 4)
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
            }
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
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
    /// The composer's brain label opens Settings → Brain.
    let openBrain: () -> Void
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
        CompactComposer(placeholder: "Message \(name)…",
                        transcript: voice.listening ? voice.partial : nil,
                        level: voice.level,
                        notice: voice.listening ? nil : voice.notice,
                        trailing: AnyView(CompanionMicButton(voice: voice, name: name) { sendVoice($0, model) }),
                        openBrain: openBrain)
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

/// The active companion's conversations: the current one, then earlier ones (newest first).
/// Tap to go back to one; "Remove from list" only drops it from the list.
private struct CompanionConversations: View {
    let model: CompanionModel
    let browse: BrowseModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let entry = model.active
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        NavigationStack {
            List {
                if let entry, !entry.thread_id.isEmpty {
                    Section("Current") {
                        row(title: model.conversationTitle, provider: entry.provider, modelID: entry.model, detail: "Now", current: true)
                    }
                }
                Section {
                    if entry?.history.isEmpty != false {
                        Text("Earlier conversations appear here after you start a new one.")
                            .font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.muted)
                    }
                    ForEach(entry?.history ?? []) { item in
                        Button {
                            Task { if await model.resumeConversation(item.thread_id) { dismiss() } }
                        } label: {
                            row(title: item.title, provider: item.provider, modelID: item.model,
                                detail: item.ended_at_ms > 0 ? agoLabel(item.ended_at_ms, now) : "", current: false)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.saving)
                        .accessibilityHint("Goes back to this conversation.")
                        .swipeActions {
                            Button(role: .destructive) { Task { await model.removeConversation(item.thread_id) } } label: {
                                Label("Remove from list", systemImage: "minus.circle")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) { Task { await model.removeConversation(item.thread_id) } } label: {
                                Label("Remove from list", systemImage: "minus.circle")
                            }
                        }
                    }
                } header: { Text("Earlier") } footer: {
                    Text("Removing only takes a conversation off this list; the chat stays in your history.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(VerdeTheme.background)
            .navigationTitle("Conversations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(VerdeTheme.accent)
    }

    private func row(title: String, provider: String, modelID: String, detail: String, current: Bool) -> some View {
        HStack(spacing: 10) {
            ProviderGlyph(provider: provider.isEmpty ? nil : provider)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(VerdeTheme.ui(14)).lineLimit(1)
                Text(brainLabel(provider: providerDisplayName(provider), model: modelID, effort: nil))
                    .font(VerdeTheme.ui(11)).foregroundStyle(VerdeTheme.subtle).lineLimit(1)
            }
            Spacer(minLength: 6)
            if current { Image(systemName: "checkmark").foregroundStyle(VerdeTheme.accent) }
            else if !detail.isEmpty { Text(detail).font(VerdeTheme.ui(11)).foregroundStyle(VerdeTheme.subtle) }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Settings

enum CompanionSettingsPage: Hashable { case brain }

struct CompanionSettings: View {
    let model: CompanionModel
    let browse: BrowseModel
    /// Opens straight on Brain (from the sheet composer's brain label).
    var startAtBrain = false
    @Environment(\.dismiss) private var dismiss
    @State private var path: [CompanionSettingsPage] = []
    @State private var editingID = ""
    @State private var name = ""
    @State private var character = CompanionCharacter.sprout
    @State private var orders = ""
    @AppStorage(CompanionBubbleStore.hiddenKey) private var bubbleHidden = false

    private var dirty: Bool {
        guard let active = model.active, active.id == editingID else { return false }
        let cleaned = cleanCompanionName(name)
        let renamed = !cleaned.isEmpty && cleaned != active.name
        let changed = character != active.character || orders != active.orders
        return renamed || changed
    }

    var body: some View {
        NavigationStack(path: $path) {
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
            .navigationDestination(for: CompanionSettingsPage.self) { page in
                switch page {
                case .brain: CompanionBrainScreen(model: model, browse: browse)
                }
            }
            .onAppear {
                load()
                if startAtBrain && path.isEmpty { path = [.brain] }
            }
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

    /// Brain: provider, model, effort and speed on their own page.
    private var brain: some View {
        let active = model.active
        let label = brainLabel(provider: providerDisplayName(active?.provider ?? ""), model: active?.model, effort: nil)
        return Section {
            NavigationLink(value: CompanionSettingsPage.brain) {
                LabeledContent("Brain", value: active?.provider.isEmpty == false ? label : "Default brain")
            }
            .accessibilityIdentifier("companion-brain")
        } header: { Text("Brain") } footer: {
            Text("Choose the provider and model that do \(name.isEmpty ? "your companion" : name)'s work.")
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
    }

    /// Saves pending identity, orders and brain edits for the companion being edited.
    private func save() async -> Bool {
        guard dirty else { return true }
        // The brain is saved by its own page; only identity and orders here.
        let id = editingID, newName = name, newCharacter = character, newOrders = orders
        return await model.update { roster in
            guard roster.companions.contains(where: { $0.id == id }) else { return false }
            if !cleanCompanionName(newName).isEmpty { roster.rename(id, to: newName) }
            roster.edit(id) { entry in
                entry.character = newCharacter
                entry.orders = newOrders
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
