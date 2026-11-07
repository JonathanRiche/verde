import Foundation
import Observation

func manageMessage(_ job: ManageJob) -> String {
    if job.state == "uncertain" { return "The connection dropped before verde answered. Refresh to check before retrying." }
    if job.error?.code == "workspace_busy" {
        return "Stop \(job.busy?.pending_turns ?? 0) running requests and \(job.busy?.running_tasks ?? 0) background tasks first."
    }
    return job.error?.message.isEmpty == false ? job.error!.message : "The host couldn't complete this action."
}

/// Only optional provider discovery failures use the built-in catalog notice.
func newChatModelMessage(_ error: LocalError) -> String {
    if error.rpc_code == "provider_unavailable" {
        return "Live models are unavailable. You can start a chat with the built-in choices."
    }
    return error.message
}

/// A typed workspace folder as the core stores it: trimmed, without trailing slashes.
func normalizedWorkspacePath(_ raw: String) -> String {
    var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
    return path
}

/// Folder chrome uses the workspace's name or the final folder component; editing keeps the path.
func workspaceFolderName(_ raw: String, workspaces: [Workspace]) -> String {
    let path = normalizedWorkspacePath(raw)
    if let workspace = workspaces.first(where: { normalizedWorkspacePath($0.path) == path }), !workspace.label.isEmpty {
        return workspace.label
    }
    if path == "/" { return "Computer" }
    return path.split(separator: "/").last.map(String.init) ?? "Folders"
}

/// Why a typed folder can't become a workspace, before asking the host; nil when it may.
/// The core stores the path as given, so it has to be a clean absolute path.
func workspacePathProblem(_ raw: String) -> String? {
    let path = normalizedWorkspacePath(raw)
    if path.isEmpty { return nil }
    if path.hasPrefix("~") { return "Use the full path, for example /Users/you/project, not ~." }
    guard path.hasPrefix("/") else { return "Use the folder's full path, starting with /." }
    if path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) { return "The path can't contain line breaks or tabs." }
    if path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) { return "Use the folder's full path without . or .. parts." }
    return nil
}

/// The host's answer when a folder can't be listed, worded for adding a workspace.
func workspaceFolderMessage(_ error: LocalError?) -> String {
    switch error?.code {
    case "not_found": return "That folder doesn't exist on the computer. Check the path or pick it under Browse folders."
    case "path_outside_roots": return "verde can't open that folder on the computer."
    default: return error?.message.isEmpty == false ? error!.message : "The computer couldn't open that folder."
    }
}

/// Drops repeated values, keeping the first of each (host lists can repeat a folder).
/// Add-workspace suggestions worth offering (I7-6, Android parity): folders tied to an open
/// workspace (the folder, a parent or one inside it) stay; folders known only from closed
/// workspaces go, since the host can't vouch they still exist. One row per folder.
func freshFolderSuggestions(_ suggestions: [String], workspaces: [Workspace]) -> [String] {
    func norm(_ p: String) -> String { var s = Substring(p); while s.hasSuffix("/") && s.count > 1 { s = s.dropLast() }; return String(s) }
    func related(_ a: String, _ b: String) -> Bool {
        let x = norm(a), y = norm(b)
        return x == y || x.hasPrefix(y + "/") || y.hasPrefix(x + "/")
    }
    let open = workspaces.filter { $0.open && !$0.path.isEmpty }.map(\.path)
    let closed = workspaces.filter { !$0.open && !$0.path.isEmpty }.map(\.path)
    let kept = suggestions.filter { s in open.contains { related(s, $0) } || !closed.contains { related(s, $0) } }
    return uniqued(kept, by: norm)
}

func uniqued<T: Hashable>(_ items: [T]) -> [T] {
    var seen = Set<T>()
    return items.filter { seen.insert($0).inserted }
}

func uniqued<T, K: Hashable>(_ items: [T], by key: (T) -> K) -> [T] {
    var seen = Set<K>()
    return items.filter { seen.insert(key($0)).inserted }
}

/// The live catalog's last activity per chat (the core moves it after mobile turns, C7).
func liveActivity(_ workspaces: WorkspacesView?) -> [String: Int64] {
    var out: [String: Int64] = [:]
    for workspace in workspaces?.items ?? [] {
        for thread in workspace.threads { if let ms = thread.last_activity_at_ms { out[thread.thread_id] = ms } }
    }
    return out
}

/// A History row with the newer of its paged and live activity times, so Home and History agree (I7-7).
func withLiveActivity(_ thread: ThreadSummary, _ live: [String: Int64]) -> ThreadSummary {
    guard let ms = live[thread.thread_id], ms > (thread.last_activity_at_ms ?? 0) else { return thread }
    var copy = thread
    copy.last_activity_at_ms = ms
    return copy
}

/// "demo-app · Working · 2 h ago": only the parts that exist, so no separator dangles.
func historySubtitle(_ thread: ThreadSummary, workspace: String?, now: Int64) -> String {
    // S39: the core's state (C11) names what the chat is doing; idle and unread say nothing.
    [workspace, coreChatState(thread.state).label(status: thread.status),
     thread.archived ? "Archived" : nil, thread.last_activity_at_ms.map { agoLabel($0, now) }]
        .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
}

/// B2: a row's History section from its own activity time, the same rule as the core's buckets
/// (under a day "Today", under a week "This week", else "Older"), so a 10-minute-old chat is under
/// Today whether or not the list is filtered. An undated row keeps the core's bucket.
func historyBucket(_ thread: ThreadSummary, now: Int64) -> String {
    guard let at = thread.last_activity_at_ms else { return thread.history_bucket.isEmpty ? "Older" : thread.history_bucket }
    let age = max(0, now - at)
    return age < 86_400_000 ? "Today" : age < 604_800_000 ? "This week" : "Older"
}

func historySections(_ items: [ThreadSummary], now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> [(String, [ThreadSummary])] {
    let order = ["Today", "This week", "Older"]
    var grouped: [String: [ThreadSummary]] = [:]
    var extra: [String] = []
    for item in items where !isSubagent(item) {
        let bucket = historyBucket(item, now: now)
        if grouped[bucket] == nil && !order.contains(bucket) { extra.append(bucket) }
        grouped[bucket, default: []].append(item)
    }
    // I10-5: newest activity first inside each section (undated last, ties keep the host's order).
    return (order + extra).compactMap { bucket in
        guard let rows = grouped[bucket], !rows.isEmpty else { return nil }
        return (bucket, rows.enumerated().sorted {
            let (l, r) = ($0.element.last_activity_at_ms ?? .min, $1.element.last_activity_at_ms ?? .min)
            return l != r ? l > r : $0.offset < $1.offset
        }.map(\.element))
    }
}

/// Management projections and intents stay in the core. Pending mutations are never replayed.
@MainActor @Observable
final class ManageModel {
    let browse: BrowseModel
    private(set) var view: ManageView?
    private(set) var busy = false
    var notice: String?
    private var host: CoreHost?
    private var hostID: String?
    private var observing = false

    init(browse: BrowseModel) { self.browse = browse }

    func start() async {
        let id = browse.hostID
        guard let session = browse.hosts.session(id) else { notice = "Choose a paired host first."; return }
        hostID = id
        await session.start()
        guard browse.hostID == id else { return }
        host = session.host
        await refresh()
        if !observing { observing = true; track() }
    }

    private func track() {
        withObservationTracking {
            _ = browse.hostID
            _ = browse.hosts.session(hostID)?.store.snapshots["manage"]
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.browse.hostID != self.hostID { self.view = nil; self.host = nil; self.observing = false; return }
                await self.refresh()
                self.track()
            }
        }
    }

    func refresh() async {
        guard let host, let data = try? await host.query("manage"), browse.hostID == hostID else { return }
        view = try? JSONDecoder().decode(ManageQuery.self, from: data).data
    }

    /// Wait only for a mutation's durable management job; searches publish through browse.
    @discardableResult
    func run(_ event: (String) -> Event, mutation: Bool = false) async -> ManageJob? {
        guard !busy, let host, hostID == browse.hostID else { return nil }
        busy = true; notice = nil
        defer { busy = false }
        let id = UUID().uuidString
        do {
            try await host.send(event(id))
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            repeat {
                await refresh()
                guard hostID == browse.hostID else { return nil }
                if let job = view?.operations.first(where: { $0.intent_id == id }), job.state != "pending" {
                    if job.state != "succeeded" { notice = manageMessage(job); return nil }
                    return job
                }
                let data = try await host.query("operations")
                let op = try JSONDecoder().decode(OperationsQuery.self, from: data).data?.items.first { $0.intent_id == id }
                if op?.state == "failed" { notice = op?.error?.message ?? "The host refused this action."; return nil }
                if !mutation { return nil }
                try await Task.sleep(for: .milliseconds(100))
            } while ContinuousClock.now < deadline && !Task.isCancelled
            notice = "Still waiting for the host. Refresh to check before retrying."
        } catch { notice = "The host is unavailable. Refresh before retrying." }
        return nil
    }

    func select(_ workspace: String, _ selection: ChatSelection = ChatSelection()) async {
        await run { id in .new_chat_select(EventNewChatSelect(now_ms: 0, wall_time_ms: 0, intent_id: id, workspace_id: workspace, provider: selection.provider, model: selection.model, effort: selection.effort, access: selection.access, speed: selection.speed)) }
    }
    func createThread(_ workspace: String) async -> ManageJob? {
        guard let chat = view?.new_chat, chat.workspace_id == workspace, chat.can_create else { return nil }
        let s = chat.selection
        return await run({ id in .thread_create(EventThreadCreate(now_ms: 0, wall_time_ms: 0, intent_id: id, workspace_id: workspace, provider: s.provider ?? "codex", model: s.model, effort: s.effort, access: s.access, speed: s.speed)) }, mutation: true)
    }
    func directory(_ path: String? = nil) async {
        await run { id in .directory_list(EventDirectoryList(now_ms: 0, wall_time_ms: 0, intent_id: id, path: path)) }
    }
    func history(_ text: String, workspace: String?) async {
        await run { id in .history_search(EventHistorySearch(now_ms: 0, wall_time_ms: 0, intent_id: id, query: text.trimmingCharacters(in: .whitespacesAndNewlines), workspace_id: workspace)) }
    }
    func moreHistory() async {
        await run { id in .history_load_more(EventHistoryLoadMore(now_ms: 0, wall_time_ms: 0, intent_id: id)) }
    }
    func workspace(_ action: String, id workspace: String, value: String = "") async -> ManageJob? {
        await run({ id in
            switch action {
            case "rename": return .workspace_rename(EventWorkspaceRename(now_ms: 0, wall_time_ms: 0, intent_id: id, workspace_id: workspace, label: value.trimmingCharacters(in: .whitespacesAndNewlines)))
            case "close": return .workspace_close(EventWorkspaceClose(now_ms: 0, wall_time_ms: 0, intent_id: id, workspace_id: workspace))
            default: return .workspace_archive(EventWorkspaceArchive(now_ms: 0, wall_time_ms: 0, intent_id: id, workspace_id: workspace, archived: action == "archive"))
            }
        }, mutation: true)
    }
    /// Pins the icon (0..15) and color (0..7); nil returns that slot to automatic.
    func identity(_ workspace: String, icon: Int?, color: Int?) async -> ManageJob? {
        await run({ id in .workspace_identity(EventWorkspaceIdentity(now_ms: 0, wall_time_ms: 0, intent_id: id, workspace_id: workspace,
            icon_index: icon.map { UInt8($0) }, color_index: color.map { UInt8($0) })) }, mutation: true)
    }
    /// Adds a workspace only once the host has listed its folder. The core writes the path into
    /// the host's store as given, so a typo or a missing folder would otherwise become a workspace.
    func createWorkspace(path raw: String, label rawLabel: String) async -> ManageJob? {
        let path = normalizedWorkspacePath(raw)
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = workspacePathProblem(path) { notice = problem; return nil }
        guard !path.isEmpty else { notice = "Enter a folder path."; return nil }
        if let problem = await folderProblem(path) { notice = problem; return nil }
        return await run({ id in .workspace_create(EventWorkspaceCreate(now_ms: 0, wall_time_ms: 0, intent_id: id, path: path, label: label.isEmpty ? nil : label)) }, mutation: true)
    }

    /// Lists `path` on the host and waits for the answer: nil when it opens (or the host can't
    /// browse folders, so only it can judge), else the reason to show.
    func folderProblem(_ path: String) async -> String? {
        guard !busy, let host, hostID == browse.hostID, view?.directory.supported == true else { return nil }
        busy = true; notice = nil
        defer { busy = false }
        let id = UUID().uuidString
        do {
            try await host.send(.directory_list(EventDirectoryList(now_ms: 0, wall_time_ms: 0, intent_id: id, path: path)))
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while ContinuousClock.now < deadline && !Task.isCancelled {
                let data = try await host.query("operations")
                if let op = try JSONDecoder().decode(OperationsQuery.self, from: data).data?.items.first(where: { $0.intent_id == id }), op.state != "pending" {
                    await refresh()
                    if op.state == "failed" { return workspaceFolderMessage(view?.directory.error ?? op.error) }
                    return nil
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            return "The computer didn't answer in time. Try again."
        } catch { return "The host is unavailable. Refresh before retrying." }
    }
    func thread(_ action: String, workspace: String, thread: String, title: String = "") async -> ManageJob? {
        await run({ id in
            switch action {
            case "rename": return .thread_rename(EventThreadRename(now_ms: 0, wall_time_ms: 0, intent_id: id, workspace_id: workspace, thread_id: thread, title: title.trimmingCharacters(in: .whitespacesAndNewlines)))
            case "sync": return .thread_sync(EventThreadSync(now_ms: 0, wall_time_ms: 0, intent_id: id, workspace_id: workspace, thread_id: thread))
            default: return .thread_close(EventThreadClose(now_ms: 0, wall_time_ms: 0, intent_id: id, workspace_id: workspace, thread_id: thread))
            }
        }, mutation: true)
    }
}
