import SwiftUI
import UIKit

enum BrowseRoute: Hashable {
    case workspace(String)
    case thread(workspace: String, thread: String)
    case terminal(workspace: String, terminal: String)
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

private func statusColor(_ status: String, attention: Bool) -> Color {
    if attention || status == "waiting_approval" { return .red }
    if ["working", "running", "accepted", "waiting"].contains(status) { return .accentColor }
    return .secondary
}

private struct Dot: View {
    let color: Color
    let label: String
    var body: some View {
        Circle().fill(color).frame(width: 10, height: 10).accessibilityLabel(label)
    }
}

private struct AttentionBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.red.opacity(0.15), in: Capsule()).foregroundStyle(.red)
    }
}

private struct RowContent: View {
    let title: String
    let detail: String?
    let dot: Dot
    var badge: String?
    var body: some View {
        HStack(spacing: 12) {
            dot
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
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
    let pane: Pane
    let now: Int64
    var body: some View {
        MenuRow(content: RowContent(title: pane.title, detail: paneLine(pane, now),
                                    dot: Dot(color: statusColor(pane.status, attention: pane.attention), label: paneLabel(pane)),
                                    badge: attentionLabel(pane.attention_kind)),
                destination: route(pane), copies: [("Copy title", pane.title)])
    }
}

private struct ThreadItem: View {
    let thread: ThreadSummary
    let now: Int64
    var workspaceLabel: String?
    var body: some View {
        let parts = [workspaceLabel, thread.status == "idle" ? nil : statusLabel(thread.status),
                     thread.last_activity_at_ms.map { agoLabel($0, now) }].compactMap { $0 }
        MenuRow(content: RowContent(title: thread.title, detail: parts.isEmpty ? nil : parts.joined(separator: " · "),
                                    dot: Dot(color: statusColor(thread.status, attention: thread.status == "waiting_approval"),
                                             label: statusLabel(thread.status))),
                destination: .thread(workspace: thread.workspace_id, thread: thread.thread_id),
                copies: [("Copy title", thread.title)])
    }
}

private struct WorkspaceItem: View {
    let workspace: Workspace
    var body: some View {
        let info = workspaceSummary(workspace)
        MenuRow(content: RowContent(title: workspace.label,
                                    detail: [info.summary, workspace.path].filter { !$0.isEmpty }.joined(separator: "\n"),
                                    dot: Dot(color: info.active > 0 ? .accentColor : .secondary, label: info.active > 0 ? "Active" : "Idle"),
                                    badge: info.badge),
                destination: .workspace(workspace.workspace_id), copies: [("Copy path", workspace.path)])
    }
}

func hostDotColor(_ row: HostRow) -> Color {
    let status = hostStatus(row)
    if status == "Connected" { return .green }
    if row.fatal || row.view?.auth_state == "repair_required" || status.hasPrefix("Unreachable") { return .red }
    return .secondary
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
                        Text("\(row.saved.label) · \(status)").font(.subheadline)
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
        .navigationBarTitleDisplayMode(large ? .large : .inline)
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
                Section("Needs attention") { ForEach(attention, id: \.id) { PaneItem(pane: $0, now: now) } }
            }
            if !running.isEmpty {
                Section("Running") { ForEach(running, id: \.id) { PaneItem(pane: $0, now: now) } }
            }
            if panes.isEmpty { Section { Text("Nothing is running or waiting on you.") } }
            let workspaces = state.workspaces?.items ?? []
            let labels = Dictionary(workspaces.map { ($0.workspace_id, $0.label) }, uniquingKeysWith: { a, _ in a })
            let recent = recentThreads(state.workspaces)
            if !recent.isEmpty {
                Section("Recent chats") {
                    ForEach(recent, id: \.thread_id) { ThreadItem(thread: $0, now: now, workspaceLabel: labels[$0.workspace_id]) }
                }
            }
            let open = workspaces.filter(\.open)
            if !open.isEmpty {
                Section("Workspaces") { ForEach(open, id: \.workspace_id) { WorkspaceItem(workspace: $0) } }
            } else if state.workspaces != nil {
                Section { Text("No workspaces on this host yet. Add one from Verde on your computer.") }
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
                Text("No workspaces on this host yet. Add one from Verde on your computer.")
            } else {
                Section { ForEach(all.filter(\.open), id: \.workspace_id) { WorkspaceItem(workspace: $0) } }
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
                if !workspace.path.isEmpty { Text(workspace.path).font(.footnote).foregroundStyle(.secondary) }
                Section("Panes") {
                    if workspace.panes.isEmpty { Text("No open panes.") }
                    ForEach(workspace.panes, id: \.id) { PaneItem(pane: $0, now: now) }
                }
                let threads = workspaceThreads(workspace)
                let current = threads.filter { !$0.archived }
                let archived = threads.filter(\.archived)
                Section("Chats") {
                    if current.isEmpty { Text("No chats in this workspace yet.") }
                    ForEach(current, id: \.thread_id) { ThreadItem(thread: $0, now: now) }
                    if !archived.isEmpty {
                        Button(showArchived ? "Hide archived (\(archived.count))" : "Show archived (\(archived.count))") {
                            showArchived.toggle()
                        }
                        if showArchived { ForEach(archived, id: \.thread_id) { ThreadItem(thread: $0, now: now) } }
                    }
                }
            } else {
                Text("This workspace is no longer on the host.")
            }
        }
    }
}

/// D-06 replaces this with the transcript; it deliberately sends no focus/open intents yet.
struct ThreadPlaceholderScreen: View {
    let model: BrowseModel
    let workspaceID: String
    let threadID: String
    var body: some View {
        let state = model.state
        let workspace = state.workspaces?.items.first { $0.workspace_id == workspaceID }
        let thread = workspace?.threads.first { $0.thread_id == threadID }
        let pane = ((state.home?.items ?? []) + (workspace?.panes ?? []))
            .first { $0.workspace_id == workspaceID && $0.thread_id == threadID }
        Clock(ticking: pane?.can_stop == true && pane?.started_at_ms != nil) { now in
            List {
                if let workspace { Text(workspace.label).font(.headline) }
                if let thread {
                    Text([thread.provider, thread.model].compactMap { $0 }.joined(separator: " · "))
                    if let last = thread.last_activity_at_ms { Text("Last activity \(agoLabel(last, now))") }
                }
                Text(pane.map { paneLine($0, now) } ?? statusLabel(thread?.status ?? "idle"))
                if thread == nil && pane == nil { Text("This chat is no longer on the host.") }
                Text("The transcript view is coming in the next update. Open this chat in Verde on your computer for now.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(thread?.title ?? pane?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TerminalPlaceholderScreen: View {
    let model: BrowseModel
    let workspaceID: String
    let terminalID: String
    var body: some View {
        let state = model.state
        let workspace = state.workspaces?.items.first { $0.workspace_id == workspaceID }
        let pane = ((state.home?.items ?? []) + (workspace?.panes ?? []))
            .first { $0.workspace_id == workspaceID && $0.terminal_id == terminalID }
        List {
            if let workspace { Text(workspace.label).font(.headline) }
            Text(pane.map { paneLine($0, 0) } ?? "This terminal is no longer on the host.")
            Text("The terminal view is coming in a later update.").foregroundStyle(.secondary)
        }
        .navigationTitle(pane?.title ?? "Terminal")
        .navigationBarTitleDisplayMode(.inline)
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
            root().navigationDestination(for: BrowseRoute.self) { route in
                switch route {
                case .workspace(let id): WorkspaceScreen(model: model, workspaceID: id, actions: actions)
                case .thread(let workspace, let thread): ThreadPlaceholderScreen(model: model, workspaceID: workspace, threadID: thread)
                case .terminal(let workspace, let terminal): TerminalPlaceholderScreen(model: model, workspaceID: workspace, terminalID: terminal)
                }
            }
        }
        .environment(\.openRoute, { route in path.append(route) })
    }
}
