import SwiftUI

struct GitChatControls: View {
    let browse: BrowseModel
    let workspace: String
    let thread: String
    @State private var model: GitChangesModel?
    var body: some View {
        Group {
            if let model {
                if (model.change?.files ?? 0) > 0 || model.ahead > 0 || model.notice != nil {
                    HStack(spacing: 0) {
                        Button {
                            Task {
                                if (model.change?.files ?? 0) == 0 && model.ahead > 0 { await model.push() }
                                else { await model.begin(push: model.defaultPush, quick: model.defaultPush && model.canCommit) }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(model.canCommit ? model.label : "Changes").lineLimit(1)
                                if let count = model.change?.files, count > 0 { Text("\(count)").monospacedDigit() }
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
                        .background(VerdeTheme.panel, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(VerdeTheme.border))
                        .sheet(isPresented: Binding(get: { model.sheet }, set: { model.sheet = $0 })) { GitCommitSheet(model: model) }
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
                        .popover(isPresented: Binding(get: { model.notice != nil && !model.sheet && !model.confirmMain }, set: { if !$0 { model.notice = nil } })) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(model.notice ?? "")
                                if model.canCommit && model.view?.can_retry == true { Button("Check original operation") { Task { await model.retry() } } }
                                if model.canCommit { ForEach(model.rejectedRoots, id: \.self) { root in Button("Pull & push") { Task { await model.pullPush(root) } } } }
                                Button("Dismiss") { model.notice = nil }
                            }.padding().presentationCompactAdaptation(.popover)
                        }
                }
            }
        }
        .task(id: browse.hostID) {
            let next = GitChangesModel(browse: browse, workspace: workspace, thread: thread)
            model = next; await next.start()
        }
        .onChange(of: browse.session?.store.snapshots["git_review"]) { _, _ in Task { await model?.refresh() } }
        .onChange(of: browse.session?.store.snapshots["git_status"]) { _, _ in Task { await model?.refresh() } }
        .onChange(of: browse.session?.store.snapshots["git_summary:" + workspace]) { _, _ in Task { await model?.refresh() } }
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
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background((repo.is_default_branch || ["main", "master"].contains(repo.branch ?? "") ? VerdeTheme.warning : VerdeTheme.muted).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            ForEach(repo.files, id: \.path) { file in fileRow(repo, file) }
                        }
                        HStack {
                            Text("\(model.count) selected files")
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
                HStack(spacing: 12) {
                    Button("Cancel") { model.sheet = false }
                    Spacer(minLength: 0)
                    if model.canCommit {
                        Button("Commit on new branch") { Task { await model.commit(newBranch: true) } }.disabled(!model.canSubmit)
                        Button("Commit") { Task { await model.commit() } }.buttonStyle(.borderedProminent).disabled(!model.canSubmit)
                    }
                }.font(VerdeTheme.ui(12, bold: true)).padding().background(VerdeTheme.panel)
            }
            .navigationTitle("Commit changes").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button(model.edit ? "Done" : "Edit") { model.edit.toggle() }.disabled(model.busy) }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .tint(VerdeTheme.accent).foregroundStyle(VerdeTheme.text).font(VerdeTheme.ui(14))
        .interactiveDismissDisabled(model.busy)
    }
    @ViewBuilder private func fileRow(_ repo: GitReviewRepo, _ file: GitReviewFile) -> some View {
        let key = GitFileKey(root: repo.root, path: file.path)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if model.edit {
                    Button {
                        if model.selected.contains(key) { model.selected.remove(key); model.hunks[key] = nil } else { model.selected.insert(key) }
                    } label: { Image(systemName: model.selected.contains(key) ? "checkmark.square.fill" : "square").frame(width: 26, height: 26) }
                    .accessibilityLabel("Select \(file.path)").accessibilityValue(model.selected.contains(key) ? "Selected" : "Not selected")
                }
                Text(file.path).font(VerdeTheme.mono(11)).lineLimit(2)
                Spacer(minLength: 4)
                Text("+\(file.additions)").foregroundStyle(VerdeTheme.accent)
                Text("−\(file.deletions)").foregroundStyle(VerdeTheme.danger)
            }
            if file.ownership != "mine" { Text(file.ownership.capitalized).font(VerdeTheme.ui(10)).foregroundStyle(VerdeTheme.warning) }
            if model.edit && model.selected.contains(key) && file.hunk_selectable && !file.preview_truncated && !file.binary {
                ForEach(file.hunks, id: \.index) { hunk in
                    DisclosureGroup {
                        ScrollView(.horizontal) { Text(hunk.text).font(VerdeTheme.mono(10)).textSelection(.enabled) }
                    } label: {
                        Toggle(hunk.header, isOn: Binding(get: { model.hunks[key]?.contains(hunk.index) ?? true }, set: { on in
                            var selected = model.hunks[key] ?? Set(file.hunks.map(\.index))
                            if on { selected.insert(hunk.index) } else { selected.remove(hunk.index) }
                            if selected.isEmpty { model.selected.remove(key); model.hunks[key] = nil }
                            else { model.hunks[key] = selected.count == file.hunks.count ? nil : selected }
                        })).font(VerdeTheme.mono(10))
                    }
                }
            }
            if file.preview_truncated { Text("Preview limited · select the whole file").font(VerdeTheme.ui(10)).foregroundStyle(VerdeTheme.muted) }
            Divider().overlay(VerdeTheme.border)
        }.opacity(file.ownership == "mine" ? 1 : 0.65).disabled(model.busy)
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
        }
        // Rows only read cached summaries. Opening a chat subscribes its workspace
        // through GitChangesModel.start; a drawer must not scan every workspace.
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
