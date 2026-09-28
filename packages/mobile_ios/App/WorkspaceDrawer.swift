import SwiftUI

func drawerThreads(_ workspace: Workspace) -> [ThreadSummary] {
    let open = Set(workspace.panes.compactMap(\.thread_id))
    return workspaceThreads(workspace).filter { !$0.archived && open.contains($0.thread_id) }
}

struct WorkspaceDrawer: View {
    let browse: BrowseModel
    let selected: BrowseRoute?
    let tab: RootTab
    let close: () -> Void
    let open: (BrowseRoute) -> Void
    let root: (RootTab) -> Void
    let settings: () -> Void
    @State private var folded: Set<String> = []
    @State private var search = ""
    @State private var manage: ManageModel?
    @State private var renaming: ThreadSummary?
    @State private var title = ""
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VerdeWordmark(); Spacer()
                Button { open(.addWorkspace) } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.accessibilityLabel("Add workspace")
                Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("Close workspace drawer")
            }.padding(.horizontal, 12)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(VerdeTheme.subtle)
                TextField("Chats and workspaces", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
            }.padding(14)
            Rectangle().fill(VerdeTheme.border).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    HStack {
                        row("Home", icon: "house", selected: selected == nil && tab == .home) { root(.home) }
                        row("Workspaces", icon: "square.stack", selected: selected == nil && tab == .workspaces) { root(.workspaces) }
                    }
                    HStack {
                        row("New chat", icon: "square.and.pencil") { open(.newChat(nil)) }
                        row("History", icon: "clock") { open(.history) }
                    }
                    let workspaces = (browse.state.workspaces?.items ?? []).filter(\.open)
                    let active = workspaces.flatMap(drawerThreads).filter { activeTurn($0.status) || $0.status == "waiting_approval" }
                    if !active.isEmpty && search.isEmpty {
                        section("Active")
                        ForEach(active, id: \.thread_id) { chat($0) }
                        Divider().overlay(VerdeTheme.border).padding(8)
                    }
                    ForEach(workspaces, id: \.workspace_id) { workspace in
                        let threads = drawerThreads(workspace).filter { matches($0.title) || matches(workspace.label) }
                        let terminals = workspace.panes.filter { $0.kind == "terminal" && $0.terminal_id != nil && (matches($0.title) || matches(workspace.label)) }
                        if matches(workspace.label) || !threads.isEmpty || !terminals.isEmpty {
                            HStack {
                                Button { if !folded.insert(workspace.workspace_id).inserted { folded.remove(workspace.workspace_id) } } label: {
                                    Image(systemName: folded.contains(workspace.workspace_id) ? "chevron.right" : "chevron.down").font(.caption).frame(width: 32, height: 44)
                                }.accessibilityLabel((folded.contains(workspace.workspace_id) ? "Expand " : "Collapse ") + workspace.label)
                                Button { open(.workspace(workspace.workspace_id)) } label: { Text(workspace.label).font(VerdeTheme.ui(13, bold: true)).lineLimit(1).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }
                                Menu {
                                    Button("New chat") { open(.newChat(workspace.workspace_id)) }
                                    Button("New terminal") { open(.newTerminal(workspace: workspace.workspace_id, request: UUID())) }
                                    Button("History") { open(.history) }
                                    Button("Workspace actions") { open(.workspace(workspace.workspace_id)) }
                                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel(workspace.label + " actions")
                            }.foregroundStyle(VerdeTheme.muted)
                            if !folded.contains(workspace.workspace_id) || !search.isEmpty {
                                ForEach(threads, id: \.thread_id) { chat($0) }
                                ForEach(terminals, id: \.id) { pane in
                                    if let id = pane.terminal_id {
                                        row(pane.title, icon: "terminal", selected: selected == .terminal(workspace: workspace.workspace_id, terminal: id)) { open(.terminal(workspace: workspace.workspace_id, terminal: id)) }
                                    }
                                }
                            }
                        }
                    }
                    if workspaces.isEmpty { Text("Pair with a host to see your workspaces.").font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.muted).padding(16) }
                }.padding(.horizontal, 8)
            }
            Divider().overlay(VerdeTheme.border)
            row("Settings", icon: "gearshape", action: settings).padding(.horizontal, 8)
            row(browse.state.row?.saved.label ?? "Hosts", icon: "desktopcomputer", selected: tab == .hosts) { root(.hosts) }.accessibilityIdentifier("drawer-hosts").padding(8)
        }
        .background(VerdeTheme.panel).foregroundStyle(VerdeTheme.text)
        .task(id: browse.hostID) {
            let next = ManageModel(browse: browse)
            await next.start()
            manage = next
        }
        .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $title)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") { if let thread = renaming { action("rename", thread, title: title) }; renaming = nil }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Chat action", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") { notice = nil }
        } message: { Text(notice ?? "") }
        .accessibilityElement(children: .contain).accessibilityAddTraits(.isModal)
    }
    private func matches(_ value: String) -> Bool { search.isEmpty || value.localizedCaseInsensitiveContains(search) }
    private func section(_ text: String) -> some View { Text(text.uppercased()).font(VerdeTheme.ui(10, bold: true)).tracking(0.8).foregroundStyle(VerdeTheme.subtle).padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4).accessibilityAddTraits(.isHeader) }
    private func row(_ title: String, icon: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) { Image(systemName: icon).frame(width: 18); Text(title).lineLimit(1); Spacer(minLength: 0) }
                .font(VerdeTheme.ui(13)).padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
                .background(selected ? VerdeTheme.accent.opacity(0.19) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func action(_ action: String, _ thread: ThreadSummary, title: String = "") {
        guard let manage, !manage.busy else { return }
        Task {
            let result = await manage.thread(action, workspace: thread.workspace_id, thread: thread.thread_id, title: title)
            notice = manage.notice
            if result != nil && action == "close" && selected == .thread(workspace: thread.workspace_id, thread: thread.thread_id) { root(.home) }
        }
    }
    private func chat(_ thread: ThreadSummary) -> some View {
        let target = BrowseRoute.thread(workspace: thread.workspace_id, thread: thread.thread_id)
        return Button { open(target) } label: {
            HStack(spacing: 10) {
                ProviderGlyph(provider: thread.provider)
                Text(thread.title.isEmpty ? "New chat" : thread.title).lineLimit(1)
                Spacer(minLength: 0)
                GitThreadDot(browse: browse, workspace: thread.workspace_id, thread: thread.thread_id)
                StatusPip(active: activeTurn(thread.status), attention: thread.status == "waiting_approval", failed: thread.status == "failed")
            }.font(VerdeTheme.ui(13)).padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
                .background(selected == target ? VerdeTheme.accent.opacity(0.19) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .leading) { if selected == target { RoundedRectangle(cornerRadius: 2).fill(VerdeTheme.accent).frame(width: 2).padding(.vertical, 10) } }
        }.buttonStyle(.plain)
        .contextMenu {
            Button("Open") { open(target) }
            Button("Copy title") { UIPasteboard.general.string = thread.title }
            Button("Rename") { title = thread.title; renaming = thread }.disabled(manage == nil || manage?.busy == true)
            Button("Sync") { action("sync", thread) }.disabled(manage == nil || manage?.busy == true)
            Button("Close", role: .destructive) { action("close", thread) }.disabled(manage == nil || manage?.busy == true)
        }
        .accessibilityIdentifier("drawer-chat").accessibilityAddTraits(selected == target ? .isSelected : [])
    }
}
