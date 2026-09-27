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
    var body: some View {
        List {
            ManageNotice(model: manage)
            Picker("Workspace", selection: $workspace) {
                Text("All workspaces").tag("")
                ForEach(browse.state.workspaces?.items ?? [], id: \.workspace_id) { Text($0.label).tag($0.workspace_id) }
            }
            let history = browse.state.workspaces?.history
            let sections = historySections(history?.items ?? [])
            ForEach(sections.indices, id: \.self) { index in
                Section(sections[index].0) {
                    ForEach(sections[index].1, id: \.thread_id) { thread in
                        NavigationLink(value: BrowseRoute.thread(workspace: thread.workspace_id, thread: thread.thread_id)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(thread.title).lineLimit(2)
                                Text([thread.provider, thread.archived ? "Archived" : nil, thread.cwd].compactMap { $0 }.joined(separator: " · ")) .font(VerdeTheme.ui(12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            if history?.loading == true { ProgressView("Loading chats…") }
            else if history?.next_cursor != nil { Button("Load more") { Task { await manage.moreHistory() } } }
            else if sections.isEmpty { Text("No chats match.") }
            if let error = history?.error { Text(error.message).foregroundStyle(.red) }
        }
        .navigationTitle("History").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search chats")
        .task(id: query + "\u{0}" + workspace) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await manage.history(query, workspace: workspace.isEmpty ? nil : workspace)
        }
        .onDisappear { Task { await manage.history("", workspace: nil) } }
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
            Button("Start chat") {
                Task {
                    if let job = await manage.createThread(workspace), let thread = job.thread_id {
                        openRoute(.thread(workspace: job.workspace_id ?? workspace, thread: thread))
                    }
                }
            }.disabled(manage.busy || chat?.workspace_id != workspace || chat?.can_create != true)
                .accessibilityIdentifier("create-chat")
        }.navigationTitle("New chat").navigationBarTitleDisplayMode(.inline)
        .onAppear { workspace = initialWorkspace ?? workspaces.first?.workspace_id ?? "" }
        .task(id: workspace) { if !workspace.isEmpty { await manage.select(workspace) } }
    }
    @ViewBuilder private func choice(_ label: String, value: String?, choices: [ChatChoice], update: @escaping (String) -> ChatSelection) -> some View {
        if !choices.isEmpty {
            Menu {
                ForEach(choices, id: \.id) { item in
                    Button(item.label + (item.favorite ? " ★" : "")) { Task { await manage.select(workspace, update(item.id)) } }.disabled(!item.enabled)
                }
            } label: { LabeledContent(label, value: choices.first { $0.id == value }?.label ?? value ?? "Default") }
                .disabled(manage.busy)
        }
    }
}

struct AddWorkspaceScreen: View {
    let manage: ManageModel
    @State private var path = ""
    @State private var label = ""
    @Environment(\.openRoute) private var openRoute
    var body: some View {
        Form {
            ManageNotice(model: manage)
            Section("Workspace") {
                TextField("Folder on the computer", text: $path).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("workspace-path")
                TextField("Name (optional)", text: $label)
                Button("Add workspace") {
                    Task { if let job = await manage.createWorkspace(path: path, label: label), let id = job.workspace_id { openRoute(.workspace(id)) } }
                }.disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manage.busy || manage.view?.can_manage_workspaces != true)
            }
            Section("Browse folders") {
                if let directory = manage.view?.directory {
                    if !directory.supported { Text("Folder browsing needs a newer host. You can still enter a path.") }
                    else {
                        ForEach(directory.suggestions, id: \.self) { root in Button(root) { Task { await manage.directory(root) } } }
                        if !directory.path.isEmpty {
                            Text(directory.path) .font(VerdeTheme.ui(12))
                            Button("Use this folder") { path = directory.path }.disabled(directory.loading || directory.error != nil)
                        }
                        if let parent = directory.parent { Button("Up one folder") { Task { await manage.directory(parent) } } }
                        ForEach(directory.entries, id: \.path) { entry in Button(entry.name) { Task { await manage.directory(entry.path) } } }
                        if directory.loading { ProgressView() }
                        if let error = directory.error { Text(error.message).foregroundStyle(.red) }
                    }
                }
            }.disabled(manage.busy)
        }.navigationTitle("Add workspace").navigationBarTitleDisplayMode(.inline)
        .task { await manage.directory() }
    }
}

struct WorkspaceActions: View {
    let workspace: Workspace
    let manage: ManageModel
    @State private var rename = false
    @State private var close = false
    @State private var label = ""
    var body: some View {
        Section("Workspace actions") {
            ManageNotice(model: manage)
            NavigationLink("New chat", value: BrowseRoute.newChat(workspace.workspace_id)).disabled(manage.view?.can_create_threads != true)
            NavigationLink("History", value: BrowseRoute.history)
            Button("Rename workspace") { label = workspace.label; rename = true }.disabled(manage.view?.can_manage_workspaces != true)
            if workspace.open { Button("Close workspace", role: .destructive) { close = true }.disabled(manage.view?.can_manage_workspaces != true) }
            else { Button("Reopen workspace") { Task { await manage.workspace("reopen", id: workspace.workspace_id) } }.disabled(manage.view?.can_manage_workspaces != true) }
        }.disabled(manage.busy)
        .alert("Rename workspace", isPresented: $rename) {
            TextField("Name", text: $label)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { Task { await manage.workspace("rename", id: workspace.workspace_id, value: label) } }.disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("Close this workspace and its sessions?", isPresented: $close, titleVisibility: .visible) {
            Button("Close workspace", role: .destructive) { Task { await manage.workspace("close", id: workspace.workspace_id) } }
        } message: { Text("The host will refuse to close a workspace while requests or background tasks are running.") }
    }
}

struct ThreadActions: View {
    let workspace: String
    let thread: String
    let title: String
    let manage: ManageModel
    @State private var rename = false
    @State private var close = false
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Menu {
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
