import Foundation
import Observation

struct BrowseState {
    var hostID: String?
    var row: HostRow?
    var home: HomeView?
    var workspaces: WorkspacesView?
    /// Non-nil while the warm-start cache is shown instead of this session's live projection.
    var savedAtMs: Int64?
    var refreshing = false
    var networkAvailable = true
    var fatal = false
    var host: HostView? { row?.view }
    var hasData: Bool { home != nil || workspaces != nil }
}

/// Screen state for the selected host only. Projections come from that host's
/// core (`home` / `workspaces` queries); nothing is merged across hosts and the
/// daemon is never called directly.
@MainActor @Observable
final class BrowseModel {
    static let refreshTimeout: TimeInterval = 15

    let hosts: HostsModel
    private let cache: ViewCache?
    private let wallClock: () -> Int64
    private let saveInterval: TimeInterval
    private(set) var cached: CachedViews?
    private(set) var refreshing = false
    private var cachedFor: String?
    private var lastSave: Date?
    private var savedRevision: String?
    private var pendingSave: Task<Void, Never>?

    init(hosts: HostsModel, cache: ViewCache? = nil,
         wallClock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
         saveInterval: TimeInterval = 5) {
        self.hosts = hosts
        self.cache = cache
        self.wallClock = wallClock
        self.saveInterval = saveInterval
        hosts.onActiveChange = { [weak self] in self?.activeChanged() }
        hosts.onStoreChange = { [weak self] id in self?.storeChanged(id) }
        activeChanged()
    }

    var hostID: String? { hosts.active }
    var session: PairingModel? { hosts.session(hostID) }

    var state: BrowseState {
        let row = hostID.flatMap { hosts.row($0) }
        var state = BrowseState(hostID: hostID, row: row, refreshing: refreshing,
                                networkAvailable: hosts.networkState?.available ?? true)
        guard let store = session?.store else {
            state.fatal = hostID != nil && !hosts.loading
            return state
        }
        if let auth = row?.view?.auth_state, HostsModel.wiped.contains(auth) { return state }
        // The cache stays visible until this session's core has synced once; afterwards the
        // core's own (possibly stale) projection is always at least as new as the cache.
        if let cached, !store.synced {
            state.home = cached.home
            state.workspaces = cached.workspaces
            state.savedAtMs = cached.saved_at_ms
        } else {
            state.home = store.home?.data
            state.workspaces = store.workspaces?.data
        }
        return state
    }

    private func activeChanged() {
        pendingSave?.cancel()
        pendingSave = nil
        lastSave = nil
        savedRevision = nil
        cachedFor = hostID
        cached = nil
        guard let id = hostID, session?.store.synced != true else { return }
        cached = cache?.load(id)
    }

    private func storeChanged(_ id: String) {
        guard id == hostID, let store = session?.store else { return }
        if let auth = session?.row?.auth_state, HostsModel.wiped.contains(auth) {
            // HostsModel already cleared the file; drop the copy and any queued save.
            cached = nil
            pendingSave?.cancel()
            pendingSave = nil
            savedRevision = nil
            return
        }
        if store.synced { cached = nil }
        scheduleSave()
    }

    /// Throttled: at most one write per `saveInterval`, always of the newest projection.
    private func scheduleSave() {
        guard cache != nil, pendingSave == nil, let id = hostID else { return }
        let wait = lastSave.map { saveInterval - Date().timeIntervalSince($0) } ?? 0
        if wait <= 0 { save(id); return }
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.pendingSave = nil
            if self.hostID == id { self.save(id) }
        }
    }

    private func save(_ id: String) {
        guard let cache, let session = hosts.session(id), let view = session.row,
              view.auth_state == "paired", view.sync_state == "ready",
              var home = session.store.home?.data, var workspaces = session.store.workspaces?.data,
              let homeRevision = session.store.home?.revision,
              let workspacesRevision = session.store.workspaces?.revision else { return }
        let revision = homeRevision + "/" + workspacesRevision
        guard revision != savedRevision else { return }
        home.loading = false; home.stale = false; home.error = nil
        workspaces.loading = false; workspaces.stale = false; workspaces.error = nil
        workspaces.history.loading = false; workspaces.history.error = nil
        if cache.save(id, CachedViews(saved_at_ms: wallClock(), home: home, workspaces: workspaces)) {
            savedRevision = revision
            lastSave = Date()
        }
    }

    /// Pull-to-refresh / Retry: `retry_connection` skips any reconnect backoff and,
    /// when the connection is ready, re-reads the snapshot and thread catalog.
    func refresh() async {
        guard !refreshing, let session else { return }
        refreshing = true
        defer { refreshing = false }
        await session.start()
        guard let host = session.host else { return }
        do {
            try await host.send(.retry_connection(EventRetryConnection(now_ms: 0, wall_time_ms: 0,
                intent_id: UUID().uuidString)))
        } catch { return } // A rejection leaves state unchanged; a closed host already published its failure.
        let deadline = Date().addingTimeInterval(Self.refreshTimeout)
        while session.store.home?.data?.loading == true, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

// MARK: - Pure presentation rules (unit tested)

enum BannerAction { case retry, hosts }

struct Banner: Equatable {
    var text: String
    var action: BannerAction?
    var error = false
    var busy = false
}

func statusLabel(_ status: String) -> String {
    switch status {
    case "waiting_approval": return "Needs approval"
    case "waiting": return "Waiting"
    case "working", "running", "accepted": return "Working"
    case "idle": return "Idle"
    case "exited": return "Exited"
    case "unavailable": return "Unavailable"
    case "completed": return "Done"
    case "failed": return "Failed"
    case "aborted", "cancelled": return "Stopped"
    default: return capitalized(status)
    }
}

/// K-17 attention reason shown as a badge; nil when the core reports none.
func attentionLabel(_ kind: String?) -> String? {
    guard let kind else { return nil }
    switch kind {
    case "unread": return "Unread"
    case "needs_approval": return "Needs approval"
    case "blocked": return "Blocked"
    case "failed": return "Failed"
    default: return capitalized(kind)
    }
}

private func capitalized(_ value: String) -> String {
    let spaced = value.replacingOccurrences(of: "_", with: " ")
    return spaced.prefix(1).uppercased() + spaced.dropFirst()
}

func paneLabel(_ pane: Pane) -> String {
    pane.kind == "terminal" && pane.status == "working" ? "Running" : statusLabel(pane.status)
}

func elapsedLabel(_ startMs: Int64, _ nowMs: Int64) -> String {
    let total = max(0, nowMs - startMs) / 1000
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%ld:%02ld:%02ld", Int(h), Int(m), Int(s)) : String(format: "%ld:%02ld", Int(m), Int(s))
}

func agoLabel(_ thenMs: Int64, _ nowMs: Int64) -> String {
    let minutes = max(0, nowMs - thenMs) / 60_000
    if minutes < 1 { return "just now" }
    if minutes < 60 { return "\(minutes) min ago" }
    if minutes < 24 * 60 { return "\(minutes / 60) h ago" }
    return "\(minutes / (24 * 60)) d ago"
}

func paneLine(_ pane: Pane, _ nowMs: Int64) -> String {
    let kind = pane.kind == "terminal" ? "Terminal" : pane.kind == "browser" ? "Browser" : "Chat"
    let timer = pane.can_stop ? pane.started_at_ms.map { " · " + elapsedLabel($0, nowMs) } ?? "" : ""
    return "\(kind) · \(paneLabel(pane))\(timer)"
}

func isSubagent(_ thread: ThreadSummary) -> Bool { thread.thread_id.hasPrefix("subagent:") }

/// Most recent non-archived top-level chats from the core's history projection.
func recentThreads(_ workspaces: WorkspacesView?, limit: Int = 8) -> [ThreadSummary] {
    Array((workspaces?.history.items ?? []).filter { !$0.archived && !isSubagent($0) }.prefix(limit))
}

func workspaceThreads(_ workspace: Workspace) -> [ThreadSummary] {
    workspace.threads.filter { !isSubagent($0) }.sorted {
        let a = $0.last_activity_at_ms ?? 0, b = $1.last_activity_at_ms ?? 0
        return a != b ? a > b : $0.thread_id < $1.thread_id
    }
}

func openable(_ pane: Pane) -> Bool {
    switch pane.kind {
    case "chat": return pane.thread_id != nil
    case "terminal": return pane.terminal_id != nil
    default: return false
    }
}

/// Counts shown on a workspace row: "N chats · N terminals · N active · closed" plus a K-17 badge.
func workspaceSummary(_ workspace: Workspace) -> (summary: String, active: Int, badge: String?) {
    let chats = workspace.threads.filter { !isSubagent($0) && !$0.archived }.count
    let terminals = workspace.panes.filter { $0.kind == "terminal" && $0.terminal_id != nil }.count
    let active = workspace.panes.filter { $0.attention || $0.can_stop || $0.status == "working" }.count
    let flagged = workspace.panes.filter { $0.attention_kind != nil }.count
    var parts = ["\(chats) chat\(chats == 1 ? "" : "s")"]
    if terminals > 0 { parts.append("\(terminals) terminal\(terminals == 1 ? "" : "s")") }
    if active > 0 { parts.append("\(active) active") }
    if !workspace.open { parts.append("closed") }
    let badge = flagged > 0 ? "\(flagged) need\(flagged == 1 ? "s" : "") attention" : nil
    return (parts.joined(separator: " · "), active, badge)
}

/// Cached views, or a live projection backed by at least one snapshot.
func hasContent(_ state: BrowseState) -> Bool {
    state.hasData && (state.savedAtMs != nil || ["ready", "stale"].contains(state.host?.sync_state ?? ""))
}

func showSpinner(_ state: BrowseState) -> Bool {
    guard let host = state.host else { return !state.fatal }
    return state.networkAvailable && !state.fatal && state.row?.fatal != true && host.phase != "failed"
        && host.error == nil && host.trust_proposal == nil && !host.update_required
}

func needsPairing(_ state: BrowseState) -> Bool {
    ["unpaired", "signed_out", "signing_out"].contains(state.host?.auth_state ?? "")
}

func browseBanner(_ state: BrowseState, _ nowMs: Int64) -> Banner? {
    let saved = state.savedAtMs.map { " Showing saved data from \(agoLabel($0, nowMs))." } ?? ""
    if state.fatal || state.row?.fatal == true { return Banner(text: "Connection unavailable — reopen Verde.", error: true) }
    guard let host = state.host, host.auth_state != "loading" else {
        return state.savedAtMs != nil ? Banner(text: "Loading.\(saved)", busy: true) : nil
    }
    if needsPairing(state) { return nil }
    if host.auth_state == "repair_required" {
        return Banner(text: "Pair again — device authorization needs renewal.", action: .hosts, error: true)
    }
    if host.trust_proposal != nil { return Banner(text: "Review this host's identity before connecting.", action: .hosts, error: true) }
    if host.update_required { return Banner(text: "Update required — update Verde on this phone or host.", error: true) }
    if !state.networkAvailable { return Banner(text: "You're offline.\(saved)", error: true) }
    if host.phase == "failed" || host.error?.failure_kind == "network" {
        return Banner(text: "Can't reach \(host.label). Is Tailscale on?\(saved)", action: .retry, error: true)
    }
    if state.home?.error != nil || state.workspaces?.error != nil {
        return Banner(text: "Couldn't load the latest data. Pull down to retry.\(saved)", action: .retry, error: true)
    }
    if host.phase != "ready" { return Banner(text: "Connecting…\(saved)", busy: true) }
    if state.savedAtMs != nil { return Banner(text: "Updating…\(saved)", busy: true) }
    if state.home?.incomplete_scopes.isEmpty == false { return Banner(text: "Some host data is still loading.") }
    return nil
}
