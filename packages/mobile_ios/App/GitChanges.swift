import SwiftUI

struct GitChatControls: View {
    let browse: BrowseModel
    let workspace: String
    let thread: String
    let model: GitChangesModel?
    private var controls: some View {
        Group {
            if let model {
                if (model.change?.files ?? 0) > 0 || model.ahead > 0 || model.notice != nil {
                    HStack(spacing: 0) {
                        Button {
                            Task {
                                if (model.change?.files ?? 0) == 0 && model.ahead > 0 { await model.push() }
                                else { await model.begin(push: model.defaultPush, quick: model.canCommit) }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(model.canCommit ? model.label : "Changes").lineLimit(1)
                                if model.change != nil { Text("\(model.mineCount)").monospacedDigit() }
                            }.padding(.horizontal, 8).padding(.vertical, 7)
                        }.disabled(model.busy)
                        if model.canCommit {
                            Divider().frame(height: 18)
                            Menu {
                                Button("Commit…") { Task { await model.begin(push: false) } }
                                Button("Commit & push") { Task { await model.begin(push: true, quick: true) } }
                                if model.ahead > 0 { Button("Push") { Task { await model.push() } } }
                                ForEach(model.rejectedRoots, id: \.self) { root in
                                    Button("Pull & push · \(URL(fileURLWithPath: root).lastPathComponent)") { Task { await model.pullPush(root) } }
                                }
                            } label: { Image(systemName: "chevron.down").padding(8).accessibilityLabel("Git actions") }
                            .disabled(model.busy)
                        }
                    }.font(VerdeTheme.ui(11, bold: true))
                        .foregroundStyle((model.change?.attention ?? 0) > 0 ? VerdeTheme.warning : VerdeTheme.text)
                        .modifier(ToolbarChrome())
                        .sheet(isPresented: Binding(get: { model.sheet }, set: { if $0 { model.sheet = true } else { model.dismissSheet() } })) { GitCommitSheet(model: model) }
                        .confirmationDialog("Push repository", isPresented: Binding(get: { model.choosePush }, set: { model.choosePush = $0 })) {
                            ForEach(model.repos.filter { $0.has_remote && $0.ahead > 0 }, id: \.root) { repo in
                                Button("\(repo.name) · ↑\(repo.ahead)") { Task { await model.push(root: repo.root) } }
                            }
                        }
                        .alert("Commit & push to \(model.mainBranch ?? "main")?", isPresented: Binding(get: { model.confirmMain }, set: { model.confirmMain = $0 })) {
                            Button("Abort", role: .cancel) {}
                            Button("Commit & push to \(model.mainBranch ?? "main")") { Task { await model.commit(push: true) } }
                            Button("Create branch & continue") { Task { await model.commit(push: true, newBranch: true) } }
                        } message: { Text("\(model.count) files · \(model.finalMessage.components(separatedBy: .newlines).first ?? "")") }

                }
            }
        }
    }
    var body: some View {
        controls
        .onChange(of: browse.session?.store.snapshots["operations"]) { _, _ in Task { await model?.refresh() } }
        .onChange(of: browse.session?.row?.phase) { _, _ in Task { await catalogChanged() } }
        .onChange(of: browse.session?.store.snapshots["workspaces"]) { _, _ in
            Task { await catalogChanged() }
        }
        .onChange(of: browse.session?.store.snapshots["git_review"]) { _, _ in Task { await model?.refresh() } }
        .onChange(of: browse.session?.store.snapshots["git_status"]) { _, _ in Task { await model?.refresh() } }
        .onChange(of: browse.session?.store.snapshots["git_summary:" + workspace]) { _, _ in Task { await model?.refresh() } }
    }
    private func catalogChanged() async {
        let workspaceValue = browse.session?.store.workspaces?.data?.items.first { $0.workspace_id == workspace }
        let available = workspaceValue?.threads.contains { $0.thread_id == thread } == true
        await model?.catalog(available: available, connected: browse.session?.row?.phase == "ready" && browse.session?.store.synced == true)
    }

}

struct GitCommitSheet: View {
    @Bindable var model: GitChangesModel
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Review this chat’s changes before committing.").foregroundStyle(VerdeTheme.muted)
                    if model.view?.loading == true { ProgressView("Reviewing changes…") }
                    if let review = model.review {
                        if review.turn_running { Label("Frozen snapshot · this chat is still working", systemImage: "snowflake").font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.warning) }
                        if !model.canCommit { Text("This device can review changes. Chat or Full access is required to commit.").font(VerdeTheme.ui(13)) }
                        ForEach(review.repos, id: \.root) { repo in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("BRANCH").font(VerdeTheme.ui(10, bold: true))
                                Label(repo.branch ?? "Detached HEAD", systemImage: "arrow.triangle.branch").font(VerdeTheme.ui(14, bold: true))
                                Text(repo.name).font(VerdeTheme.ui(12))
                                if repo.is_default_branch || ["main", "master"].contains(repo.branch ?? "") {
                                    Text("You're committing to the default branch")
                                        .font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.warning)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background((repo.is_default_branch || ["main", "master"].contains(repo.branch ?? "") ? VerdeTheme.warning : VerdeTheme.muted).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            ForEach(repo.files, id: \.path) { file in fileRow(repo, file) }
                        }
                        HStack {
                            Text("\(model.count) selected \(model.count == 1 ? "file" : "files")")
                            Spacer()
                            Text("+\(model.totals.0)").foregroundStyle(VerdeTheme.accent)
                            Text("−\(model.totals.1)").foregroundStyle(VerdeTheme.danger)
                        }.font(VerdeTheme.ui(12))
                        if model.canCommit {
                            HStack {
                                Text("Commit message").font(VerdeTheme.ui(13, bold: true))
                                Spacer()
                                if model.view?.message_state == "loading" { ProgressView() }
                                Button { Task { await model.generate() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Regenerate commit message").disabled(model.view?.message_state == "loading")
                            }
                            TextField(model.generated.isEmpty ? "Generate or enter a commit message" : model.generated, text: $model.message, axis: .vertical)
                                .lineLimit(2...5).padding(12).background(VerdeTheme.panel, in: RoundedRectangle(cornerRadius: 10))
                                .accessibilityIdentifier("git-commit-message")
                        }
                    }
                    if let notice = model.notice { Text(notice).font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.warning) }
                    if model.canCommit && model.view?.can_retry == true { Button("Check original operation") { Task { await model.retry() } } }
                }.padding(18)
            }
            .background(VerdeTheme.background)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    GitActionToastCard(model: model)
                    HStack {
                        Button("Cancel") { model.dismissSheet() }.disabled(model.busy)
                        Spacer()
                        if model.canCommit {
                            Button(model.actionTitle(.branch)) { Task { await model.submitSheet(.branch) } }.disabled(!model.canSubmit)
                        }
                    }
                    if model.canCommit {
                        HStack(spacing: 12) {
                            Spacer(minLength: 0)
                            if model.hasRemote {
                                Button(model.actionTitle(model.alternateAction)) { Task { await model.submitSheet(model.alternateAction) } }.disabled(!model.canSubmit)
                            }
                            Button(model.actionTitle(model.primaryAction)) { Task { await model.submitSheet(model.primaryAction) } }
                                .buttonStyle(.borderedProminent).disabled(!model.canSubmit)
                        }
                    }
                }.font(VerdeTheme.ui(12, bold: true)).padding().background(VerdeTheme.panel)
            }
            .navigationTitle("Commit changes").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button(model.allDiffsShown ? "Hide diffs" : "Show diffs") { Task { await model.toggleDiffs() } }.disabled(model.busy) }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .tint(VerdeTheme.accent).foregroundStyle(VerdeTheme.text).font(VerdeTheme.ui(14))
        .interactiveDismissDisabled(model.busy)
    }
    @ViewBuilder private func fileRow(_ repo: GitReviewRepo, _ file: GitReviewFile) -> some View {
        let key = GitFileKey(root: repo.root, path: file.path)
        let selected = model.selected.contains(key)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    if model.expanded.contains(key) { model.expanded.remove(key) } else { model.expanded.insert(key) }
                } label: {
                    Image(systemName: model.expanded.contains(key) ? "chevron.down" : "chevron.right").frame(width: 28, height: 40)
                }.accessibilityLabel("Show diffs for \(file.path)")
                Button { model.toggleFile(key) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selected ? (model.hunks[key] == nil ? "checkmark.square.fill" : "minus.square.fill") : "square")
                        VStack(alignment: .leading) {
                            Text(file.path).font(VerdeTheme.mono(11)).lineLimit(2)
                            if file.ownership != "mine" { Text(file.ownership.capitalized).font(VerdeTheme.ui(10)).foregroundStyle(VerdeTheme.warning) }
                        }
                        Spacer(minLength: 4)
                        Text("+\(file.additions)").foregroundStyle(VerdeTheme.accent)
                        Text("−\(file.deletions)").foregroundStyle(VerdeTheme.danger)
                    }.frame(maxWidth: .infinity, minHeight: 40).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!model.canCommit)
                    .accessibilityLabel("Select \(file.path)").accessibilityValue(selected ? (model.hunks[key] == nil ? "Selected" : "Partially selected") : "Not selected")
            }
            if model.expanded.contains(key) {
                if file.hunk_selectable && !file.preview_truncated && !file.binary {
                    ForEach(file.hunks, id: \.index) { hunk in
                        VStack(alignment: .leading) {
                            Toggle(hunk.header, isOn: Binding(get: {
                                model.selected.contains(key) && (model.hunks[key]?.contains(hunk.index) ?? true)
                            }, set: { model.toggleHunk(key, file: file, index: hunk.index, on: $0) })).disabled(!model.canCommit)
                            ScrollView(.horizontal) { Text(hunk.text).textSelection(.enabled) }
                        }.font(VerdeTheme.mono(10))
                    }
                } else {
                    Text("Can only be committed whole").font(VerdeTheme.ui(10)).foregroundStyle(VerdeTheme.muted)
                }
            }
            Divider().overlay(VerdeTheme.border)
        }.opacity(selected ? 1 : 0.65).disabled(model.busy)
    }

}

struct GitThreadDot: View {
    let browse: BrowseModel
    let workspace: String
    let thread: String
    private var summary: GitThreadSummary? {
        guard let data = browse.session?.store.snapshots["git_summary:" + workspace] else { return nil }
        return (try? JSONDecoder().decode(GitSummaryQuery.self, from: data))?.data?.threads.first { $0.local_thread_id == thread }
    }
    var body: some View {
        Group {
            if let summary, summary.files > 0 {
                Circle().fill(summary.attention > 0 ? VerdeTheme.warning : VerdeTheme.accent).frame(width: 6, height: 6).accessibilityLabel("\(summary.files) uncommitted files")
            }
        }.task(id: browse.hostID) {
            guard let session = browse.session else { return }
            await session.start()
            try? await session.host?.send(.git_summary_refresh(EventGitSummaryRefresh(now_ms: 0, wall_time_ms: 0, intent_id: UUID().uuidString, workspace_id: workspace)))
        }
    }
}

struct CommitSettingsSection: View {
    let browse: BrowseModel
    @State private var config: GitConfigCommitSnapshot?
    var body: some View {
        Section("Commit messages") {
            LabeledContent("Provider", value: ["auto": "Auto", "codex": "Codex", "claude": "Claude", "cursor": "Cursor", "opencode": "OpenCode"][config?.commit_message_provider ?? "auto"] ?? "Auto")
            LabeledContent("Model", value: config?.commit_message_model ?? "Default (provider’s fast model)")
            LabeledContent("Default action", value: config?.commit_default_action == "commit_and_push" ? "Commit & push" : "Commit")
            Text("Change on your computer").font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted)
        }.task {
            guard let host = browse.session?.host, let data = try? await host.query("git_review") else { return }
            config = (try? JSONDecoder().decode(GitReviewQuery.self, from: data))?.data?.config
        }
    }
}
