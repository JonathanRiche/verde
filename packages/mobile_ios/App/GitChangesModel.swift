import Foundation
import Observation

struct GitFileKey: Hashable { let root: String; let path: String }

/// Presentation only: routing, authorization, retained retries and RPCs belong to the core.
@MainActor @Observable
final class GitChangesModel {
    let workspace: String
    let thread: String
    private let sendEvent: (Event) async throws -> Void
    private let query: (String) async throws -> Data
    private(set) var view: GitReviewView?
    private(set) var status: GitStatusView?
    private(set) var summary: GitSummary?
    var sheet = false
    var confirmMain = false
    var choosePush = false
    var expanded: Set<GitFileKey> = []
    private var generatedSelection: Data?
    private var generatingSelection: (id: String, key: Data)?
    var message = "" { didSet { if message != oldValue { commitAfterMessage = nil } } }
    var notice: String?
    var selected: Set<GitFileKey> = []
    var hunks: [GitFileKey: Set<UInt32>] = [:]
    private var commitAfterMessage: (review: String, selection: Data, push: Bool, branch: Bool)?
    private var loadedID: String?
    private var quick = false
    private var wantsPush = false
    private var submitting = false
    private var reportedCommit: String?
    private var reportedPush: String?
    private var generating = false
    private var pending: [String: Bool] = [:]
    private var routeReady = false
    private var routeConnected = false

    init(workspace: String, thread: String,
         send: @escaping (Event) async throws -> Void, query: @escaping (String) async throws -> Data) {
        self.workspace = workspace; self.thread = thread; self.sendEvent = send; self.query = query
    }
    convenience init(browse: BrowseModel, workspace: String, thread: String) {
        let hostID = browse.hostID
        self.init(workspace: workspace, thread: thread, send: { event in
            guard browse.hostID == hostID, let session = browse.session else { throw CoreBridgeError.closed }
            await session.start(); guard let host = session.host else { throw CoreBridgeError.closed }; try await host.send(event)
        }, query: { selector in
            guard browse.hostID == hostID, let host = browse.session?.host else { throw CoreBridgeError.closed }
            return try await host.query(selector)
        })
    }
    var change: GitThreadSummary? { summary?.threads.first { $0.local_thread_id == thread } }
    var review: GitReviewResult? {
        guard view?.review?.workspace_id == workspace, view?.review?.local_thread_id == thread else { return nil }
        return view?.review
    }
    var repos: [GitRepoStatus] {
        guard status?.status?.workspace_id == workspace, status?.status?.local_thread_id == thread else { return [] }
        return status?.status?.repos ?? []
    }
    var ahead: UInt32 { repos.filter { $0.has_remote }.reduce(0) { $0 + $1.ahead } }
    var canCommit: Bool { view?.can_commit == true || status?.can_commit == true }
    var busy: Bool { submitting || pending.values.contains(true) || view?.mutation_state == "pending" }
    var generated: String { generatedSelection == selectionKey ? (view?.message?.message ?? "") : "" }
    var finalMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? generated : message }
    var mainBranch: String? {
        review?.repos.first { $0.is_default_branch || ["main", "master"].contains($0.branch ?? "") }?.branch
    }
    var selections: [GitRepoSelection] {
        (review?.repos ?? []).compactMap { repo in
            let files = repo.files.compactMap { file -> GitFileSelection? in
                let key = GitFileKey(root: repo.root, path: file.path)
                guard selected.contains(key) else { return nil }
                return GitFileSelection(path: file.path, hunks: hunks[key].map { $0.sorted() })
            }
            return files.isEmpty ? nil : GitRepoSelection(root: repo.root, files: files)
        }
    }
    var count: Int { selections.reduce(0) { $0 + $1.files.count } }
    var totals: (Int, Int) {
        var added = 0; var removed = 0
        for repo in review?.repos ?? [] { for file in repo.files {
            let key = GitFileKey(root: repo.root, path: file.path)
            guard selected.contains(key) else { continue }
            if let indices = hunks[key] {
                for hunk in file.hunks where indices.contains(hunk.index) {
                    for line in hunk.text.split(separator: "\n") {
                        if line.hasPrefix("+") { added += 1 }
                        if line.hasPrefix("-") { removed += 1 }
                    }
                }
            } else { added += Int(file.additions); removed += Int(file.deletions) }
        } }
        return (added, removed)
    }
    private var selectionKey: Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(selections)) ?? Data()
    }
    var usesGeneratedMessage: Bool { message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var allDiffsShown: Bool {
        let keys = (review?.repos ?? []).flatMap { repo in repo.files.map { GitFileKey(root: repo.root, path: $0.path) } }
        return !keys.isEmpty && keys.allSatisfy { expanded.contains($0) }
    }
    func toggleFile(_ key: GitFileKey) {
        guard canCommit, !busy else { return }
        commitAfterMessage = nil
        if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
        hunks[key] = nil
    }
    func toggleHunk(_ key: GitFileKey, file: GitReviewFile, index: UInt32, on: Bool) {
        guard canCommit, !busy, file.hunk_selectable, !file.binary, !file.preview_truncated else { return }
        commitAfterMessage = nil
        var indices = selected.contains(key) ? (hunks[key] ?? Set(file.hunks.map(\.index))) : []
        if on { indices.insert(index) } else { indices.remove(index) }
        if indices.isEmpty { selected.remove(key); hunks[key] = nil }
        else { selected.insert(key); hunks[key] = indices.count == file.hunks.count ? nil : indices }
    }
    func toggleDiffs() async {
        if allDiffsShown {
            expanded = []
            if usesGeneratedMessage && generatedSelection != selectionKey { await generate() }
        } else {
            expanded = Set((review?.repos ?? []).flatMap { repo in repo.files.map { GitFileKey(root: repo.root, path: $0.path) } })
        }
    }
    var canSubmit: Bool { canCommit && !busy && view?.state == "loaded" && view?.loading != true && count > 0 && view?.message_state != "loading" && !generating }
    var defaultPush: Bool { (view?.config?.commit_default_action ?? "commit") == "commit_and_push" }
    var label: String {
        if (change?.files ?? 0) == 0 && ahead > 0 { return "↑\(ahead) Push" }
        return defaultPush ? "Commit & push" : "Commit"
    }
    func start() async {
        await dispatch(.git_summary_refresh(EventGitSummaryRefresh(now_ms: 0, wall_time_ms: 0, intent_id: UUID().uuidString, workspace_id: workspace)))
        await dispatch(.git_status_refresh(EventGitStatusRefresh(now_ms: 0, wall_time_ms: 0, intent_id: UUID().uuidString, workspace_id: workspace, thread_id: thread)))
        await refresh()
    }
    func refresh() async {
        do {
            let next = try JSONDecoder().decode(GitReviewQuery.self, from: await query("git_review")).data
            status = try JSONDecoder().decode(GitStatusQuery.self, from: await query("git_status")).data
            summary = try JSONDecoder().decode(GitSummaryQuery.self, from: await query("git_summary:" + workspace)).data
            await receive(next)
            await receipts()
            await advanceQuickAction()
            await finishGeneratedCommit()
        } catch { notice = "Connect to the host to review changes." }
    }
    func receive(_ next: GitReviewView?) async {
        view = next
        if let error = next?.error { notice = error.message }
        if let result = next?.result, result.workspace_id == workspace, result.local_thread_id == thread {
            let identity = result.repos.map(\.commit).joined(separator: ",")
            if !identity.isEmpty && reportedCommit != identity {
                reportedCommit = identity
                let entries = result.repos.map { $0.short_commit + ($0.push == "pushed" ? " · pushed" : "") }.joined(separator: ", ")
                notice = "Committed \(result.files) files · \(entries)"
                sheet = false; confirmMain = false; quick = false
            }
        }
        if let result = next?.pull_push_result {
            let key = result.root + ":" + result.push
            if reportedPush != key { reportedPush = key; notice = result.push == "pushed" ? "Pushed to remote" : result.push == "rejected" ? "Push rejected. Pull & push to reconcile remote changes." : "Push failed. Check the remote on your computer." }
        }
        guard let review, next?.state == "loaded", next?.loading != true else { return }
        if review.review_id != loadedID {
            loadedID = review.review_id
            message = ""; hunks = [:]; selected = []; expanded = []; generatedSelection = nil
            for repo in review.repos { for file in repo.files where file.ownership == "mine" { selected.insert(GitFileKey(root: repo.root, path: file.path)) } }
            if quick && (review.turn_running || review.repos.contains { $0.branch == nil || $0.files.contains { $0.ownership != "mine" } }) { quick = false; sheet = true }
            if !selections.isEmpty { await generate() }
            else if quick { quick = false; sheet = true; notice = "No selected changes to commit." }
        }
        await advanceQuickAction()
    }
    private func advanceQuickAction() async {
        if quick, view?.message_state == "ready", generatedSelection == selectionKey, !generated.isEmpty, canSubmit {
            quick = false
            if mainBranch != nil { confirmMain = true } else { await commit(push: true) }
        }
    }
    func begin(push: Bool, quick: Bool = false) async {
        wantsPush = push; self.quick = quick; sheet = !quick; notice = nil; loadedID = nil
        await dispatch(.git_review_open(EventGitReviewOpen(now_ms: 0, wall_time_ms: 0, intent_id: UUID().uuidString, workspace_id: workspace, thread_id: thread)))
        await refresh()
    }
    func generate() async {
        guard let review, !generating, generatingSelection == nil, !selections.isEmpty, view?.message_state != "loading" else { return }
        generating = true; defer { generating = false }
        let id = UUID().uuidString
        generatedSelection = nil
        generatingSelection = (id, selectionKey)
        await dispatch(.git_message_generate(EventGitMessageGenerate(now_ms: 0, wall_time_ms: 0, intent_id: id, review_id: review.review_id, selections: selections)))
    }
    func commit(push: Bool? = nil, newBranch: Bool = false) async {
        guard let review, canSubmit else { return }
        if usesGeneratedMessage && (generatedSelection != selectionKey || generated.isEmpty) {
            commitAfterMessage = (review.review_id, selectionKey, push ?? wantsPush, newBranch)
            notice = "Generating a message for the selected changes…"
            await generate()
            await finishGeneratedCommit()
            return
        }
        submitting = true; defer { submitting = false }
        confirmMain = false
        await dispatch(.git_commit(EventGitCommit(now_ms: 0, wall_time_ms: 0, intent_id: UUID().uuidString, review_id: review.review_id, message: finalMessage, selections: selections, push: push ?? wantsPush, new_branch: newBranch, branch_name: newBranch ? view?.message?.branch : nil)))
        await refresh()
    }
    func dismissSheet() { sheet = false; quick = false; commitAfterMessage = nil }
    private func finishGeneratedCommit() async {
        guard let action = commitAfterMessage, generatingSelection == nil, !generating else { return }
        commitAfterMessage = nil
        guard review?.review_id == action.review, selectionKey == action.selection else { return }
        guard !generated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sheet = true; notice = "Enter a commit message or try generating one again."; return
        }
        await commit(push: action.push, newBranch: action.branch)
    }
    func push(root: String? = nil) async {
        guard canCommit, !busy else { return }
        let candidates = repos.filter { $0.has_remote && $0.ahead > 0 }
        if root == nil && candidates.count > 1 { choosePush = true; return }
        guard let repo = candidates.first(where: { root == nil || $0.root == root }) else { return }
        submitting = true; defer { submitting = false }
        reportedPush = nil
        await dispatch(.git_push(EventGitPush(now_ms: 0, wall_time_ms: 0, intent_id: UUID().uuidString, workspace_id: workspace, root: repo.root)))
        await refresh()
    }
    var rejectedRoots: [String] {
        var roots = view?.result?.repos.filter { $0.push == "rejected" }.map(\.root) ?? []
        if let pushed = view?.pull_push_result, pushed.push == "rejected", !roots.contains(pushed.root) { roots.append(pushed.root) }
        return roots
    }
    func pullPush(_ root: String) async {
        guard canCommit, !busy else { return }
        submitting = true; defer { submitting = false }
        reportedPush = nil
        await dispatch(.git_pull_push(EventGitPullPush(now_ms: 0, wall_time_ms: 0, intent_id: UUID().uuidString, workspace_id: workspace, root: root)))
        await refresh()
    }
    func retry() async {
        guard canCommit, !busy else { return }
        await dispatch(.git_retry(EventGitRetry(now_ms: 0, wall_time_ms: 0, intent_id: UUID().uuidString)))
        await refresh()
    }
    /// Retry a read when a newly-created chat finally gains a synced route.
    func catalog(available: Bool, connected: Bool) async {
        let arrived = available && connected && (!routeReady || !routeConnected)
        routeReady = available; routeConnected = connected
        if arrived {
            await dispatch(.git_status_refresh(EventGitStatusRefresh(now_ms: 0, wall_time_ms: 0, intent_id: UUID().uuidString, workspace_id: workspace, thread_id: thread)))
            await refresh()
        }
    }
    private func receipts() async {
        guard !pending.isEmpty,
              let bytes = try? await query("operations"),
              let operations = try? JSONDecoder().decode(OperationsQuery.self, from: bytes).data?.items else { return }
        for operation in operations where pending[operation.intent_id] != nil && operation.state != "pending" {
            // Core alone owns recovery. An uncertain receipt never becomes a new commit.
            pending[operation.intent_id] = nil
            if let generation = generatingSelection, generation.id == operation.intent_id {
                if operation.state == "succeeded" { generatedSelection = generation.key }
                generatingSelection = nil
            }
            if operation.state == "uncertain" { notice = "Checking original operation…"; continue }
            if operation.state != "succeeded" {
                quick = false; confirmMain = false
                notice = operation.error?.message ?? "The host refused this action."
                if ["review_expired", "changed_since_review"].contains(operation.error?.code ?? "") {
                    await begin(push: wantsPush)
                }
            }
        }
    }
    private func dispatch(_ event: Event) async {
        var id: String?
        do {
            let data = try JSONEncoder().encode(event)
            id = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["intent_id"] as? String
            let mutation: Bool
            switch event { case .git_commit, .git_push, .git_pull_push, .git_retry: mutation = true; default: mutation = false }
            if let id { pending[id] = mutation }
            try await sendEvent(event)
            await receipts()
        } catch {
            if let id { pending[id] = nil }
            notice = "The host is unavailable. Check the operation before trying again."
        }
    }
}
