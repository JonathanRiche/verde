import Foundation
import Observation

/// Workspace explorer: the read-only file tree and the workspace-wide Changes list. Everything is
/// read through the host core (`workspace_files_list`, `workspace_file_read`,
/// `workspace_changes_open`, `workspace_file_patch`); the phone never reads workspace files itself.
/// Files are addressed by (root id, root-relative path). Paths and contents are never logged.

/// Chat filter of the Changes list: everything, one claiming chat, or files no chat claimed.
enum ChangesFilter: Hashable {
    case all
    case unassigned
    case chat(threadID: String, title: String)

    var threadID: String? { if case .chat(let id, _) = self { return id }; return nil }
}

func changeOwners(_ repos: [GitWorkspaceRepo]) -> [ChangesFilter] {
    var seen = Set<String>()
    var out: [ChangesFilter] = []
    for owner in repos.flatMap(\.files).flatMap(\.owners) where seen.insert(owner.local_thread_id).inserted {
        out.append(.chat(threadID: owner.local_thread_id, title: ownerTitle(owner)))
    }
    return out
}

/// The host always titles owners; the short-id fallback is only a guard.
func ownerTitle(_ owner: GitWorkspaceOwner) -> String {
    owner.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Chat " + String(owner.local_thread_id.suffix(6)) : owner.title
}

extension GitWorkspaceFile {
    func matches(_ filter: ChangesFilter) -> Bool {
        switch filter {
        case .all: return true
        case .unassigned: return owners.isEmpty || ownership == "unassigned"
        case .chat(let id, _): return owners.contains { $0.local_thread_id == id }
        }
    }
}

/// One-letter git-style status for the file list.
func changeLetter(_ file: GitWorkspaceFile) -> String {
    if file.untracked { return "U" }
    switch file.status {
    case "added": return "A"
    case "deleted": return "D"
    case "renamed": return "R"
    default: return "M"
    }
}

let explorerUpdateText = "Update Verde on the computer to use this."

func explorerErrorText(_ error: LocalError?) -> String? {
    guard let error else { return nil }
    switch error.code {
    case "unsupported", "method_not_found": return explorerUpdateText
    case "scope_denied", "forbidden": return "This phone isn't allowed to browse workspace files."
    case "offline", "cancelled": return "Connect to the host to refresh."
    case "path_outside_roots": return "This path is outside the workspace folders."
    case "not_found": return "This no longer exists on the host."
    case "root_not_found": return "This folder is no longer part of the workspace."
    case "capability_unavailable": return "Git isn't available for this repository on the host."
    case "resource_not_found": return "This workspace is no longer on the host."
    case "resource_limit": return "Too many folders open. Collapse some and try again."
    case "invalid_path": return "This path can't be opened."
    default:
        return error.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "The host couldn't read this workspace." : error.message
    }
}

/// `context_lines` that asks the host for the whole file around the changes.
let fullContextLines: UInt32 = 1_000_000
/// The root id the host gives the workspace home.
let homeRoot = "home"

extension ExplorerRoot {
    /// Absolute host path of a root-relative file; nil when the host sent no root path.
    func absolute(_ relative: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var base = Substring(path)
        while base.hasSuffix("/") { base = base.dropLast() }
        return String(base) + "/" + relative
    }
}

/// What the viewer shows for a Files-tab read: the file's bytes or a problem.
enum WorkspaceReadOutcome: Equatable {
    case bytes(Data)
    case problem(FileProblem)
}

/// Viewer outcome of a failed `workspace_file_read`; nil falls back to the `/api/file` fetch (older hosts).
func readFailure(_ code: String?) -> WorkspaceReadOutcome? {
    switch code {
    case "unsupported", "method_not_found": return nil
    case "not_found", "root_not_found", "resource_not_found": return .problem(.of("not_found", limit: 0))
    case "path_outside_roots", "scope_denied", "forbidden": return .problem(.of("forbidden", limit: 0))
    case "offline", "cancelled", "timeout": return .problem(.of("offline", limit: 0))
    case "invalid_path", "invalid_params", "not_file": return .problem(.unresolved)
    default: return .problem(.failed)
    }
}

/// Viewer outcome of a finished `workspace_file` view: bytes, a problem, or nil to fetch through
/// `/api/file` (`external` kinds such as PDFs, and older hosts).
func readOutcome(_ view: ExplorerFileView, limit: UInt32 = ViewerKind.text.limit) -> WorkspaceReadOutcome? {
    if let error = view.error { return readFailure(error.code) }
    if !view.supported { return nil }
    guard let result = view.result else { return .problem(.failed) }
    switch result.kind {
    case "text", "markdown", "image":
        if result.encoding == "base64" {
            guard let data = Data(base64Encoded: result.content) else { return .problem(.unreadable) }
            return .bytes(data)
        }
        return .bytes(Data(result.content.utf8))
    case "binary": return .problem(.binary)
    case "too_large": return .problem(.of("too_large", limit: limit))
    default: return nil
    }
}

extension CoreHost {
    /// Reads one workspace file through the core (`workspace.files.read`), then always closes the
    /// preview so the body isn't held in core state. Throws only on cancellation.
    func readWorkspaceFile(workspaceID: String, root: String, path: String, limit: UInt32,
                           wait: Duration = .seconds(30)) async throws -> WorkspaceReadOutcome? {
        let id = UUID().uuidString
        defer {
            _ = try? send(.workspace_preview_close(EventWorkspacePreviewClose(now_ms: 0, wall_time_ms: 0,
                intent_id: UUID().uuidString, workspace_id: workspaceID)))
        }
        do {
            try send(.workspace_file_read(EventWorkspaceFileRead(now_ms: 0, wall_time_ms: 0, intent_id: id,
                workspace_id: workspaceID, root: root, path: path)))
            let deadline = ContinuousClock.now.advanced(by: wait)
            repeat {
                try Task.checkCancellation()
                let operations = try JSONDecoder().decode(OperationsQuery.self, from: query("operations"))
                if let op = operations.data?.items.first(where: { $0.intent_id == id }), op.state != "pending" {
                    guard op.state == "succeeded" else { return readFailure(op.error?.code) }
                    let view = try JSONDecoder().decode(ExplorerFileQuery.self, from: query("workspace_file")).data
                    guard let view, view.root == root, view.path == path else { return .problem(.failed) }
                    return readOutcome(view, limit: limit)
                }
                try await Task.sleep(for: .milliseconds(100))
            } while ContinuousClock.now < deadline
            return .problem(.of("timeout", limit: limit))
        } catch is CancellationError {
            throw CancellationError()
        } catch CoreBridgeError.rejected {
            return .problem(.failed)
        } catch {
            return .problem(.unavailable)
        }
    }
}

/// The `selection_prompt` utility query (client_core's shared ask-agent formatter).
func selectionPromptSelector(_ excerpt: SelectionExcerpt, roots: [ExplorerRoot], instruction: String) -> String? {
    struct Root: Encodable { let name: String; let path: String; let home: Bool }
    struct Selector: Encodable {
        let utility: String
        let path: String
        let roots: [Root]
        let start_line: Int
        let end_line: Int
        let side: String?
        let text: String
        let instruction: String
    }
    let selector = Selector(utility: "selection_prompt", path: excerpt.path,
                            roots: roots.map { Root(name: $0.name, path: $0.path, home: $0.home) },
                            start_line: excerpt.start, end_line: excerpt.end, side: excerpt.side,
                            text: excerpt.text, instruction: instruction)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard let data = try? encoder.encode(selector) else { return nil }
    return String(decoding: data, as: UTF8.self)
}

private struct SelectionPromptReply: Decodable {
    struct Body: Decodable { let text: String? }
    let data: Body?
}

private struct ExplorerUtility: Encodable {
    let utility: String
    let text: String
    var language: String?
}

private func explorerUtilitySelector(_ utility: String, _ text: String, language: String? = nil) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let data = (try? encoder.encode(ExplorerUtility(utility: utility, text: text, language: language))) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

/// Same bounds as the transcript: the core caps utility input at 64 KiB; `diff_index` at 1 MiB.
private let explorerMaxRenderSelector = 72 * 1024
private let explorerMaxIndexSelector = 1024 * 1024

/// Decodes a utility reply off the main actor.
private func explorerDecodeDetached<T>(_ data: Data, _ transform: @escaping (Data) throws -> T?) async -> T? {
    await Task.detached(priority: .userInitiated) { try? transform(data) }.value ?? nil
}

/// One workspace's explorer projections for the selected host. Intents go out in order on one lane.
@MainActor @Observable
final class ExplorerModel: DiffRenderSource {
    static let patchSelector = "workspace_patch"

    let workspaceID: String
    let filesSelector: String
    let changesSelector: String
    private(set) var files: ExplorerFilesView?
    private(set) var changes: ExplorerChangesView?
    private(set) var patch: ExplorerPatchView?
    /// No core for the selected host (signed out, failed).
    private(set) var unavailable = false

    @ObservationIgnored private let connect: () async -> Bool
    @ObservationIgnored private let sendEvent: (Event) async throws -> Void
    @ObservationIgnored private let queryData: (String) async throws -> Data
    @ObservationIgnored private var connected: Bool?
    @ObservationIgnored private var lane: Task<Void, Never>?
    @ObservationIgnored private(set) var watching = false
    @ObservationIgnored private let highlightCache = RenderLRU<RenderResult<[RenderSpan]>>(64)
    @ObservationIgnored private let diffCache = RenderLRU<RenderResult<DiffView>>(16)
    @ObservationIgnored private let indexCache = RenderLRU<RenderResult<DiffIndexView>>(8)

    init(workspaceID: String, connect: @escaping () async -> Bool = { true },
         send: @escaping (Event) async throws -> Void, query: @escaping (String) async throws -> Data) {
        self.workspaceID = workspaceID
        filesSelector = "workspace_files:" + workspaceID
        changesSelector = "workspace_changes:" + workspaceID
        self.connect = connect
        sendEvent = send
        queryData = query
    }

    /// Bound to the host selected when the screen opened; a host switch makes it unavailable.
    convenience init(browse: BrowseModel, workspaceID: String) {
        let hostID = browse.hostID
        self.init(workspaceID: workspaceID, connect: {
            guard browse.hostID == hostID, let session = browse.session else { return false }
            await session.start()
            return session.host != nil
        }, send: { event in
            guard browse.hostID == hostID, let host = browse.session?.host else { throw CoreBridgeError.closed }
            try await host.send(event)
        }, query: { selector in
            guard browse.hostID == hostID, let host = browse.session?.host else { throw CoreBridgeError.closed }
            return try await host.query(selector)
        })
    }

    /// Connects once; cached projections (a tree opened earlier) show before any new read.
    private func ensureConnected() async -> Bool {
        if let connected { return connected }
        let ok = await connect()
        if let connected { return connected }
        connected = ok
        guard ok else { unavailable = true; return false }
        for selector in [filesSelector, changesSelector, Self.patchSelector] {
            if let data = try? await queryData(selector) { receive(selector, data) }
        }
        return true
    }

    func start() { enqueue { _ = await $0.ensureConnected() } }

    /// A core publication of one of this model's selectors (other workspaces are ignored).
    func receive(_ selector: String, _ data: Data?) {
        guard let data else { return }
        let decoder = JSONDecoder()
        switch selector {
        case filesSelector:
            if let view = try? decoder.decode(ExplorerFilesQuery.self, from: data).data, view.workspace_id == workspaceID { files = view }
        case changesSelector:
            if let view = try? decoder.decode(ExplorerChangesQuery.self, from: data).data, view.workspace_id == workspaceID { changes = view }
        case Self.patchSelector:
            if let view = try? decoder.decode(ExplorerPatchQuery.self, from: data).data,
               view.workspace_id.isEmpty || view.workspace_id == workspaceID { patch = view }
        default: break
        }
    }

    private func enqueue(_ action: @escaping (ExplorerModel) async -> Void) {
        let previous = lane
        lane = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await action(self)
        }
    }

    private func intent(_ build: @escaping (String) -> Event) {
        enqueue { model in
            guard await model.ensureConnected() else { return }
            // The view keeps its last state; the next action retries.
            try? await model.sendEvent(build(UUID().uuidString))
        }
    }

    /// Workspace folders: the home (`home`) and the verde.toml folders.
    func loadRoots() {
        let ws = workspaceID
        intent { .workspace_files_list(EventWorkspaceFilesList(now_ms: 0, wall_time_ms: 0, intent_id: $0, workspace_id: ws)) }
    }

    /// Lists one folder of `root` ("" is the root itself); the core coalesces a read already in flight.
    func list(root: String, path: String) {
        let ws = workspaceID
        intent { .workspace_files_list(EventWorkspaceFilesList(now_ms: 0, wall_time_ms: 0, intent_id: $0, workspace_id: ws, root: root, path: path)) }
    }

    /// Starts watching: the core refreshes on chat turns and foreground while open.
    func openChanges() {
        watching = true
        let ws = workspaceID
        intent { .workspace_changes_open(EventWorkspaceChangesOpen(now_ms: 0, wall_time_ms: 0, intent_id: $0, workspace_id: ws)) }
    }

    func closeChanges() {
        guard watching else { return }
        watching = false
        let ws = workspaceID
        intent { .workspace_changes_close(EventWorkspaceChangesClose(now_ms: 0, wall_time_ms: 0, intent_id: $0, workspace_id: ws)) }
    }

    func openPatch(root: String, path: String, full: Bool) {
        let ws = workspaceID
        intent { .workspace_file_patch(EventWorkspaceFilePatch(now_ms: 0, wall_time_ms: 0, intent_id: $0, workspace_id: ws,
                                                              root: root, path: path, context_lines: full ? fullContextLines : nil)) }
    }

    /// The shared ask-agent message (client_core `selection_prompt`), or nil when the core refuses it.
    func prompt(_ excerpt: SelectionExcerpt, roots: [ExplorerRoot], instruction: String) async -> String? {
        guard await ensureConnected(), let selector = selectionPromptSelector(excerpt, roots: roots, instruction: instruction),
              let data = try? await queryData(selector) else { return nil }
        return (try? JSONDecoder().decode(SelectionPromptReply.self, from: data))?.data?.text
    }

    // MARK: K-11 rendering utilities for the diff screen (pure core queries)

    func cachedIndex(_ body: String) -> RenderResult<DiffIndexView>? { indexCache[body] }

    func index(_ body: String) async -> RenderResult<DiffIndexView> {
        if let cached = indexCache[body] { return cached }
        let result = RenderResult(await utility(explorerUtilitySelector("diff_index", body), limit: explorerMaxIndexSelector) { data in
            try JSONDecoder().decode(DiffIndexQuery.self, from: data).data
        })
        indexCache[body] = result
        return result
    }

    func cachedDiff(_ text: String) -> RenderResult<DiffView>? { diffCache[text] }

    func diff(_ text: String) async -> RenderResult<DiffView> {
        if let cached = diffCache[text] { return cached }
        let result = RenderResult(await utility(explorerUtilitySelector("diff", text)) { data in
            try JSONDecoder().decode(DiffQuery.self, from: data).data
        })
        diffCache[text] = result
        return result
    }

    func cachedHighlight(_ code: String, language: String) -> RenderResult<[RenderSpan]>? { highlightCache[language + "\u{0}" + code] }

    func highlight(_ code: String, language: String) async -> RenderResult<[RenderSpan]> {
        let key = language + "\u{0}" + code
        if let cached = highlightCache[key] { return cached }
        let result = RenderResult(await utility(explorerUtilitySelector("highlight", code, language: language)) { data in
            try JSONDecoder().decode(HighlightQuery.self, from: data).data?.spans
        })
        highlightCache[key] = result
        return result
    }

    private func utility<T>(_ selector: String, limit: Int = explorerMaxRenderSelector,
                            _ transform: @escaping (Data) throws -> T?) async -> T? {
        guard selector.utf8.count <= limit, await ensureConnected(), let data = try? await queryData(selector) else { return nil }
        return await explorerDecodeDetached(data, transform)
    }
}
