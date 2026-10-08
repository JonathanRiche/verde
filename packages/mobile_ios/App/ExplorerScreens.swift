import SwiftUI

/// Workspace explorer screens (Android ExplorerScreens.kt parity): the Changes list with chat
/// filters and a commit bar, the Files tree, one changed file's diff, and a Files-tab file in the
/// viewer. Each screen owns an `ExplorerModel` bound to the host selected when it opened; all reads
/// go through the core. Paths and contents are never logged.

/// Feeds the model the core's publications of its selectors, connects it, and leaves the screen
/// when the selected host changes.
private struct ExplorerSync: ViewModifier {
    let browse: BrowseModel
    let model: ExplorerModel
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        let snapshots = browse.session?.store.snapshots
        content
            .onChange(of: snapshots?[model.filesSelector], initial: true) { _, data in model.receive(model.filesSelector, data) }
            .onChange(of: snapshots?[model.changesSelector], initial: true) { _, data in model.receive(model.changesSelector, data) }
            .onChange(of: snapshots?[ExplorerModel.patchSelector], initial: true) { _, data in model.receive(ExplorerModel.patchSelector, data) }
            .task { model.start() }
            .onChange(of: browse.hostID) { dismiss() }
    }
}

/// Inline title with the workspace (or folder) underneath.
private struct ExplorerTitle: ToolbarContent {
    let title: String
    let subtitle: String?
    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(title).font(VerdeTheme.ui(15, bold: true)).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(VerdeTheme.ui(11)).foregroundStyle(VerdeTheme.muted).lineLimit(1).truncationMode(.head)
                }
            }
        }
    }
}

private struct ExplorerMessage: View {
    let text: String
    var retry: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 8) {
            Text(text).font(VerdeTheme.ui(14)).foregroundStyle(VerdeTheme.muted).multilineTextAlignment(.center)
            if let retry { Button("Try again", action: retry) }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ExplorerLoading: View {
    let identifier: String
    var body: some View { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier(identifier) }
}

private func signed(_ additions: UInt64, _ deletions: UInt64) -> String { "+\(additions) −\(deletions)" }

// MARK: - Changes

struct ChangesRoute: View {
    let browse: BrowseModel
    let workspaceID: String
    @State private var model: ExplorerModel
    @State private var git: GitChangesModel?
    @State private var selected: ChangesFilter = .all
    @Environment(\.openRoute) private var openRoute

    init(browse: BrowseModel, workspaceID: String) {
        self.browse = browse
        self.workspaceID = workspaceID
        _model = State(initialValue: ExplorerModel(browse: browse, workspaceID: workspaceID))
    }

    var body: some View {
        let workspace = browse.state.workspaces?.items.first { $0.workspace_id == workspaceID }
        let changes = model.changes
        let repos = changes?.repos ?? []
        let threads = workspace?.threads ?? []
        // The ledger's title wins; a chat the catalog knows by a better name fills a placeholder.
        let owners: [ChangesFilter] = changeOwners(repos).map { owner in
            guard case .chat(let id, let title) = owner, title.hasPrefix("Chat "),
                  let better = threads.first(where: { $0.thread_id == id })?.title,
                  !better.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return owner }
            return .chat(threadID: id, title: better)
        }
        let filter = activeFilter(owners)
        VStack(spacing: 0) {
            if !repos.isEmpty { chips(repos, owners: owners, filter: filter) }
            if !repos.isEmpty, let error = explorerErrorText(changes?.error) {
                Text(error).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 4)
            }
            content(changes, repos, filter: filter).frame(maxWidth: .infinity, maxHeight: .infinity)
            if repos.contains(where: { !$0.files.isEmpty }) { CommitBar(filter: filter, owners: owners, onCommit: commit) }
        }
        .background(VerdeTheme.background)
        .accessibilityIdentifier("changes-screen")
        .navigationTitle("Changes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ExplorerTitle(title: "Changes", subtitle: workspace?.label)
            ToolbarItem(placement: .primaryAction) {
                if changes?.loading == true { ProgressView() }
                else { Button { model.openChanges() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh changes") }
            }
        }
        .modifier(ExplorerSync(browse: browse, model: model))
        .onAppear { model.openChanges() }
        .onDisappear { model.closeChanges() }
        .overlay(alignment: .bottom) { if let git, !git.sheet { GitActionToastCard(model: git) } }
        .sheet(isPresented: Binding(get: { git?.sheet == true }, set: { if !$0 { git?.dismissSheet() } })) {
            if let git { GitCommitSheet(model: git) }
        }
        .alert("Commit & push to \(git?.mainBranch ?? "main")?", isPresented: Binding(get: { git?.confirmMain == true }, set: { git?.confirmMain = $0 })) {
            Button("Abort", role: .cancel) {}
            Button("Commit & push to \(git?.mainBranch ?? "main")") { Task { await git?.commit(push: true) } }
            Button("Create branch & continue") { Task { await git?.commit(push: true, newBranch: true) } }
        }
        .onChange(of: browse.session?.store.snapshots["operations"]) { Task { await git?.refresh() } }
        .onChange(of: browse.session?.store.snapshots["git_review"]) { Task { await git?.refresh() } }
        .onChange(of: browse.session?.store.snapshots["git_status"]) { Task { await git?.refresh() } }
        // Changes aren't pushed: refetch once a commit finishes or the sheet closes.
        .onChange(of: git.map { $0.busy || $0.sheet } ?? false) { was, now in if was && !now { model.openChanges() } }
    }

    /// The chosen filter; a chat that no longer claims anything falls back to All.
    private func activeFilter(_ owners: [ChangesFilter]) -> ChangesFilter {
        guard let id = selected.threadID else { return selected }
        return owners.first { $0.threadID == id } ?? .all
    }

    private func chips(_ repos: [GitWorkspaceRepo], owners: [ChangesFilter], filter: ChangesFilter) -> some View {
        let total = repos.reduce(0) { $0 + $1.files.count }
        let unassigned = repos.reduce(0) { sum, repo in sum + repo.files.filter { $0.matches(.unassigned) }.count }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("All · \(total)", selected: filter == .all, id: "changes-filter-all") { selected = .all }
                ForEach(owners, id: \.self) { owner in
                    let count = repos.reduce(0) { sum, repo in sum + repo.files.filter { $0.matches(owner) }.count }
                    if case .chat(let id, let title) = owner {
                        chip("\(title) · \(count)", selected: filter == owner, id: "changes-filter-" + id) { selected = owner }
                    }
                }
                if unassigned > 0 {
                    chip("Unassigned · \(unassigned)", selected: filter == .unassigned, id: "changes-filter-unassigned") { selected = .unassigned }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    private func chip(_ label: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(VerdeTheme.ui(13, bold: selected)).lineLimit(1).frame(maxWidth: 220)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .foregroundStyle(selected ? VerdeTheme.accent : VerdeTheme.text)
                .background(selected ? VerdeTheme.accent.opacity(0.16) : VerdeTheme.alternate, in: Capsule())
                .overlay(Capsule().stroke(selected ? VerdeTheme.accent : VerdeTheme.border))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    @ViewBuilder
    private func content(_ changes: ExplorerChangesView?, _ repos: [GitWorkspaceRepo], filter: ChangesFilter) -> some View {
        if model.unavailable {
            ExplorerMessage(text: "Connect to a host to see changes.")
        } else if changes?.supported == false {
            ExplorerMessage(text: explorerUpdateText)
        } else if repos.isEmpty, let error = explorerErrorText(changes?.error) {
            ExplorerMessage(text: error) { model.openChanges() }
        } else if let changes, changes.loaded || (!changes.loading && changes.error != nil) {
            if repos.allSatisfy({ $0.files.isEmpty && !$0.too_many_files }) {
                ExplorerMessage(text: "No uncommitted changes.")
            } else {
                List {
                    ForEach(repos, id: \.root) { repo in
                        let shown = repo.files.filter { $0.matches(filter) }
                        if !shown.isEmpty || repo.too_many_files {
                            Section {
                                if repo.too_many_files {
                                    Text("Too many changed files to list here. Review them on the computer.")
                                        .font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted)
                                }
                                ForEach(shown, id: \.path) { file in
                                    Button { openRoute(.patch(workspace: workspaceID, root: repo.root, path: file.path)) } label: { ChangeRow(file: file) }
                                        .buttonStyle(.plain)
                                        .accessibilityIdentifier("change-" + file.path)
                                }
                            } header: { RepoHeader(repo: repo, showName: repos.count > 1) }
                        }
                    }
                    if !repos.contains(where: { repo in repo.too_many_files || repo.files.contains { $0.matches(filter) } }) {
                        Text("No changes for this filter.").font(VerdeTheme.ui(14)).foregroundStyle(VerdeTheme.muted)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        } else {
            ExplorerLoading(identifier: "changes-loading")
        }
    }

    /// Commits go through the chat-scoped commit flow of the chosen chat.
    private func commit(_ thread: String) {
        let next = GitChangesModel(browse: browse, workspace: workspaceID, thread: thread)
        git = next
        Task {
            await next.start()
            await next.begin(push: false)
        }
    }
}

private struct RepoHeader: View {
    let repo: GitWorkspaceRepo
    let showName: Bool
    var body: some View {
        let detail = [repo.branch ?? repo.head.map { "detached " + String($0.prefix(8)) },
                      repo.ahead > 0 ? "↑\(repo.ahead)" : nil,
                      repo.behind > 0 ? "↓\(repo.behind)" : nil].compactMap { $0 }.joined(separator: " · ")
        let additions = repo.files.reduce(UInt64(0)) { $0 + UInt64($1.additions) }
        let deletions = repo.files.reduce(UInt64(0)) { $0 + UInt64($1.deletions) }
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if showName { Text(repo.name).font(VerdeTheme.ui(13, bold: true)).foregroundStyle(VerdeTheme.text) }
                if !detail.isEmpty { Text(detail).font(VerdeTheme.ui(11)).foregroundStyle(VerdeTheme.muted) }
            }
            Spacer(minLength: 8)
            Text("\(repo.files.count) · " + signed(additions, deletions)).font(VerdeTheme.ui(11)).foregroundStyle(VerdeTheme.muted)
        }
        .textCase(nil)
    }
}

private struct ChangeRow: View {
    let file: GitWorkspaceFile
    var body: some View {
        let letter = changeLetter(file)
        let color = letter == "A" || letter == "U" ? Color(uiColor: .systemGreen) : letter == "D" ? VerdeTheme.danger : VerdeTheme.warning
        let directory = (file.path as NSString).deletingLastPathComponent
        HStack(spacing: 10) {
            Text(letter).font(VerdeTheme.mono(13)).foregroundStyle(color).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(basename(file.path)).font(VerdeTheme.ui(14)).lineLimit(1)
                if !directory.isEmpty {
                    Text(directory).font(VerdeTheme.ui(11)).foregroundStyle(VerdeTheme.subtle).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
            if let owner = file.owners.first {
                Text(ownerTitle(owner) + (file.owners.count > 1 ? " +\(file.owners.count - 1)" : "") + (owner.unclear ? "?" : ""))
                    .font(VerdeTheme.ui(11)).foregroundStyle(VerdeTheme.muted).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(VerdeTheme.mutedPanel, in: RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: 120, alignment: .trailing)
            }
            if file.binary { Text("binary").font(VerdeTheme.ui(11)).foregroundStyle(VerdeTheme.subtle) }
            else { Text(signed(UInt64(file.additions), UInt64(file.deletions))).font(VerdeTheme.mono(11)).foregroundStyle(VerdeTheme.muted) }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// Commit uses the chat-scoped commit flow; with no chat filter, the user picks the chat first.
private struct CommitBar: View {
    let filter: ChangesFilter
    let owners: [ChangesFilter]
    let onCommit: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(caption).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch filter {
            case .chat(let id, _):
                Button("Commit") { onCommit(id) }.buttonStyle(.borderedProminent).accessibilityIdentifier("changes-commit")
            case .all:
                Menu {
                    ForEach(owners, id: \.self) { owner in
                        if case .chat(let id, let title) = owner { Button(title) { onCommit(id) }.accessibilityIdentifier("commit-as-" + id) }
                    }
                } label: { Text("Commit…") }
                .buttonStyle(.borderedProminent).disabled(owners.isEmpty).accessibilityIdentifier("changes-commit")
            case .unassigned:
                Button("Commit…") {}.buttonStyle(.borderedProminent).disabled(true).accessibilityIdentifier("changes-commit")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(VerdeTheme.panel)
        .overlay(alignment: .top) { Rectangle().fill(VerdeTheme.border).frame(height: 1) }
    }

    private var caption: String {
        switch filter {
        case .chat(_, let title): return "Commit what \(title) changed"
        case .unassigned: return "Unassigned files are committed from the computer"
        case .all: return owners.isEmpty ? "No chat claimed these files" : "Commits go through a chat"
        }
    }
}

// MARK: - Files

/// Key of one folder: root id and root-relative path ("" is the root itself).
func dirKey(_ root: String, _ path: String) -> String { root + "\u{0}" + path }

/// One visible row of the flattened tree.
enum TreeRow: Identifiable {
    case root(ExplorerRoot, open: Bool)
    case item(root: String, entry: ExplorerEntry, depth: Int, open: Bool)
    case note(root: String, path: String, depth: Int, text: String, retry: Bool, loading: Bool)

    var id: String {
        switch self {
        case .root(let root, _): return "root:" + root.id
        case .item(let root, let entry, _, _): return "entry:" + dirKey(root, entry.path)
        case .note(let root, let path, _, _, _, _): return "note:" + dirKey(root, path)
        }
    }
}

/// Flattens the roots and every expanded, listed folder into rows (depth-first, listing order).
func treeRows(_ view: ExplorerFilesView?, expanded: Set<String>) -> [TreeRow] {
    guard let view else { return [] }
    var dirs: [String: ExplorerDir] = [:]
    for dir in view.dirs { dirs[dirKey(dir.root, dir.path)] = dir }
    var out: [TreeRow] = []
    func folder(_ root: String, _ path: String, _ depth: Int) {
        guard let dir = dirs[dirKey(root, path)], !(dir.loading && !dir.loaded) else {
            out.append(.note(root: root, path: path, depth: depth, text: "Loading…", retry: false, loading: true))
            return
        }
        if let error = dir.error, !dir.loaded {
            out.append(.note(root: root, path: path, depth: depth, text: explorerErrorText(error) ?? "", retry: true, loading: false))
            return
        }
        if dir.entries.isEmpty { out.append(.note(root: root, path: path, depth: depth, text: "Empty folder", retry: false, loading: false)) }
        for entry in dir.entries {
            let open = entry.kind == "directory" && expanded.contains(dirKey(root, entry.path))
            out.append(.item(root: root, entry: entry, depth: depth, open: open))
            if open { folder(root, entry.path, depth + 1) }
        }
        if dir.truncated {
            out.append(.note(root: root, path: path + "\u{0}more", depth: depth,
                             text: "Showing the first \(dir.entries.count) entries", retry: false, loading: false))
        }
    }
    for root in view.roots {
        let open = expanded.contains(dirKey(root.id, ""))
        out.append(.root(root, open: open))
        if open { folder(root.id, "", 1) }
    }
    return out
}

func entrySize(_ bytes: UInt64) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    return bytes >= 1024 * 1024 ? "\(bytes / (1024 * 1024)) MB" : "\(bytes / 1024) KB"
}

struct FilesRoute: View {
    let browse: BrowseModel
    let workspaceID: String
    @State private var model: ExplorerModel
    @State private var expanded: Set<String> = []
    @State private var seeded = false
    @Environment(\.openRoute) private var openRoute

    init(browse: BrowseModel, workspaceID: String) {
        self.browse = browse
        self.workspaceID = workspaceID
        _model = State(initialValue: ExplorerModel(browse: browse, workspaceID: workspaceID))
    }

    var body: some View {
        let label = browse.state.workspaces?.items.first { $0.workspace_id == workspaceID }?.label
        let files = model.files
        let listed = Set((files?.dirs ?? []).map { dirKey($0.root, $0.path) })
        Group {
            if model.unavailable {
                ExplorerMessage(text: "Connect to a host to browse files.")
            } else if files?.supported == false {
                ExplorerMessage(text: explorerUpdateText)
            } else if (files?.roots ?? []).isEmpty, let error = explorerErrorText(files?.error) {
                ExplorerMessage(text: error) { model.loadRoots() }
            } else if let files, files.loaded {
                List(treeRows(files, expanded: expanded)) { row in
                    line(row, roots: files.roots)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(VerdeTheme.background)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else {
                ExplorerLoading(identifier: "files-loading")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VerdeTheme.background)
        .accessibilityIdentifier("files-screen")
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ExplorerTitle(title: "Files", subtitle: label)
            ToolbarItem(placement: .primaryAction) {
                Button { model.loadRoots(); expanded.forEach(list) } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh files")
            }
        }
        .modifier(ExplorerSync(browse: browse, model: model))
        .task { model.loadRoots() }
        // The home folder starts open; everything else opens on tap.
        .onChange(of: (files?.roots ?? []).map(\.id), initial: true) { _, ids in
            guard !seeded, !ids.isEmpty, let roots = model.files?.roots else { return }
            seeded = true
            expanded.insert(dirKey((roots.first(where: \.home) ?? roots[0]).id, ""))
        }
        // Expanded folders the core hasn't listed (first open, or a cache wiped by sign-out) load now.
        .onChange(of: ListingKey(expanded: expanded, listed: listed, loaded: files?.loaded == true), initial: true) { _, key in
            guard key.loaded else { return }
            key.expanded.subtracting(key.listed).forEach(list)
        }
    }

    private struct ListingKey: Equatable {
        let expanded: Set<String>
        let listed: Set<String>
        let loaded: Bool
    }

    private func list(_ key: String) {
        let parts = key.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false)
        model.list(root: String(parts[0]), path: parts.count > 1 ? String(parts[1]) : "")
    }

    private func toggle(_ key: String) {
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
    }

    @ViewBuilder
    private func line(_ row: TreeRow, roots: [ExplorerRoot]) -> some View {
        switch row {
        case .root(let root, let open):
            TreeLine(depth: 0, open: open, folder: true, name: root.name, detail: nil, ignored: false) { toggle(dirKey(root.id, "")) }
                .accessibilityIdentifier("files-root-" + root.name)
        case .item(let rootID, let entry, let depth, let open):
            let directory = entry.kind == "directory"
            TreeLine(depth: depth, open: open, folder: directory, name: entry.name + (entry.symlink ? " ↗" : ""),
                     detail: directory ? nil : entrySize(entry.size), ignored: entry.ignored) {
                if directory { toggle(dirKey(rootID, entry.path)) }
                else if let root = roots.first(where: { $0.id == rootID }) {
                    openRoute(.workspaceFile(workspace: workspaceID, root: root.id, path: entry.path, absolute: root.absolute(entry.path) ?? ""))
                }
            }
            .accessibilityIdentifier("files-entry-" + entry.path)
        case .note(let root, let path, let depth, let text, let retry, let loading):
            HStack(spacing: 8) {
                if loading { ProgressView().controlSize(.small) }
                Text(text).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted)
                Spacer(minLength: 0)
                if retry { Button("Retry") { model.list(root: root, path: path) }.buttonStyle(.borderless) }
            }
            .padding(.leading, CGFloat(16 + 16 * depth)).padding(.trailing, 16).padding(.vertical, 4)
        }
    }
}

private struct TreeLine: View {
    let depth: Int
    let open: Bool
    let folder: Bool
    let name: String
    let detail: String?
    let ignored: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if folder {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VerdeTheme.muted).frame(width: 20)
                        .accessibilityLabel(open ? "Collapse" : "Expand")
                } else {
                    Color.clear.frame(width: 20, height: 1)
                }
                Text(name).font(VerdeTheme.ui(14, bold: depth == 0 || folder)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let detail { Text(detail).font(VerdeTheme.ui(11)).foregroundStyle(VerdeTheme.subtle) }
            }
            .padding(.leading, CGFloat(8 + 16 * depth)).padding(.trailing, 16).padding(.vertical, 8)
            .opacity(ignored ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Patch

struct PatchRoute: View {
    let browse: BrowseModel
    let workspaceID: String
    let root: String
    let path: String
    @State private var model: ExplorerModel

    init(browse: BrowseModel, workspaceID: String, root: String, path: String) {
        self.browse = browse
        self.workspaceID = workspaceID
        self.root = root
        self.path = path
        _model = State(initialValue: ExplorerModel(browse: browse, workspaceID: workspaceID))
    }

    var body: some View {
        let workspace = browse.state.workspaces?.items.first { $0.workspace_id == workspaceID }
        let base = trimmedRoot(root)
        let repoName = model.changes?.repos.first { $0.root == root }?.name
        // Diff selections read "<repo>/<path>" unless the repository is the workspace home.
        let roots = [ExplorerRoot(id: root, name: repoName ?? basename(base), path: root,
                                  home: workspace.map { trimmedRoot($0.path) == base } ?? false)]
        SelectionScope(browse: browse, explorer: model, path: base + "/" + path, roots: roots) {
            PatchScreen(browse: browse, model: model, root: root, path: path)
        }
        .modifier(ExplorerSync(browse: browse, model: model))
    }
}

private func trimmedRoot(_ root: String) -> String {
    var value = Substring(root)
    while value.hasSuffix("/") { value = value.dropLast() }
    return String(value)
}

private struct PatchScreen: View {
    let browse: BrowseModel
    let model: ExplorerModel
    let root: String
    let path: String
    @State private var full = false
    @State private var wrap = true
    @State private var render: DiffFileRender?
    @State private var rendered: String?
    @State private var viewer: ViewerRequest?

    var body: some View {
        let view = model.patch.flatMap { $0.root == root && $0.path == path ? $0 : nil }
        let result = view?.result
        let patch = result?.patch ?? ""
        VStack(spacing: 0) {
            if let result {
                HStack {
                    Text(signed(UInt64(result.additions), UInt64(result.deletions)) + (result.truncated ? " · truncated" : ""))
                        .font(VerdeTheme.mono(11)).foregroundStyle(VerdeTheme.muted)
                    Spacer()
                    Button(wrap ? "No wrap" : "Wrap") { wrap.toggle() }.font(VerdeTheme.ui(13))
                }
                .padding(.horizontal, 16).padding(.vertical, 4)
            }
            if view?.loading == true && result != nil { ProgressView().progressViewStyle(.linear) }
            Group {
                if model.unavailable {
                    ExplorerMessage(text: "Connect to a host to see this diff.")
                } else if view?.supported == false {
                    ExplorerMessage(text: explorerUpdateText)
                } else if let result {
                    if result.clean { ExplorerMessage(text: "No uncommitted changes in this file now.") }
                    else if result.binary { ExplorerMessage(text: "Binary file changed.") }
                    else if patch.isEmpty { ExplorerMessage(text: "No diff to show.") }
                    else if rendered != patch { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else {
                        switch render {
                        case .parsed(let parsed): PatchLines(model: parsed, wrap: wrap)
                        case .source(let source):
                            ScrollView([.vertical, .horizontal]) {
                                Text(source).font(selectableLineFont).fixedSize().padding(8)
                            }
                        case nil: ExplorerMessage(text: "No diff to show.")
                        }
                    }
                } else if let error = explorerErrorText(view?.error) {
                    ExplorerMessage(text: error) { model.openPatch(root: root, path: path, full: full) }
                } else {
                    ExplorerLoading(identifier: "patch-loading")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(VerdeTheme.background)
        .accessibilityIdentifier("patch-screen")
        .navigationTitle(basename(path))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ExplorerTitle(title: basename(path), subtitle: (path as NSString).deletingLastPathComponent)
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle("Full file", isOn: $full).toggleStyle(.button).accessibilityIdentifier("patch-full")
                Button("Open") {
                    var line: UInt64?
                    if case .parsed(let parsed) = render { line = firstNewLine(parsed) }
                    viewer = ViewerRequest(citation: FileCitation(path: trimmedRoot(root) + "/" + path, line: line))
                }
                .disabled(result?.status == "deleted")
            }
        }
        .task(id: full) { model.openPatch(root: root, path: path, full: full) }
        .task(id: patch) {
            guard !patch.isEmpty else { render = nil; rendered = nil; return }
            let next = await renderDiffFile(model, DiffRecord(text: patch, patch: patch), path: path)
            guard !Task.isCancelled else { return }
            render = next
            rendered = patch
        }
        .sheet(item: $viewer) { request in
            FileViewer(browse: browse, workspaceID: model.workspaceID, citation: request.citation)
        }
    }
}

/// First line of the new side worth opening the file at: the first addition, else the first line.
func firstNewLine(_ model: DiffFileModel) -> UInt64? {
    let rows = model.hunks.flatMap(\.rows)
    return rows.first { $0.kind == "add" && $0.newLine != nil }?.newLine ?? rows.first { $0.newLine != nil }?.newLine
}

private struct PatchLines: View {
    let model: DiffFileModel
    let wrap: Bool
    @Environment(\.lineSelection) private var selection

    private enum Item: Hashable {
        case header(Int)
        /// Hunk, row and 1-based position among all rows (the selection's unit).
        case line(Int, Int, Int)
    }

    private var items: [Item] {
        var out: [Item] = []
        var position = 0
        for (h, hunk) in model.hunks.enumerated() {
            out.append(.header(h))
            for r in hunk.rows.indices {
                position += 1
                out.append(.line(h, r, position))
            }
        }
        return out
    }

    var body: some View {
        let entries = items
        let charWidth = selectableCharWidth()
        let columns = model.hunks.flatMap(\.rows).map { $0.text.count }.max() ?? 0
        let contentWidth = CGFloat(columns + model.numberWidth * 2 + 4) * charWidth + 16
        let gutter = 8 + CGFloat(model.numberWidth * 2 + 4) * charWidth
        ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries, id: \.self) { item in
                    switch item {
                    case .header(let h):
                        Text(model.hunks[h].header).font(.caption2.monospaced()).foregroundStyle(VerdeTheme.muted)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(VerdeTheme.accent.opacity(0.08))
                    case .line(let h, let r, let at):
                        let row = model.hunks[h].rows[r]
                        Text(diffRowText(row, width: model.numberWidth)).font(selectableLineFont)
                            .fixedSize(horizontal: !wrap, vertical: true)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(selection?.contains(at) == true ? selectedLineColor : Color.clear)
                            .modifier(LineGestures(selection: selection, position: at, gutter: gutter))
                            .accessibilityIdentifier("patch-line")
                    }
                }
            }
            .frame(minWidth: wrap ? nil : contentWidth, alignment: .leading)
        }
        .onAppear { bind() }
        .onChange(of: model) { bind() }
        .onDisappear { selection?.source = nil }
    }

    private func bind() {
        let rows = model.hunks.flatMap(\.rows)
        selection?.source = { diffLines(rows, range: $0) }
    }
}

// MARK: - Files-tab file

/// A file opened from the Files tab: read through `workspace_file_read` by (root id, relative
/// path); `absolute` (from the root's host path, may be empty) names it for download and asking.
struct WorkspaceFileRoute: View {
    let browse: BrowseModel
    let workspaceID: String
    let root: String
    let path: String
    let absolute: String
    @State private var explorer: ExplorerModel

    init(browse: BrowseModel, workspaceID: String, root: String, path: String, absolute: String) {
        self.browse = browse
        self.workspaceID = workspaceID
        self.root = root
        self.path = path
        self.absolute = absolute
        _explorer = State(initialValue: ExplorerModel(browse: browse, workspaceID: workspaceID))
    }

    var body: some View {
        SelectionScope(browse: browse, explorer: explorer, path: absolute.isEmpty ? nil : absolute) {
            FileViewer(browse: browse, workspaceID: workspaceID, citation: FileCitation(path: absolute.isEmpty ? path : absolute),
                       reader: { [workspaceID, root, path] host in
                           try await host.readWorkspaceFile(workspaceID: workspaceID, root: root, path: path, limit: ViewerKind.of(path).limit)
                       },
                       embedded: true)
        }
        .modifier(ExplorerSync(browse: browse, model: explorer))
    }
}

// MARK: - Entry points

/// "Changes · Files" entry points (drawer and workspace screen); `workspace` names the target when ambiguous.
struct ExplorerLinks: View {
    let onChanges: () -> Void
    let onFiles: () -> Void
    var workspace: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            link("Changes", icon: "plusminus", id: "explorer-changes", action: onChanges)
            link("Files", icon: "folder", id: "explorer-files", action: onFiles)
            if let workspace {
                Text(workspace).font(VerdeTheme.ui(11)).foregroundStyle(VerdeTheme.subtle).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    private func link(_ title: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(VerdeTheme.ui(13))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(VerdeTheme.alternate, in: Capsule())
                .overlay(Capsule().stroke(VerdeTheme.border))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(VerdeTheme.text)
        .accessibilityIdentifier(id)
    }
}
