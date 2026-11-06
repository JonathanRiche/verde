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
func uniqued<T: Hashable>(_ items: [T]) -> [T] {
    var seen = Set<T>()
    return items.filter { seen.insert($0).inserted }
}

func uniqued<T, K: Hashable>(_ items: [T], by key: (T) -> K) -> [T] {
    var seen = Set<K>()
    return items.filter { seen.insert(key($0)).inserted }
}

/// "demo-app · Working · 2 h ago": only the parts that exist, so no separator dangles.
func historySubtitle(_ thread: ThreadSummary, workspace: String?, now: Int64) -> String {
    [workspace, thread.status == "idle" || thread.status.isEmpty ? nil : statusLabel(thread.status),
     thread.archived ? "Archived" : nil, thread.last_activity_at_ms.map { agoLabel($0, now) }]
        .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
}

func historySections(_ items: [ThreadSummary]) -> [(String, [ThreadSummary])] {
    var sections: [(String, [ThreadSummary])] = []
    for item in items where !isSubagent(item) {
        if sections.last?.0 == item.history_bucket { sections[sections.count - 1].1.append(item) }
        else { sections.append((item.history_bucket, [item])) }
    }
    return sections
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
