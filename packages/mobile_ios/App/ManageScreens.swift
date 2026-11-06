import SwiftUI

struct ManageContainer<Content: View>: View {
    let browse: BrowseModel
    @ViewBuilder let content: (ManageModel) -> Content
    @State private var model: ManageModel?
    var body: some View {
        Group {
            if let model { content(model) }
            else { ProgressView("Loading…") }
        }.task(id: browse.hostID) {
            let next = ManageModel(browse: browse)
            await next.start()
            model = next
        }
    }
}

/// A list section header (S7): sentence case, 13 pt semibold, the muted text colour. Lists
/// uppercase headers by default; this keeps the title as written.
struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(VerdeTheme.ui(13, bold: true)).foregroundStyle(VerdeTheme.muted).textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

struct ManageNotice: View {
    let model: ManageModel
    var body: some View {
        if let notice = model.notice { Text(notice).font(.callout).foregroundStyle(.red).accessibilityIdentifier("manage-error") }
        if model.busy { ProgressView() }
    }
}

struct HistoryScreen: View {
    let browse: BrowseModel
    let manage: ManageModel
    @State private var query = ""
    @State private var workspace = ""
    /// Refreshed every `relativeTimeRefresh` so "12 min ago" keeps up (I2-4).
    @State private var now = Int64(Date().timeIntervalSince1970 * 1000)
    var body: some View {
        List {
            // I12-3: the search field sits in the list's 720-point column, not across the bar.
            HistorySearchField(query: $query)
            ManageNotice(model: manage)
            Picker("Workspace", selection: $workspace) {
                Text("All workspaces").tag("")
                ForEach(browse.state.workspaces?.items ?? [], id: \.workspace_id) { item in
                    Text(workspaceDisplayLabel(item, among: browse.state.workspaces?.items ?? [])).tag(item.workspace_id)
                }
            }
            let history = browse.state.workspaces?.history
            let live = liveActivity(browse.state.workspaces)
            // I10-5: ordered by the activity the rows show (live activity included).
            // The companion's own conversation lives in its pane, not in History (U1 iPad).
            let hidden = browse.companionThreads
            let sections = historySections((history?.items ?? []).filter { !hidden.contains($0.thread_id) }.map { withLiveActivity($0, live) })
            let labels = Dictionary((browse.state.workspaces?.items ?? []).map { ($0.workspace_id, $0.label) }, uniquingKeysWith: { a, _ in a })
            ForEach(sections.indices, id: \.self) { index in
                Section {
                    ForEach(sections[index].1, id: \.thread_id) { thread in
                        let subtitle = historySubtitle(withLiveActivity(thread, live), workspace: labels[thread.workspace_id], now: now)
                        NavigationLink(value: BrowseRoute.thread(workspace: thread.workspace_id, thread: thread.thread_id)) {
                            HStack(alignment: .top, spacing: 12) {
                                ProviderGlyph(provider: thread.provider).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(thread.title.isEmpty ? "Untitled chat" : thread.title).font(VerdeTheme.ui(16)).lineLimit(2)
                                    if !subtitle.isEmpty { Text(subtitle).font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.muted).lineLimit(2) }
                                }
                                Spacer(minLength: 4)
                                GitThreadDot(browse: browse, workspace: thread.workspace_id, thread: thread.thread_id)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                } header: { SectionTitle(sections[index].0) }
            }
            if history?.loading == true { ProgressView("Loading chats…") }
            else if history?.next_cursor != nil { Button("Load more") { Task { await manage.moreHistory() } } }
            else if sections.isEmpty { Text("No chats match.") }
            if let error = history?.error { Text(error.message).foregroundStyle(.red) }
        }
        .modifier(ReadableListWidth())
        .navigationTitle("History").navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(relativeTimeRefresh))
                now = Int64(Date().timeIntervalSince1970 * 1000)
            }
        }
        .task(id: query + "\u{0}" + workspace) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await manage.history(query, workspace: workspace.isEmpty ? nil : workspace)
        }
        .onDisappear { Task { await manage.history("", workspace: nil) } }
    }
}

/// History's search field, a row of the list so it keeps the list's width.
private struct HistorySearchField: View {
    @Binding var query: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(VerdeTheme.subtle).accessibilityHidden(true)
            TextField("Search chats", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search).accessibilityIdentifier("history-search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(VerdeTheme.subtle)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.borderless).frame(width: 44, height: 44)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12).frame(minHeight: 44)
        .background(VerdeTheme.alternate, in: RoundedRectangle(cornerRadius: 10))
        .listRowSeparator(.hidden)
    }
}

struct NewChatScreen: View {
    let browse: BrowseModel
    let manage: ManageModel
    let initialWorkspace: String?
    @State private var workspace = ""
    @Environment(\.openRoute) private var openRoute
    var body: some View {
        let workspaces = (browse.state.workspaces?.items ?? []).filter(\.open)
        let chat = manage.view?.new_chat
        let selection = chat?.selection ?? ChatSelection()
        Form {
            ManageNotice(model: manage)
            if workspaces.isEmpty { Text("Add a workspace first.") }
            Picker("Workspace", selection: $workspace) {
                ForEach(workspaces, id: \.workspace_id) { Text($0.label).tag($0.workspace_id) }
            }.disabled(manage.busy)
            if let path = workspaces.first(where: { $0.workspace_id == workspace })?.path {
                LabeledContent("Working directory", value: path) .font(VerdeTheme.ui(12))
            }
            if chat?.workspace_id == workspace {
                choice("Provider", value: selection.provider, choices: chat?.providers ?? []) { value in ChatSelection(provider: value) }
                choice("Model", value: selection.model, choices: chat?.catalogs.models ?? []) { value in var s = selection; s.model = value; s.effort = nil; s.speed = nil; return s }
                choice("Effort", value: selection.effort, choices: chat?.catalogs.efforts ?? []) { value in var s = selection; s.effort = value; return s }
                choice("Access", value: selection.access, choices: chat?.catalogs.access ?? []) { value in var s = selection; s.access = value; return s }
                choice("Speed", value: selection.speed, choices: chat?.catalogs.speeds ?? []) { value in var s = selection; s.speed = value; return s }
                if chat?.loading == true { ProgressView("Loading models…") }
                if let error = chat?.error {
                    Text(newChatModelMessage(error))
                        .foregroundStyle(error.rpc_code == "provider_unavailable" ? VerdeTheme.warning : VerdeTheme.danger)
                        .accessibilityIdentifier("new-chat-model-notice")
                }
            }
            Section {
                Button {
                    Task {
                        if let job = await manage.createThread(workspace), let thread = job.thread_id {
                            openRoute(.thread(workspace: job.workspace_id ?? workspace, thread: thread))
                        }
                    }
                } label: {
                    if manage.busy { ProgressView().tint(VerdeTheme.onAccent) } else { Text("Start chat") }
                }
                .modifier(PrimaryRow())
                .disabled(manage.busy || chat?.workspace_id != workspace || chat?.can_create != true)
                .accessibilityLabel("Start chat")
                .accessibilityIdentifier("create-chat")
            }
        }
        // I12-3: every content screen keeps the same centred 720-point column.
        .modifier(ReadableListWidth())
        .navigationTitle("New chat").navigationBarTitleDisplayMode(.inline)
        .onAppear { workspace = initialWorkspace ?? mostRecentOpenWorkspace(workspaces)?.workspace_id ?? "" }
        .task(id: workspace) { if !workspace.isEmpty { await manage.select(workspace) } }
    }
    /// The whole row opens the menu (not only its value), and the menu marks the current choice.
    @ViewBuilder private func choice(_ label: String, value: String?, choices: [ChatChoice], update: @escaping (String) -> ChatSelection) -> some View {
        if !choices.isEmpty {
            let catalogs = manage.view?.new_chat.catalogs
            let resolved = label == "Model" ? catalogs?.default_model_label : label == "Effort" ? catalogs?.default_effort_label : nil
            let shown = newChatChoiceLabel(label, value: value, choices: choices, defaultLabel: resolved)
            Menu {
                ForEach(choices, id: \.id) { item in
                    let current = newChatIsCurrent(label, item: item, value: value, choices: choices)
                    // S25 / I10-1: "Auto · provider default" for effort, the host default "(default)".
                    let title = newChatMenuLabel(label, item, defaultModel: catalogs?.default_model_label) + (item.favorite ? " ★" : "")
                    Button { Task { await manage.select(workspace, update(item.id)) } } label: {
                        if current { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }.disabled(!item.enabled)
                }
            } label: {
                HStack(spacing: 8) {
                    Text(label).foregroundStyle(VerdeTheme.text)
                    Spacer(minLength: 8)
                    Text(shown).foregroundStyle(VerdeTheme.muted).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(VerdeTheme.subtle)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .disabled(manage.busy)
            .accessibilityLabel(label)
            .accessibilityValue(shown)
            .accessibilityHint("Opens the \(label.lowercased()) choices.")
        }
    }
}

/// The host's default when a new chat leaves a setting unset (client_core manage.zig).
func newChatDefault(_ setting: String) -> String? {
    switch setting {
    case "Access": return defaultAccessID
    case "Speed": return "off"
    default: return nil
    }
}

/// A New chat row's value (I10-1): the chosen label, else what the default resolves to ("Full
/// access", "Standard", "Opus 5.5"), unset effort "Auto". Never a bare "Default".
func newChatChoiceLabel(_ setting: String, value: String?, choices: [ChatChoice], defaultLabel: String? = nil) -> String {
    if setting == "Model" { return composerModelLabel(choices, value: value, defaultLabel: defaultLabel) }
    if setting == "Effort" { return composerEffortLabel(choices, value: value, defaultLabel: defaultLabel) }
    if setting == "Speed" { return composerSpeedLabel(value?.isEmpty == false ? value : newChatDefault(setting)) }
    if setting == "Access" { return composerAccessLabel(choices, value: value) }
    if let value, !value.isEmpty { return choices.first { $0.id == value }?.label ?? value }
    return "Auto"
}

/// The menu row to check: the chosen one, else the row an unset setting means (effort's and
/// model's default row, access's and speed's host default).
func newChatIsCurrent(_ setting: String, item: ChatChoice, value: String?, choices: [ChatChoice]) -> Bool {
    if let value, !value.isEmpty { return item.id == value }
    if let id = newChatDefault(setting) { return item.id == id }
    let picker: ComposerPicker = setting == "Model" ? .model : .effort
    let unset = composerCurrentChoice(picker, value: nil, choices: choices)
    return item.id == unset || (isDefaultChoice(unset) && isDefaultChoice(item.id))
}

/// A New chat menu row, in the composer pickers' words.
func newChatMenuLabel(_ setting: String, _ item: ChatChoice, defaultModel: String? = nil) -> String {
    switch setting {
    case "Effort": return isDefaultChoice(item.id) ? "Auto · provider default" : item.label
    case "Model": return composerPickerLabel(.model, item, defaultModel: defaultModel)
    case "Speed": return composerPickerLabel(.speed, item)
    case "Access": return composerPickerLabel(.access, item)
    default: return item.label
    }
}

struct AddWorkspaceScreen: View {
    let manage: ManageModel
    @State private var path = ""
    @State private var label = ""
    @Environment(\.openRoute) private var openRoute
    var body: some View {
        let problem = workspacePathProblem(path)
        Form {
            ManageNotice(model: manage)
            Section {
                TextField("Folder on the computer, e.g. /Users/you/project", text: $path)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).submitLabel(.done)
                    .accessibilityLabel("Folder on the computer")
                    .accessibilityIdentifier("workspace-path")
                if let problem {
                    Text(problem).font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.danger).accessibilityIdentifier("workspace-path-problem")
                }
                TextField("Name (optional)", text: $label).accessibilityLabel("Workspace name, optional")
            } header: { SectionTitle("Workspace") }
            Section {
                Button {
                    Task {
                        if let job = await manage.createWorkspace(path: path, label: label), let id = job.workspace_id { openRoute(.workspace(id)) }
                    }
                } label: {
                    if manage.busy { ProgressView().tint(VerdeTheme.onAccent) } else { Text("Add workspace") }
                }
                .modifier(PrimaryRow())
                .disabled(normalizedWorkspacePath(path).isEmpty || problem != nil || manage.busy || manage.view?.can_manage_workspaces != true)
                .accessibilityLabel("Add workspace")
                .accessibilityIdentifier("add-workspace")
            }
            Section {
                if let directory = manage.view?.directory {
                    if !directory.supported { Text("Folder browsing needs a newer host. You can still enter a path.") }
                    else {
                        // Host lists can repeat a folder; a repeated row id can break the list's updates.
                        ForEach(freshFolderSuggestions(directory.suggestions, workspaces: manage.browse.state.workspaces?.items ?? []), id: \.self) { root in
                            folderRow(root, systemImage: "folder") { Task { await manage.directory(root) } }
                        }
                        if !directory.path.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "folder.fill").foregroundStyle(VerdeTheme.accent).accessibilityHidden(true)
                                Text(directory.path).font(VerdeTheme.mono(12)).foregroundStyle(VerdeTheme.text).lineLimit(3).textSelection(.enabled)
                            }
                            .accessibilityElement(children: .combine).accessibilityLabel("Current folder, \(directory.path)")
                            Button("Use this folder") { path = directory.path; manage.notice = nil }
                                .buttonStyle(TonalButtonStyle())
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                                .disabled(directory.loading || directory.error != nil)
                        }
                        if let parent = directory.parent { folderRow("Up one folder", systemImage: "arrow.turn.left.up") { Task { await manage.directory(parent) } } }
                        ForEach(uniqued(directory.entries, by: \.path), id: \.path) { entry in
                            folderRow(entry.name, systemImage: "folder") { Task { await manage.directory(entry.path) } }
                        }
                        if directory.loading { ProgressView() }
                        if let error = directory.error { Text(workspaceFolderMessage(error)).foregroundStyle(VerdeTheme.danger) }
                    }
                }
            } header: { SectionTitle("Browse folders") }
            .disabled(manage.busy)
        }
        .modifier(ReadableListWidth())
        .navigationTitle("Add workspace").navigationBarTitleDisplayMode(.inline)
        .task { await manage.directory() }
    }

    /// A folder to browse into: icon, name and a chevron, the whole row tappable.
    private func folderRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage).foregroundStyle(VerdeTheme.muted).frame(width: 20).accessibilityHidden(true)
                Text(title).foregroundStyle(VerdeTheme.text).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.forward").font(.system(size: 12, weight: .semibold)).foregroundStyle(VerdeTheme.subtle).accessibilityHidden(true)
            }
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint("Shows this folder's subfolders.")
    }
}

struct WorkspaceActions: View {
    let workspace: Workspace
    let manage: ManageModel
    @State private var rename = false
    @State private var close = false
    @State private var styling = false
    @State private var label = ""
    var body: some View {
        // Each presenter sits on its own row: modifiers on a List section apply to every row in
        // it, and several rows presenting one sheet at once present nothing.
        Section {
            ManageNotice(model: manage)
            NavigationLink("New chat", value: BrowseRoute.newChat(workspace.workspace_id)).disabled(manage.view?.can_create_threads != true)
            NavigationLink("History", value: BrowseRoute.history)
            Button("Rename workspace") { label = workspace.label; rename = true }.disabled(manage.view?.can_manage_workspaces != true)
                .alert("Rename workspace", isPresented: $rename) {
                    TextField("Name", text: $label)
                    Button("Cancel", role: .cancel) {}
                    Button("Rename") { Task { await manage.workspace("rename", id: workspace.workspace_id, value: label) } }.disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            Button { styling = true } label: {
                HStack {
                    Text("Icon and color").foregroundStyle(VerdeTheme.text)
                    Spacer()
                    WorkspaceChip(workspace: workspace, size: 28)
                    Image(systemName: "chevron.forward").font(.system(size: 12, weight: .semibold)).foregroundStyle(VerdeTheme.subtle)
                }
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .disabled(manage.view?.can_manage_workspaces != true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Icon and color")
            .accessibilityValue(workspaceIconNames[((Int(workspace.icon_index) % 16) + 16) % 16])
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("workspace-identity")
            .sheet(isPresented: $styling) {
                WorkspaceIdentitySheet(workspace: workspace) { icon, color in
                    Task { await manage.identity(workspace.workspace_id, icon: icon, color: color) }
                }.presentationDetents([.medium, .large])
            }
            if workspace.open {
                Button("Close workspace", role: .destructive) { close = true }.disabled(manage.view?.can_manage_workspaces != true)
                    .foregroundStyle(VerdeTheme.danger)
                    .confirmationDialog("Close this workspace and its sessions?", isPresented: $close, titleVisibility: .visible) {
                        Button("Close workspace", role: .destructive) { Task { await manage.workspace("close", id: workspace.workspace_id) } }
                    } message: { Text("The host will refuse to close a workspace while requests or background tasks are running.") }
            }
            else { Button("Reopen workspace") { Task { await manage.workspace("reopen", id: workspace.workspace_id) } }.disabled(manage.view?.can_manage_workspaces != true) }
        } header: { SectionTitle("Workspace actions") }
        .disabled(manage.busy)
    }
}

struct ThreadActions: View {
    let workspace: String
    let thread: String
    let title: String
    let manage: ManageModel
    /// The chat's git actions; on phones they live here instead of in the header (S1).
    var git: GitChangesModel? = nil
    @State private var rename = false
    @State private var close = false
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.adaptive) private var adaptive
    var body: some View {
        Menu {
            if let git, !adaptive.inlineGit { Section { GitMenuItems(model: git) }.disabled(git.busy) }
            Button("Rename chat") { name = title; rename = true }
            Button("Sync chat") { Task { await manage.thread("sync", workspace: workspace, thread: thread) } }
            Button("Close chat", role: .destructive) { close = true }
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
        .accessibilityLabel("Chat actions").disabled(manage.busy || !canWrite(manage.browse.state.host))
        .alert("Rename chat", isPresented: $rename) {
            TextField("Title", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { Task { await manage.thread("rename", workspace: workspace, thread: thread, title: name) } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("Close chat?", isPresented: $close, titleVisibility: .visible) {
            Button("Close chat", role: .destructive) { Task { if await manage.thread("close", workspace: workspace, thread: thread) != nil { dismiss() } } }
        }
        .alert("Chat action", isPresented: Binding(get: { manage.notice != nil }, set: { if !$0 { manage.notice = nil } })) {
            Button("OK") { manage.notice = nil }
        } message: { Text(manage.notice ?? "") }
    }
}
