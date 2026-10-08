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

extension EnvironmentValues {
    /// Pushes onto the enclosing browse stack (context-menu "Open").
    var openRoute: (BrowseRoute) -> Void {
        get { self[OpenRouteKey.self] }
        set { self[OpenRouteKey.self] = newValue }
    }
}

private func nowMs(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

/// Ticks every second only while a running timer is visible.
private struct Clock<Content: View>: View {
    let ticking: Bool
    @ViewBuilder let content: (Int64) -> Content
    var body: some View {
        TimelineView(.periodic(from: .now, by: ticking ? 1 : 60)) { context in content(nowMs(context.date)) }
    }
}

private struct Dot: View {
    let color: Color
    let label: String
    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6).modifier(Pulse(active: ["Working", "Running", "Waiting", "Active"].contains(label))).accessibilityLabel(label)
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

private struct RowContent: View {
    let title: String
    let detail: String?
    let dot: Dot
    var provider: String?
    var badge: String?
    var body: some View {
        HStack(spacing: 12) {
            if let provider { ProviderGlyph(provider: provider) } else { dot }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                if let detail { Text(detail) .font(VerdeTheme.ui(14)).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 4)
            if let badge { AttentionBadge(text: badge) }
        }
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
                                    dot: Dot(color: VerdeTheme.status(pane.status, attention: pane.attention), label: paneLabel(pane)),
                                    provider: pane.kind == "terminal" ? pane.provider : nil,
                                    badge: attentionLabel(pane.attention_kind)),
                destination: route(pane), copies: [("Copy title", pane.title)])
            .overlay(alignment: .topTrailing) { if let thread = pane.thread_id { GitThreadDot(browse: browse, workspace: pane.workspace_id, thread: thread).padding(8) } }
    }
}

private struct ThreadItem: View {
    let browse: BrowseModel
    let thread: ThreadSummary
    let now: Int64
    var workspaceLabel: String?
    var body: some View {
        let parts = [workspaceLabel, thread.status == "idle" ? nil : statusLabel(thread.status),
                     thread.last_activity_at_ms.map { agoLabel($0, now) }].compactMap { $0 }
        MenuRow(content: RowContent(title: thread.title, detail: parts.isEmpty ? nil : parts.joined(separator: " · "),
                                    dot: Dot(color: VerdeTheme.status(thread.status, attention: thread.status == "waiting_approval"),
                                             label: statusLabel(thread.status)), provider: thread.provider),
                destination: .thread(workspace: thread.workspace_id, thread: thread.thread_id),
                copies: [("Copy title", thread.title)])
            .overlay(alignment: .topTrailing) { GitThreadDot(browse: browse, workspace: thread.workspace_id, thread: thread.thread_id).padding(8) }
    }
}

private struct WorkspaceItem: View {
    let workspace: Workspace
    var body: some View {
        let info = workspaceSummary(workspace)
        MenuRow(content: RowContent(title: workspace.label,
                                    detail: [info.summary, workspace.path].filter { !$0.isEmpty }.joined(separator: "\n"),
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
    @ViewBuilder let content: (BrowseState, Int64) -> Content

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
        }
        .navigationTitle(title)
        .toolbar { if title == "Home" { ToolbarItem(placement: .principal) { VerdeWordmark() } } }
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
            Button("Choose a host", action: pair)
        } else if needsPairing(state) {
            Text("This phone isn't paired with \(state.row?.saved.label ?? "this host") yet.")
            Button("Pair with this host", action: pair).accessibilityIdentifier("pairHost")
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
    var body: some View {
        let panes = model.state.home?.items ?? []
        BrowseFrame(title: "Home", model: model, actions: actions,
                    ticking: panes.contains { $0.can_stop && $0.started_at_ms != nil }) { state, now in
            let attention = panes.filter(\.attention)
            let running = panes.filter { !$0.attention }
            if !attention.isEmpty {
                Section("Needs attention") { ForEach(attention, id: \.id) { PaneItem(browse: model, pane: $0, now: now) } }
            }
            if !running.isEmpty {
                Section("Running") { ForEach(running, id: \.id) { PaneItem(browse: model, pane: $0, now: now) } }
            }
            if panes.isEmpty { Section { Text("Nothing is running or waiting on you.") } }
            let workspaces = state.workspaces?.items ?? []
            let labels = Dictionary(workspaces.map { ($0.workspace_id, $0.label) }, uniquingKeysWith: { a, _ in a })
            let recent = recentThreads(state.workspaces)
            if !recent.isEmpty {
                Section("Recent chats") {
                    ForEach(recent, id: \.thread_id) { ThreadItem(browse: model, thread: $0, now: now, workspaceLabel: labels[$0.workspace_id]) }
                }
            }
            let open = workspaces.filter(\.open)
            if !open.isEmpty {
                Section("Workspaces") { ForEach(open, id: \.workspace_id) { WorkspaceItem(workspace: $0) } }
            } else if state.workspaces != nil {
                Section { NavigationLink("Add a workspace", value: BrowseRoute.addWorkspace) }
            }
        }
        .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
            if gateOpen(model.state), model.state.workspaces?.items.contains(where: \.open) == true {
                NavigationLink(value: BrowseRoute.newChat(nil)) {
                    Text("New chat").font(VerdeTheme.ui(14, bold: true))
                        .padding(.horizontal, 24).frame(minHeight: 56)
                        .foregroundStyle(VerdeTheme.text)
                        .background(VerdeTheme.user, in: RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home-new-chat")
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
    }
}

struct WorkspacesScreen: View {
    let model: BrowseModel
    let actions: BrowseActions
    var body: some View {
        BrowseFrame(title: "Workspaces", model: model, actions: actions) { state, _ in
            let all = state.workspaces?.items ?? []
            if all.isEmpty {
                NavigationLink("Add a workspace", value: BrowseRoute.addWorkspace)
            } else {
                Section {
                    NavigationLink("Add workspace", value: BrowseRoute.addWorkspace)
                    NavigationLink("New chat", value: BrowseRoute.newChat(nil))
                    NavigationLink("History", value: BrowseRoute.history)
                    ForEach(all.filter(\.open), id: \.workspace_id) { WorkspaceItem(workspace: $0) } }
                let closed = all.filter { !$0.open }
                if !closed.isEmpty {
                    Section("Closed") { ForEach(closed, id: \.workspace_id) { WorkspaceItem(workspace: $0) } }
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
    var body: some View {
        let workspace = model.state.workspaces?.items.first { $0.workspace_id == workspaceID }
        BrowseFrame(title: workspace?.label ?? "Workspace", model: model, actions: actions,
                    ticking: workspace?.panes.contains { $0.can_stop && $0.started_at_ms != nil } ?? false,
                    large: false) { _, now in
            if let workspace {
                ManageContainer(browse: model) { manage in WorkspaceActions(workspace: workspace, manage: manage) }
                if !workspace.path.isEmpty { Text(workspace.path) .font(VerdeTheme.ui(13)).foregroundStyle(.secondary) }
                Section("Panes") {
                    if workspace.panes.isEmpty { Text("No open panes.") }
                    ForEach(workspace.panes, id: \.id) { PaneItem(browse: model, pane: $0, now: now) }
                    if canWrite(model.state.host) && !workspace.path.isEmpty {
                        NavigationLink(value: BrowseRoute.newTerminal(workspace: workspaceID, request: UUID())) {
                            Label("New terminal", systemImage: "plus.rectangle.on.rectangle")
                        }
                    }
                }
                let threads = workspaceThreads(workspace).filter(listed)
                let current = threads.filter { !$0.archived }
                let archived = threads.filter(\.archived)
                Section("Chats") {
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

/// One tab's stack: every browse route resolves against the selected host only.
struct BrowseStack<Root: View>: View {
    let model: BrowseModel
    let actions: BrowseActions
    @Binding var path: [BrowseRoute]
    @ViewBuilder let root: () -> Root
    var body: some View {
        NavigationStack(path: $path) {
            root().modifier(VerdeNavigation()).navigationDestination(for: BrowseRoute.self) { route in
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
                } }.modifier(VerdeNavigation())
            }
        }
        .environment(\.openRoute, { route in path.append(route) })
    }
}
