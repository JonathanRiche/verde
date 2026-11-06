import SwiftUI

func drawerThreads(_ workspace: Workspace, hidden: Set<String> = []) -> [ThreadSummary] {
    let open = Set(workspace.panes.compactMap(\.thread_id))
    return workspaceThreads(workspace, hidden: hidden).filter { !$0.archived && open.contains($0.thread_id) }
}

/// Switcher order: the core's recency rank (focus/activity newest first, closed untimed last).
func switcherWorkspaces(_ items: [Workspace]) -> [Workspace] {
    dedupedWorkspaces(items).enumerated().sorted { ($0.element.recency_rank, $0.offset) < ($1.element.recency_rank, $1.offset) }.map(\.element)
}

/// Target for new chats/terminals under All Workspaces.
func mostRecentOpenWorkspace(_ items: [Workspace]) -> Workspace? {
    switcherWorkspaces(items).first(where: \.open)
}

/// Case-insensitive subsequence match, matching the desktop/web switcher.
func fuzzyMatches(_ query: String, _ value: String) -> Bool {
    let q = Array(query.trimmingCharacters(in: .whitespaces).lowercased())
    if q.isEmpty { return true }
    var i = 0
    for c in value.lowercased() where i < q.count && c == q[i] { i += 1 }
    return i == q.count
}

struct DrawerItem: Identifiable {
    let workspace: Workspace
    let thread: ThreadSummary?
    let pane: Pane?
    var id: String { workspace.workspace_id + ":" + (thread?.thread_id ?? pane?.terminal_id ?? "") }
    var title: String { thread.map { $0.title.isEmpty ? "New chat" : $0.title } ?? pane?.title ?? "" }
    /// One rule with Home (I10-3): running (a live turn or process) or needing you per the core.
    /// A failed chat counts only while unacknowledged, which the core's `needs_you` already says.
    var active: Bool { drawerRowActive(thread: thread, pane: pane) }
    /// A chat's last activity; terminals carry no synced status-change time yet.
    var activityMs: Int64? { thread?.last_activity_at_ms }
}

/// The footer tab to mark: the current screen, as on Android. A chat, Files, Changes or any pushed
/// screen is under Workspaces; Home, Hosts and Settings only when they are on screen. The back
/// button is the chevron alone, so it never names a different section.
func drawerFooterDestination(tab: RootTab, route: BrowseRoute?) -> RootTab {
    // One rule on both platforms, by the current screen's type.
    guard tab.showsBrowse, let route else { return tab }
    switch route {
    case .history, .newChat: return .home
    case .thread, .terminal, .newTerminal, .changes, .files, .patch, .workspaceFile, .workspace, .addWorkspace: return .workspaces
    }
}

/// Active = what Home lists above Recent (S39): a chat the core classes needs you, running or
/// failed (C11); a terminal running a process.
func drawerRowActive(thread: ThreadSummary?, pane: Pane?) -> Bool {
    if let thread { return coreChatState(thread.state ?? pane?.state).isActive }
    return pane?.can_stop == true
}

/// Flat Active/Open rows by workspace recency. Both follow the scope (nil = All Workspaces):
/// a workspace's drawer lists only its own chats, active ones included. Under All Workspaces Open interleaves
/// every workspace newest activity first (untimed last; ties keep workspace then layout
/// order), matching the desktop sidebar. Companion chats (`hidden`) never appear; the bubble opens them.
func drawerItems(_ items: [Workspace], scope: String?, hidden: Set<String> = []) -> (active: [DrawerItem], open: [DrawerItem]) {
    let rows = switcherWorkspaces(items).filter(\.open).flatMap { ws -> [DrawerItem] in
        let chats: [DrawerItem] = drawerThreads(ws, hidden: hidden).map { thread in DrawerItem(workspace: ws, thread: thread, pane: ws.panes.first { $0.thread_id == thread.thread_id }) }
        return chats + ws.panes.filter { $0.kind == "terminal" && $0.terminal_id != nil }.map { DrawerItem(workspace: ws, thread: nil, pane: $0) }
    }
    let open = rows.filter { !$0.active && (scope == nil || $0.workspace.workspace_id == scope) }
    let active = rows.filter { $0.active && (scope == nil || $0.workspace.workspace_id == scope) }
    guard scope == nil else { return (active, open) }
    let recent = open.enumerated().sorted {
        let (l, r) = ($0.element.activityMs ?? .min, $1.element.activityMs ?? .min)
        return l != r ? l > r : $0.offset < $1.offset
    }.map(\.element)
    return (active, recent)
}

struct WorkspaceDrawer: View {
    let browse: BrowseModel
    let selected: BrowseRoute?
    let tab: RootTab
    /// Sidebar scope; nil is All Workspaces. It filters the drawer only.
    @Binding var scope: String?
    let close: () -> Void
    let open: (BrowseRoute) -> Void
    let root: (RootTab) -> Void
    let settings: () -> Void
    /// A sidebar beside the content rather than a modal overlay.
    var permanent = false
    /// Moss's docked controls, above the footer.
    var dock: AnyView? = nil
    /// The drawer's own width; the scope popover stays inside it (I11-7).
    var width: CGFloat = AdaptivePanes.sidebarWidth
    @Environment(\.verticalSizeClass) private var verticalSize
    @State private var search = ""
    @State private var switching = false
    @State private var workspaceQuery = ""
    /// Closed workspaces sit in a collapsed group; a query searches them regardless.
    @State private var closedExpanded = false
    @State private var manage: ManageModel?
    @State private var renaming: ThreadSummary?
    @State private var title = ""
    @State private var notice: String?
    /// I12-9: row icons grow with the text.
    @ScaledMetric(relativeTo: .footnote) private var chipSize: CGFloat = 16
    @ScaledMetric(relativeTo: .footnote) private var glyphSize: CGFloat = 18

    var body: some View {
        let all = browse.state.workspaces?.items ?? []
        let scoped = all.first { $0.workspace_id == scope }
        // Under All Workspaces new work (and Changes / Files) goes to the open chat's workspace,
        // else the most recently used one (S21).
        let current = routeWorkspaceID(selected).flatMap { id in all.first { $0.workspace_id == id && $0.open } }
        let target = scoped.flatMap { $0.open ? $0 : nil } ?? current ?? mostRecentOpenWorkspace(all)
        let here = drawerFooterDestination(tab: tab, route: selected)
        VStack(spacing: 0) {
            HStack {
                VerdeWordmark(); Spacer()
                Button(action: close) { Image(systemName: permanent ? "sidebar.left" : "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel(permanent ? "Hide sidebar" : "Close workspace drawer")
                    .accessibilityIdentifier(permanent ? "sidebar-hide" : "drawer-close")
                    .keyboardShortcut(permanent ? KeyboardShortcut("\\", modifiers: .command) : nil)
            }.padding(.horizontal, 12)
            if !all.isEmpty { switcher(all, scoped: scoped) }
            HStack(spacing: 4) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(VerdeTheme.subtle)
                    TextField("Search", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                }.padding(.horizontal, 12).frame(minHeight: 40).background(VerdeTheme.alternate, in: Capsule())
                if !all.isEmpty {
                    Button { open(.newChat(target?.workspace_id)) } label: { Image(systemName: "square.and.pencil").frame(width: 44, height: 44).contentShape(Rectangle()) }
                        .accessibilityLabel("New chat")
                    if let target {
                        Button { open(.newTerminal(workspace: target.workspace_id, request: UUID())) } label: { Image(systemName: "terminal").frame(width: 44, height: 44).contentShape(Rectangle()) }
                            .accessibilityLabel("New terminal")
                    }
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
            if let target, search.isEmpty {
                // S27 (Android parity): under All Workspaces the chips say which workspace they open,
                // the open chat's (S21) or the most recent one.
                ExplorerLinks(onChanges: { open(.changes(target.workspace_id)) }, onFiles: { open(.files(target.workspace_id)) },
                              workspace: scoped == nil ? target.label : nil,
                              onCaption: { workspaceQuery = ""; closedExpanded = false; switching = true })
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            Rectangle().fill(VerdeTheme.border).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let scoped, !scoped.open {
                        Text("\(scoped.label) is closed.").font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.muted).padding(16)
                    }
                    let sections = drawerItems(all, scope: scope, hidden: browse.companionThreads)
                    // Active is global, so its rows always name their workspace.
                    rows("Active", sections.active, chip: true)
                    rows("Open", sections.open, chip: scope == nil)
                    if !search.isEmpty { row("Search all chat history", icon: "clock") { open(.history) } }
                    if all.isEmpty { Text("Pair with a host to see your workspaces.").font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.muted).padding(16) }
                }.padding(.horizontal, 8).padding(.bottom, 16)
            }
            Divider().overlay(VerdeTheme.border)
            if let dock {
                dock
                Divider().overlay(VerdeTheme.border)
            }
            if permanent && verticalSize == .compact {
                // A short window (a phone on its side) needs its height for the list.
                HStack(spacing: 0) {
                    footerIcon("Home", icon: "house", selected: here == .home) { root(.home) }
                    footerIcon("Workspaces", icon: "square.stack", selected: here == .workspaces) { root(.workspaces) }
                    footerIcon("Hosts", icon: "desktopcomputer", selected: here == .hosts) { root(.hosts) }
                    footerIcon("Settings", icon: "gearshape", selected: here == .settings, action: settings)
                }.padding(.horizontal, 8)
            } else {
                // S22: the same four destinations as Android, in the same order; the current one
                // stays marked inside a chat too (S27).
                HStack(spacing: 4) {
                    footerTab("Home", icon: "house", selected: here == .home) { root(.home) }
                    footerTab("Workspaces", icon: "square.stack", selected: here == .workspaces) { root(.workspaces) }
                    footerTab("Hosts", icon: "desktopcomputer", selected: here == .hosts) { root(.hosts) }
                        .accessibilityIdentifier("drawer-hosts")
                    footerTab("Settings", icon: "gearshape", selected: here == .settings, action: settings)
                }.padding(.horizontal, 8).padding(.vertical, 6)
            }
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
        .accessibilityElement(children: .contain).accessibilityAddTraits(permanent ? [] : .isModal)
    }

    /// Full-width scope trigger plus its context-menu popover (spec "Switcher popover").
    private func switcher(_ all: [Workspace], scoped: Workspace?) -> some View {
        Button { workspaceQuery = ""; closedExpanded = false; switching = true } label: {
            HStack(spacing: 10) {
                if let scoped { WorkspaceChip(workspace: scoped, size: 22) }
                else { Image(systemName: "square.grid.2x2").frame(width: 22, height: 22).foregroundStyle(VerdeTheme.muted) }
                Text(scoped?.label ?? "All Workspaces").font(VerdeTheme.ui(14, bold: true)).lineLimit(2)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.caption).foregroundStyle(VerdeTheme.subtle)
            }.padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 8)
        .accessibilityLabel("Workspace scope: " + (scoped?.label ?? "All Workspaces")).accessibilityIdentifier("workspace-switcher")
        .popover(isPresented: $switching, arrowEdge: .top) {
            switcherMenu(all, scoped: scoped).presentationCompactAdaptation(.popover)
        }
    }

    private func switcherMenu(_ all: [Workspace], scoped: Workspace?) -> some View {
        let canManage = manage?.view?.can_manage_workspaces == true
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(VerdeTheme.subtle)
                TextField("Search workspaces", text: $workspaceQuery).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("workspace-switcher-search")
            }.padding(12)
            Divider().overlay(VerdeTheme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if fuzzyMatches(workspaceQuery, "All Workspaces") {
                        menuRow(selected: scoped == nil, enabled: true, action: { scope = nil; switching = false }) {
                            Image(systemName: "square.grid.2x2").frame(width: 22, height: 22)
                            Text("All Workspaces")
                        }
                    }
                    let matching = switcherWorkspaces(all).filter { fuzzyMatches(workspaceQuery, $0.label) }
                    ForEach(matching.filter(\.open), id: \.workspace_id) { ws in
                        switcherRow(ws, scoped: scoped, canManage: canManage)
                    }
                    let closed = matching.filter { !$0.open }
                    if !closed.isEmpty {
                        let expanded = closedExpanded || !workspaceQuery.isEmpty
                        Button { closedExpanded.toggle() } label: {
                            HStack(spacing: 10) {
                                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption).frame(width: 22, height: 22)
                                Text("Closed Workspaces")
                                Spacer(minLength: 0)
                                Text("\(closed.count)").font(VerdeTheme.ui(11)).foregroundStyle(VerdeTheme.subtle)
                            }.padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(VerdeTheme.muted).disabled(!workspaceQuery.isEmpty)
                            .accessibilityIdentifier("workspace-switcher-closed").accessibilityValue(expanded ? "expanded" : "collapsed")
                        if expanded {
                            ForEach(closed, id: \.workspace_id) { ws in switcherRow(ws, scoped: scoped, canManage: canManage) }
                        }
                    }
                }
            }.frame(maxHeight: 360)
            Divider().overlay(VerdeTheme.border)
            menuRow(selected: false, enabled: true, action: { switching = false; open(.addWorkspace) }) {
                Image(systemName: "plus").frame(width: 22, height: 22)
                Text("New workspace")
            }
        }
        .font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.text)
        // I12-8: the system popover background and shadow set it apart from the sidebar.
        .frame(width: max(240, width - 24))
    }

    @ViewBuilder private func rows(_ name: String, _ items: [DrawerItem], chip: Bool) -> some View {
        let shown = items.filter { matches($0.title) || matches($0.workspace.label) }
        if !shown.isEmpty {
            section(name)
            ForEach(shown) { item in
                if let thread = item.thread { chat(thread, chip: chip ? item.workspace : nil) }
                else if let pane = item.pane, let id = pane.terminal_id {
                    terminal(pane, id: id, chip: chip ? item.workspace : nil)
                }
            }
        }
    }

    private func switcherRow(_ ws: Workspace, scoped: Workspace?, canManage: Bool) -> some View {
        HStack(spacing: 0) {
            // Closed rows reopen on select, which needs workspace management rights.
            menuRow(selected: scoped?.workspace_id == ws.workspace_id, enabled: ws.open || canManage, action: {
                if !ws.open, let manage { Task { _ = await manage.workspace("reopen", id: ws.workspace_id) } }
                scope = ws.workspace_id; switching = false
            }) {
                WorkspaceChip(workspace: ws, size: 22)
                Text(workspaceDisplayLabel(ws, among: browse.state.workspaces?.items ?? [])).lineLimit(1)
            }.opacity(ws.open ? 1 : 0.55)
            if ws.open {
                Button { switching = false; open(.workspace(ws.workspace_id)) } label: {
                    Image(systemName: "gearshape").frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(VerdeTheme.muted).accessibilityLabel("Settings for " + ws.label)
            }
        }
    }
    private func menuRow<Label: View>(selected: Bool, enabled: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                label()
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").font(.caption).foregroundStyle(VerdeTheme.accent) }
            }.padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func matches(_ value: String) -> Bool { search.isEmpty || value.localizedCaseInsensitiveContains(search) }
    // S32: sentence-case section headers everywhere ("Active", "Open").
    private func section(_ text: String) -> some View { Text(text).font(VerdeTheme.ui(12, bold: true)).foregroundStyle(VerdeTheme.subtle).padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4).accessibilityAddTraits(.isHeader) }
    private func row(_ title: String, icon: String, chip: Workspace? = nil, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let chip { WorkspaceChip(workspace: chip, size: chipSize) }
                Image(systemName: icon).frame(width: 18); Text(title).lineLimit(1); Spacer(minLength: 0)
            }
                .font(VerdeTheme.ui(13)).padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
                .background(selected ? VerdeTheme.accent.opacity(0.19) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    /// A labelled footer destination: icon over a short name, 48 points tall.
    private func footerTab(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                // A fixed icon box so every label sits on the same baseline (I7-5).
                Image(systemName: icon).font(.system(size: glyphSize * 0.9)).frame(width: glyphSize * 1.33, height: glyphSize * 1.1)
                // One size for all four labels (U1 iPad): capped, so "Workspaces" never shrinks alone.
                Text(title).font(VerdeTheme.ui(11, bold: selected)).lineLimit(1).minimumScaleFactor(0.8)
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            }
            .foregroundStyle(selected ? VerdeTheme.accent : VerdeTheme.text)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(selected ? VerdeTheme.accent.opacity(0.19) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func footerIcon(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                .background(selected ? VerdeTheme.accent.opacity(0.19) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func action(_ action: String, _ thread: ThreadSummary, title: String = "") {
        guard let manage, !manage.busy else { return }
        Task {
            let result = await manage.thread(action, workspace: thread.workspace_id, thread: thread.thread_id, title: title)
            notice = manage.notice
            if result != nil && action == "close" && selected == .thread(workspace: thread.workspace_id, thread: thread.thread_id) { root(.home) }
        }
    }
    /// Terminal row: an agent TUI shows its provider glyph and a live status pip, like the desktop/web rail.
    private func terminal(_ pane: Pane, id: String, chip: Workspace?) -> some View {
        let target = BrowseRoute.terminal(workspace: pane.workspace_id, terminal: id)
        return Button { open(target) } label: {
            HStack(spacing: 10) {
                if let chip { WorkspaceChip(workspace: chip, size: chipSize) }
                if let provider = pane.provider { ProviderGlyph(provider: provider, size: glyphSize) } else { Image(systemName: "terminal").font(.system(size: glyphSize * 0.8)).frame(width: glyphSize) }
                // I11-2: two lines before a title truncates (large text, narrow sidebar).
                Text(pane.title).lineLimit(2)
                Spacer(minLength: 0)
                if pane.status == "working" || pane.status == "waiting" {
                    StatusPip(active: pane.status == "working", attention: pane.status == "waiting")
                }
            }.font(VerdeTheme.ui(13)).padding(.horizontal, 12).padding(.vertical, 4).frame(minHeight: 44).contentShape(Rectangle())
                .background(selected == target ? VerdeTheme.accent.opacity(0.19) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityAddTraits(selected == target ? .isSelected : [])
    }
    private func chat(_ thread: ThreadSummary, chip: Workspace? = nil) -> some View {
        let target = BrowseRoute.thread(workspace: thread.workspace_id, thread: thread.thread_id)
        return Button { open(target) } label: {
            HStack(spacing: 10) {
                if let chip { WorkspaceChip(workspace: chip, size: chipSize) }
                ProviderGlyph(provider: thread.provider, size: glyphSize)
                Text(thread.title.isEmpty ? "New chat" : thread.title).lineLimit(2)
                Spacer(minLength: 0)
                GitThreadDot(browse: browse, workspace: thread.workspace_id, thread: thread.thread_id)
                // S32/S40: a dot only with state (the core's, C11), as on Android; never a grey idle dot.
                let state = coreChatState(thread.state)
                if state.isActive {
                    StatusPip(active: state == .running, attention: state == .needs_you, failed: state == .failed)
                }
            }.font(VerdeTheme.ui(13)).padding(.horizontal, 12).padding(.vertical, 4).frame(minHeight: 44).contentShape(Rectangle())
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
