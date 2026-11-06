import SwiftUI
import UIKit

enum BrowseRoute: Hashable {
    case workspace(String)
    case history
    case newChat(String?)
    case addWorkspace
    case thread(workspace: String, thread: String)
    case terminal(workspace: String, terminal: String)
    /// Each push is a distinct new session request.
    case newTerminal(workspace: String, request: UUID)
    /// Workspace explorer: uncommitted changes, the file tree, one changed file's diff (repository
    /// root and repo-relative path), and a Files-tab file (root id, root-relative path, and the
    /// informational absolute path, possibly empty).
    case changes(String)
    case files(String)
    case patch(workspace: String, root: String, path: String)
    case workspaceFile(workspace: String, root: String, path: String, absolute: String)
}

/// The workspace a screen belongs to, if any.
func routeWorkspaceID(_ route: BrowseRoute?) -> String? {
    switch route {
    case .workspace(let id)?, .changes(let id)?, .files(let id)?: return id
    case .thread(let workspace, _)?, .terminal(let workspace, _)?, .newTerminal(let workspace, _)?: return workspace
    case .patch(let workspace, _, _)?, .workspaceFile(let workspace, _, _, _)?: return workspace
    case .newChat(let id)?: return id
    default: return nil
    }
}

func route(_ pane: Pane) -> BrowseRoute? {
    guard openable(pane) else { return nil }
    if pane.kind == "terminal", let id = pane.terminal_id { return .terminal(workspace: pane.workspace_id, terminal: id) }
    if let id = pane.thread_id { return .thread(workspace: pane.workspace_id, thread: id) }
    return nil
}

private struct OpenRouteKey: EnvironmentKey {
    static let defaultValue: (BrowseRoute) -> Void = { _ in }
}
private struct ReplaceRouteKey: EnvironmentKey {
    static let defaultValue: (BrowseRoute) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Pushes onto the enclosing browse stack (context-menu "Open").
    var openRoute: (BrowseRoute) -> Void {
        get { self[OpenRouteKey.self] }
        set { self[OpenRouteKey.self] = newValue }
    }
    /// Replaces the current screen in the browse stack (an ended terminal's Relaunch, I14-3), so
    /// Back skips the screen it replaced.
    var replaceRoute: (BrowseRoute) -> Void {
        get { self[ReplaceRouteKey.self] }
        set { self[ReplaceRouteKey.self] = newValue }
    }
}

private func nowMs(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

/// How often "12 min ago" labels refresh when no timer is running (I2-4).
let relativeTimeRefresh: TimeInterval = 30

/// Ticks every second only while a running timer is visible, else every `relativeTimeRefresh`.
private struct Clock<Content: View>: View {
    let ticking: Bool
    @ViewBuilder let content: (Int64) -> Content
    var body: some View {
        TimelineView(.periodic(from: .now, by: ticking ? 1 : relativeTimeRefresh)) { context in content(nowMs(context.date)) }
    }
}

private struct Dot: View {
    let color: Color
    let label: String
    var body: some View {
        // S32: a dot only when there is state; an idle row keeps the space but draws nothing.
        let idle = label == "Idle"
        Circle().fill(idle ? Color.clear : color).frame(width: 6, height: 6)
            .modifier(Pulse(active: ["Working", "Running", "Active"].contains(label))).accessibilityLabel(label)
            .accessibilityHidden(idle)
    }
}

struct AttentionBadge: View {
    let text: String
    var body: some View {
        Text(text).font(VerdeTheme.ui(11, bold: true)).padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(VerdeTheme.text)
            .background(VerdeTheme.attentionBackground, in: Capsule())
            .background(VerdeTheme.panel, in: Capsule())
    }
}

/// How a row's state reads (S7): working is accent with a spinner, waiting / needs you amber,
/// failed the error colour; idle and done show no state at all.
enum RowState: Equatable {
    case working, attention, failed

    init?(status: String, attention: Bool = false) {
        if status == "failed" { self = .failed }
        else if attention || ["waiting_approval", "waiting", "blocked"].contains(status) { self = .attention }
        else if ["working", "running", "accepted"].contains(status) { self = .working }
        else { return nil }
    }

    var color: Color {
        switch self {
        case .working: return VerdeTheme.accent
        case .attention: return VerdeTheme.warning
        case .failed: return VerdeTheme.danger
        }
    }
}

/// "workspace · state · age" with only the parts that exist (no dangling separators).
func rowSubtitle(_ parts: [String?]) -> String? {
    let shown = parts.compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    return shown.isEmpty ? nil : shown.joined(separator: " · ")
}

private struct RowContent: View {
    let title: String
    let detail: String?
    let dot: Dot
    var provider: String?
    var badge: String?
    /// The state word inside `detail`, coloured; the spinner marks a working row.
    var state: RowState? = nil
    var stateText: String? = nil
    var unread = false
    /// Pass 16: the row's icon grows with its title at large text.
    @ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat = 20
    var body: some View {
        HStack(spacing: 12) {
            if let provider { ProviderGlyph(provider: provider, size: min(glyphSize, 40)) } else { dot }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(VerdeTheme.ui(16)).lineLimit(2)
                if let detail { subtitle(detail) }
            }
            Spacer(minLength: 4)
            if state == .working { ProgressView().controlSize(.mini).accessibilityHidden(true) }
            if unread {
                Circle().fill(VerdeTheme.muted).frame(width: 8, height: 8).accessibilityLabel("Unread")
            }
            if let badge { AttentionBadge(text: badge) }
        }
        .accessibilityElement(children: .combine)
    }

    private func subtitle(_ detail: String) -> some View {
        Text(styledSubtitle(detail)).font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.muted).lineLimit(2)
    }

    private func styledSubtitle(_ detail: String) -> AttributedString {
        var text = AttributedString(detail)
        if let state, let stateText, let range = text.range(of: stateText) {
            text[range].foregroundColor = state.color
        }
        return text
    }
}

/// Opens through the enclosing NavigationStack; the context menu offers Open and Copy.
private struct MenuRow: View {
    let content: RowContent
    let destination: BrowseRoute?
    let copies: [(String, String)]
    @Environment(\.openRoute) private var openRoute
    var body: some View {
        Group {
            if let destination { NavigationLink(value: destination) { content } } else { content }
        }
        .contextMenu {
            if let destination { Button { openRoute(destination) } label: { Label("Open", systemImage: "arrow.forward") } }
            ForEach(copies.indices, id: \.self) { index in
                // Copied text goes to the pasteboard only; it is never logged.
                Button { UIPasteboard.general.string = copies[index].1 } label: { Label(copies[index].0, systemImage: "doc.on.doc") }
            }
        }
    }
}

private struct PaneItem: View {
    let browse: BrowseModel
    let pane: Pane
    let now: Int64
    var body: some View {
        MenuRow(content: RowContent(title: pane.title, detail: paneLine(pane, now),
                                    dot: Dot(color: VerdeTheme.status(pane.status, attention: pane.needs_you), label: paneLabel(pane)),
                                    provider: pane.kind == "terminal" ? pane.provider : nil,
                                    badge: pane.attention_kind == "unread" ? nil : attentionLabel(pane.attention_kind),
                                    state: RowState(status: pane.status, attention: pane.needs_you), stateText: paneLabel(pane)),
                destination: route(pane), copies: [("Copy title", pane.title)])
            .overlay(alignment: .topTrailing) { if let thread = pane.thread_id { GitThreadDot(browse: browse, workspace: pane.workspace_id, thread: thread).padding(8) } }
    }
}

private struct ThreadItem: View {
    let browse: BrowseModel
    let thread: ThreadSummary
    let now: Int64
    var workspaceLabel: String?
    /// A finished chat not yet read: a neutral dot, never amber (S26).
    var unread = false
    var body: some View {
        let state = RowState(status: thread.status)
        let stateText = state == nil ? nil : statusLabel(thread.status)
        // A live state replaces the age: "Needs approval · 11 h ago" read as stale (I6-9).
        let age = state == nil ? thread.last_activity_at_ms.map { agoLabel($0, now) } : nil
        let detail = rowSubtitle([workspaceLabel, stateText, age])
        MenuRow(content: RowContent(title: thread.title, detail: detail,
                                    dot: Dot(color: VerdeTheme.status(thread.status, attention: thread.status == "waiting_approval"),
                                             label: statusLabel(thread.status)), provider: thread.provider,
                                    state: state, stateText: stateText, unread: unread),
                destination: .thread(workspace: thread.workspace_id, thread: thread.thread_id),
                copies: [("Copy title", thread.title)])
            .overlay(alignment: .topTrailing) { GitThreadDot(browse: browse, workspace: thread.workspace_id, thread: thread.thread_id).padding(8) }
    }
}

private struct WorkspaceItem: View {
    let workspace: Workspace
    /// Companion chats, left out of the counts.
    var hidden: Set<String> = []
    /// Every workspace, to tell same-named ones apart.
    var all: [Workspace] = []
    var body: some View {
        let info = workspaceSummary(workspace, hidden: hidden)
        MenuRow(content: RowContent(title: workspaceDisplayLabel(workspace, among: all),
                                    // S34: no raw path in the list; the workspace screen shows it.
                                    detail: info.summary.isEmpty ? nil : info.summary,
                                    dot: Dot(color: info.active > 0 ? VerdeTheme.accent : VerdeTheme.subtle, label: info.active > 0 ? "Active" : "Idle"),
                                    badge: info.badge),
                destination: .workspace(workspace.workspace_id), copies: [("Copy path", workspace.path)])
    }
}

func hostDotColor(_ row: HostRow) -> Color {
    let status = hostStatus(row)
    if status == "Connected" { return VerdeTheme.accent }
    if row.fatal || row.view?.auth_state == "repair_required" || status.hasPrefix("Unreachable") { return VerdeTheme.danger }
    return VerdeTheme.subtle
}

struct BrowseActions {
    var hosts: () -> Void
    var pair: () -> Void
}

/// Host status, banner and pull-to-refresh shared by the browse screens.
private struct BrowseFrame<Content: View>: View {
    let title: String
    let model: BrowseModel
    let actions: BrowseActions
    var ticking = false
    var large = true
    /// Home's "New chat" button already keeps the bottom band; it sits beside the bubble.
    var reservesBubble = true
    /// Home and Workspaces (the stack's root), as opposed to a pushed workspace screen.
    var isRoot = true
    @ViewBuilder let content: (BrowseState, Int64) -> Content
    @State private var addingHost = false

    @Environment(\.adaptive) private var adaptive
    var body: some View {
        let state = model.state
        Clock(ticking: ticking) { now in
            List {
                if large, let row = state.row {
                    let status = hostStatus(row)
                    HStack(spacing: 8) {
                        Dot(color: hostDotColor(row), label: status)
                        Text("\(row.saved.label) · \(status)") .font(VerdeTheme.ui(14))
                    }.listRowSeparator(.hidden)
                }
                if let banner = browseBanner(state, now) {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(banner.text).accessibilityIdentifier("browseBanner")
                            if banner.busy { ProgressView().progressViewStyle(.linear) }
                            switch banner.action {
                            case .some(.retry): Button("Retry") { Task { await model.refresh() } }.disabled(state.refreshing)
                            case .some(.hosts): Button("Open hosts", action: actions.hosts)
                            case nil: EmptyView()
                            }
                        }
                    }.listRowBackground(banner.error ? Color.red.opacity(0.12) : Color.secondary.opacity(0.12))
                }
                if gateOpen(state) {
                    content(state, now)
                } else {
                    Gate(state: state, pair: actions.pair)
                }
            }
            .refreshable { await model.refresh() }
            .modifier(BubbleReserve(enabled: reservesBubble))
            .modifier(ReadableListWidth())
        }
        .navigationTitle(title)
        .toolbar {
            // iPad: the sidebar already shows the wordmark; one logo per screen.
            if title == "Home" && !adaptive.slotVisible { ToolbarItem(placement: .principal) { VerdeWordmark() } }
            // I15-2: New chat is a compose button in the bar (Home and Workspaces), not a floating
            // pill; beside a visible sidebar its "+" already does this.
            // Workspaces keeps its own New chat row (Android's choice), so only Home has the button.
            if title == "Home" && !adaptive.slotVisible && gateOpen(model.state)
                && model.state.workspaces?.items.contains(where: \.open) == true {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: BrowseRoute.newChat(nil)) {
                        Image(systemName: "square.and.pencil").frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("New chat")
                    .accessibilityIdentifier("home-new-chat")
                }
            }
            ToolbarItem(placement: .topBarTrailing) { HostMenu(model: model.hosts) { addingHost = true } }
        }
        // Pushed screens (a workspace) already carry the avatar from the stack: one avatar per bar.
        .modifier(RootCompanionToolbar(enabled: isRoot))
        .modifier(AddHostAlert(model: model.hosts, isPresented: $addingHost))
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(VerdeTheme.background)
    }
}

private func gateOpen(_ state: BrowseState) -> Bool {
    state.hostID != nil && !needsPairing(state) && hasContent(state)
}

/// Shared host-level gates shown instead of screen content.
private struct Gate: View {
    let state: BrowseState
    let pair: () -> Void
    var body: some View {
        if state.hostID == nil {
            Text("No host selected.")
            Button("Choose a host", action: pair).modifier(PrimaryRow())
        } else if needsPairing(state) {
            Text("This phone isn't paired with \(state.row?.saved.label ?? "this host") yet.")
            Button("Pair with this host", action: pair).modifier(PrimaryRow()).accessibilityIdentifier("pairHost")
        } else if showSpinner(state) {
            HStack { Spacer(); ProgressView("Loading workspaces…"); Spacer() }.padding(.vertical, 24)
        } else {
            Text("No data yet. Pull down to retry when the host is reachable.")
        }
    }
}

struct HomeScreen: View {
    let model: BrowseModel
    let actions: BrowseActions
    @Environment(\.adaptive) private var adaptive
    var body: some View {
        let hidden = model.companionThreads
        let panes = visiblePanes(model.state.home?.items ?? [], hidden: hidden)
        BrowseFrame(title: "Home", model: model, actions: actions,
                    ticking: panes.contains { $0.can_stop && $0.started_at_ms != nil }) { state, now in
            // "Needs you" is the core's set (C8); unread completions stay with the rest.
            let attention = panes.filter(\.needs_you)
            // Only live turns and running processes are "Running" (I8-5); a finished, unread chat is not.
            let running = panes.filter { !$0.needs_you && (activeTurn($0.status) || $0.can_stop) }
            if !attention.isEmpty {
                TitledSection("Needs you") { ForEach(attention, id: \.id) { PaneItem(browse: model, pane: $0, now: now) } }
            }
            if !running.isEmpty {
                TitledSection("Running") { ForEach(running, id: \.id) { PaneItem(browse: model, pane: $0, now: now) } }
            }
            if attention.isEmpty && running.isEmpty { Section { Text("Nothing is running or waiting on you.") } }
            let workspaces = state.workspaces?.items ?? []
            let labels = Dictionary(workspaces.map { ($0.workspace_id, $0.label) }, uniquingKeysWith: { a, _ in a })
            // S26: "Needs you" / "Running" / "Recent"; wide windows keep five recents beside the sidebar.
            let recent = recentThreads(state.workspaces, limit: adaptive.tier.wide ? 5 : 8, hidden: hidden)
            let unread = Set(panes.filter { $0.attention_kind == "unread" }.compactMap(\.thread_id))
            if !recent.isEmpty {
                TitledSection("Recent") {
                    ForEach(recent, id: \.thread_id) {
                        ThreadItem(browse: model, thread: $0, now: now, workspaceLabel: labels[$0.workspace_id], unread: unread.contains($0.thread_id))
                    }
                }
            }
            let open = workspaces.filter(\.open)
            if !open.isEmpty {
                TitledSection("Workspaces") { ForEach(open, id: \.workspace_id) { WorkspaceItem(workspace: $0, hidden: hidden, all: workspaces) } }
            } else if state.workspaces != nil {
                Section { NavigationLink("Add a workspace", value: BrowseRoute.addWorkspace) }
            }
        }
    }
}

struct WorkspacesScreen: View {
    let model: BrowseModel
    let actions: BrowseActions
    var body: some View {
        let hidden = model.companionThreads
        BrowseFrame(title: "Workspaces", model: model, actions: actions) { state, _ in
            let all = dedupedWorkspaces(state.workspaces?.items ?? [])
            if all.isEmpty {
                NavigationLink("Add a workspace", value: BrowseRoute.addWorkspace)
            } else {
                Section {
                    NavigationLink(value: BrowseRoute.newChat(nil)) { Label("New chat", systemImage: "square.and.pencil") }
                    NavigationLink(value: BrowseRoute.history) { Label("History", systemImage: "clock") }
                    NavigationLink(value: BrowseRoute.addWorkspace) { Label("Add workspace", systemImage: "folder.badge.plus") }
                }
                TitledSection("Open") {
                    ForEach(all.filter(\.open), id: \.workspace_id) { WorkspaceItem(workspace: $0, hidden: hidden, all: all) } }
                let closed = all.filter { !$0.open }
                if !closed.isEmpty {
                    TitledSection("Closed") { ForEach(closed, id: \.workspace_id) { WorkspaceItem(workspace: $0, hidden: hidden, all: all) } }
                }
            }
        }
    }
}

struct WorkspaceScreen: View {
    let model: BrowseModel
    let workspaceID: String
    let actions: BrowseActions
    @State private var showArchived = false
    @Environment(\.openRoute) private var openRoute
    var body: some View {
        let workspace = model.state.workspaces?.items.first { $0.workspace_id == workspaceID }
        let hidden = model.companionThreads
        BrowseFrame(title: workspace?.label ?? "Workspace", model: model, actions: actions,
                    ticking: workspace?.panes.contains { $0.can_stop && $0.started_at_ms != nil } ?? false,
                    large: false, isRoot: false) { _, now in
            if let workspace {
                ManageContainer(browse: model) { manage in WorkspaceActions(workspace: workspace, manage: manage) }
                if !workspace.path.isEmpty { Text(workspace.path) .font(VerdeTheme.ui(13)).foregroundStyle(.secondary) }
                ExplorerLinks(onChanges: { openRoute(.changes(workspaceID)) }, onFiles: { openRoute(.files(workspaceID)) })
                TitledSection("Panes") {
                    let panes = visiblePanes(workspace.panes, hidden: hidden)
                    if panes.isEmpty { Text("No open panes.") }
                    ForEach(panes, id: \.id) { PaneItem(browse: model, pane: $0, now: now) }
                    if canWrite(model.state.host) && !workspace.path.isEmpty {
                        NavigationLink(value: BrowseRoute.newTerminal(workspace: workspaceID, request: UUID())) {
                            Label("New terminal", systemImage: "plus.rectangle.on.rectangle")
                        }
                    }
                }
                let threads = workspaceThreads(workspace, hidden: hidden).filter(listed)
                let current = threads.filter { !$0.archived }
                let archived = threads.filter(\.archived)
                TitledSection("Chats") {
                    if current.isEmpty { Text("No chats in this workspace yet.") }
                    ForEach(current, id: \.thread_id) { ThreadItem(browse: model, thread: $0, now: now) }
                    if !archived.isEmpty {
                        Button(showArchived ? "Hide archived (\(archived.count))" : "Show archived (\(archived.count))") {
                            showArchived.toggle()
                        }
                        if showArchived { ForEach(archived, id: \.thread_id) { ThreadItem(browse: model, thread: $0, now: now) } }
                    }
                }
            } else {
                Text("This workspace is no longer on the host.")
            }
        }
    }
}

/// A list section under a sentence-case `SectionTitle` (S7).
struct TitledSection<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View { Section { content } header: { SectionTitle(title) } }
}

private func isThreadRoute(_ route: BrowseRoute) -> Bool {
    if case .thread = route { return true }
    return false
}

private struct OptionalCompanionToolbar: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.modifier(CompanionToolbar()) } else { content }
    }
}

/// One tab's stack: every browse route resolves against the selected host only.
struct BrowseStack<Root: View>: View {
    let model: BrowseModel
    let actions: BrowseActions
    @Binding var path: [BrowseRoute]
    @ViewBuilder let root: () -> Root
    @Environment(\.adaptive) private var adaptive
    var body: some View {
        NavigationStack(path: $path) {
            root().modifier(VerdeNavigation()).minimalBackTitle().navigationDestination(for: BrowseRoute.self) { route in
                Group { switch route {
                case .history: ManageContainer(browse: model) { manage in HistoryScreen(browse: model, manage: manage) }
                case .newChat(let id): ManageContainer(browse: model) { manage in NewChatScreen(browse: model, manage: manage, initialWorkspace: id) }
                case .addWorkspace: ManageContainer(browse: model) { manage in AddWorkspaceScreen(manage: manage) }
                case .workspace(let id): WorkspaceScreen(model: model, workspaceID: id, actions: actions)
                case .thread(let workspace, let thread):
                    TranscriptScreen(browse: model, workspaceID: workspace, threadID: thread, onHosts: actions.hosts)
                case .terminal(let workspace, let terminal):
                    TerminalScreen(browse: model, workspaceID: workspace, terminalID: terminal)
                case .newTerminal(let workspace, _): TerminalScreen(browse: model, workspaceID: workspace, terminalID: nil)
                case .changes(let workspace): ChangesRoute(browse: model, workspaceID: workspace)
                case .files(let workspace): FilesRoute(browse: model, workspaceID: workspace)
                case .patch(let workspace, let root, let path): PatchRoute(browse: model, workspaceID: workspace, root: root, path: path)
                case .workspaceFile(let workspace, let root, let path, let absolute):
                    WorkspaceFileRoute(browse: model, workspaceID: workspace, root: root, path: path, absolute: absolute)
                } }
                // The chat screen places the companion itself, before its "⋯" menu.
                .modifier(OptionalCompanionToolbar(enabled: !isThreadRoute(route)))
                // The sidebar replaces the route in place; a different route is a different screen.
                .id(route)
                // I11-5: every pushed screen keeps its back button, beside a sidebar too; it is the
                // chevron alone everywhere, so it never reads "Home" on one screen and "Back" on another.
                .modifier(VerdeNavigation())
                .toolbarRole(.editor)
                .minimalBackTitle()
            }
        }
        .environment(\.openRoute, { route in path.append(route) })
        .environment(\.replaceRoute, { route in
            var next = path
            if !next.isEmpty { next.removeLast() }
            next.append(route)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { path = next }
        })
    }
}
