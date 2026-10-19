import SwiftUI
import UIKit

private func nowMs(_ date: Date = Date()) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

/// How close (in items) to the oldest loaded row before the next page is requested.
private let prefetchItems = 5
/// Distance from the bottom (points) that still counts as "reading the latest".
private let bottomSlack: CGFloat = 48
private let bottomID = "transcript-bottom"
private let headerID = "transcript-page-header"

/// D-06 transcript for one chat thread of the selected host. Bottom slot is the stop bar until the
/// I-06 composer. Message text is never logged.
struct TranscriptScreen: View {
    let browse: BrowseModel
    let workspaceID: String
    let threadID: String
    var onHosts: () -> Void = {}

    @State private var model: TranscriptModel?
    @State private var git: GitChangesModel?

    private var fallbackTitle: String? {
        browse.state.workspaces?.items.first { $0.workspace_id == workspaceID }?.threads.first { $0.thread_id == threadID }?.title
    }

    var body: some View {
        VStack(spacing: 0) {
            if let model {
                TranscriptBody(model: model, browse: browse, onHosts: onHosts)
            } else {
                Spacer()
            }
        }
        .environment(\.gitChangesModel, git)
        .overlay(alignment: .bottom) { if let git, !git.sheet { GitActionToastCard(model: git) } }
        .task(id: browse.hostID) {
            let next = GitChangesModel(browse: browse, workspace: workspaceID, thread: threadID)
            git = next; await next.start()
        }
        .background(VerdeTheme.background)
        .navigationTitle(model?.thread?.thread.title ?? fallbackTitle ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { GitChatControls(browse: browse, workspace: workspaceID, thread: threadID, model: git) }
            ToolbarItem(placement: .topBarTrailing) {
                ManageContainer(browse: browse) { manage in ThreadActions(workspace: workspaceID, thread: threadID, title: model?.thread?.thread.title ?? fallbackTitle ?? "Chat", manage: manage) }
            }
            if let summary = model?.thread?.thread {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        ProviderGlyph(provider: summary.provider)
                        VStack(alignment: .leading, spacing: 0) {
                        Text(summary.title.isEmpty ? "Chat" : summary.title) .font(VerdeTheme.ui(15, bold: true)).lineLimit(1)
                        Text([summary.provider, summary.model].compactMap { $0 }.joined(separator: " · "))
                             .font(VerdeTheme.ui(12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            if model == nil || model?.closed == true {
                let next = TranscriptModel(browse: browse, workspaceID: workspaceID, threadID: threadID)
                model = next
                next.start()
            }
            model?.setVisible(true)
            takeHandoffs()
        }
        // A notification for this chat while it is already on screen.
        .onReceive(NotificationCenter.default.publisher(for: .verdeChatHandoff)) { _ in takeHandoffs() }
        // Focus is released after a short delay (or by the model's owner check once it is gone),
        // so a quick return to this chat doesn't churn the core's focus slot.
        .onDisappear { model?.setVisible(false) }
    }
}

extension TranscriptScreen {
    /// "Ask agent" selections (file/diff viewers) and notification replies arrive as prompts;
    /// notification Approve/Deny as an approval hand-off.
    fileprivate func takeHandoffs() {
        guard let model else { return }
        if let prompt = PromptHandoff.take(host: browse.hostID, workspace: workspaceID, thread: threadID) {
            model.input.ask(prompt)
        }
        if let request = ApprovalHandoff.take(host: browse.hostID, workspace: workspaceID, thread: threadID) {
            Task { _ = await model.decideFromNotification(request) }
        }
    }
}

private struct CompactChatKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Denser transcript rows (smaller type, tighter spacing, flat tool rows) for the Companion sheet.
    var compactChat: Bool {
        get { self[CompactChatKey.self] }
        set { self[CompactChatKey.self] = newValue }
    }
}

/// Banner, transcript and composer for one thread; also the Companion sheet's conversation.
struct TranscriptBody: View {
    @State private var file: ViewerRequest?
    let model: TranscriptModel
    let browse: BrowseModel
    let onHosts: () -> Void
    /// Shown just above the composer.
    var accessory: AnyView? = nil
    /// The Companion sheet's single-row composer.
    var compactComposer: CompactComposer? = nil

    var body: some View {
        GeometryReader { geometry in
            let state = model.state
            VStack(spacing: 0) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if let banner = transcriptBanner(state, nowMs(context.date)) {
                        BannerCard(banner: banner, retry: {
                            if state.thread?.error != nil { model.retry() } else { Task { await browse.refresh() } }
                        }, hosts: onHosts)
                    }
                }
                ZStack {
                    if let placeholder = transcriptPlaceholder(state) {
                        PlaceholderView(kind: placeholder, retry: model.retry)
                    } else {
                        TranscriptList(model: model, page: state.thread?.page, approval: state.thread?.approval, turn: state.turn)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let accessory { accessory }
                ChatComposer(model: model.input, availableHeight: geometry.size.height, compact: compactComposer)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == citationScheme {
                if let citation = citation(from: url) { file = ViewerRequest(citation: citation) }
                return .handled
            }
            return safeLinkUrl(url.absoluteString) != nil ? .systemAction : .discarded
        })
        .sheet(item: $file) { request in FileViewer(browse: browse, workspaceID: model.workspaceID, citation: request.citation) }
    }
}

private struct BannerCard: View {
    let banner: Banner
    let retry: () -> Void
    let hosts: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(banner.text) .font(VerdeTheme.ui(14)).accessibilityIdentifier("transcriptBanner")
            if banner.busy { ProgressView().progressViewStyle(.linear) }
            switch banner.action {
            case .some(.retry): Button("Retry", action: retry)
            case .some(.hosts): Button("Open hosts", action: hosts)
            case nil: EmptyView()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(banner.error ? Color.red.opacity(0.12) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12).padding(.vertical, 4)
    }
}

private struct PlaceholderView: View {
    let kind: TranscriptPlaceholder
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            switch kind {
            case .loading:
                ProgressView()
                Text("Loading conversation…")
            case .missing: Text("This chat is no longer on the host.")
            case .offline: Text("This conversation will load when the host is reachable.")
            case .empty: Text("No messages yet.")
            case .error:
                Text("Couldn't load this conversation.")
                Button("Retry loading", action: retry).buttonStyle(.borderedProminent)
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .padding(32)
        .accessibilityIdentifier("transcript-placeholder")
    }
}

private struct BottomOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

/// Starts at the newest row; older pages prepend above without moving the reading position,
/// and new output is followed only while the reader is at the bottom.
private struct TranscriptList: View {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    let model: TranscriptModel
    let page: ChatPage?
    let approval: ChatApproval?
    let turn: ChatTurn?

    @State private var position: String?
    @State private var atBottom = true
    /// The reader wants the newest output. iOS 18 tracks it from scroll phases so late row
    /// measurements can be followed; iOS 17 mirrors `atBottom`.
    @State private var follow = true
    @State private var viewport: CGFloat = 0
    @State private var cardVisible = false
    @State private var settled = false
    @Environment(\.compactChat) private var compact

    /// Changes whenever the bottom of the transcript grows (new row, streaming delta, turn state).
    private func tailKey(_ items: [TranscriptItem]) -> String {
        var key = "\(items.count)|\(items.last?.id ?? "")"
        if case .message(let row) = items.last { key += "|\(row.body.utf16.count)" }
        if case .working(let turn, let waiting) = items.last { key += "|\(turn.status)|\(waiting)" }
        return key
    }

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                // Observe rows inside the deferred content instead of capturing
                // a snapshot that can stay on the optimistic Sending row.
                let items = model.items
                ZStack(alignment: .top) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: compact ? 4 : 8) {
                            PageHeader(page: page, loadOlder: { model.loadOlder(force: true) }).id(headerID)
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                TranscriptRow(item: item, model: model, turnStartedAt: turn?.started_at_ms)
                                    .id(item.id)
                                    .onAppear {
                                        if index < prefetchItems { model.loadOlder() }
                                        if case .approval = item { cardVisible = true }
                                    }
                                    .onDisappear { if case .approval = item { cardVisible = false } }
                            }
                            Color.clear.frame(height: 1).id(bottomID)
                                .background(GeometryReader { g in
                                    Color.clear.preference(key: BottomOffsetKey.self, value: g.frame(in: .named("transcript")).maxY)
                                })
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal, compact ? 10 : 12).padding(.vertical, compact ? 6 : 8)
                    }
                    .coordinateSpace(name: "transcript")
                    .scrollPosition(id: $position)
                    .modifier(BottomAnchor())
                    // Lazy rows start at estimated heights, so the initial bottom offset can land
                    // past the measured content and show blank until a scroll. Re-anchor once
                    // the rows are measured, then reveal.
                    .opacity(settled ? 1 : 0)
                    .task {
                        for _ in 0..<3 {
                            try? await Task.sleep(for: .milliseconds(30))
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                        settled = true
                    }
                    .accessibilityIdentifier("transcript-list")
                    .onPreferenceChange(BottomOffsetKey.self) { maxY in
                        let bottom = maxY - viewport <= bottomSlack
                        if bottom != atBottom { atBottom = bottom }
                        if #unavailable(iOS 18.0) { if bottom != follow { follow = bottom } }
                    }
                    .onChange(of: tailKey(items)) {
                        // `follow` still describes the layout before this change.
                        if follow { proxy.scrollTo(bottomID, anchor: .bottom) }
                    }
                    .modifier(TailFollower(follow: $follow) { proxy.scrollTo(bottomID, anchor: .bottom) })

                    ApprovalBanner(approval: approval, cardVisible: cardVisible, controller: model.approvals) {
                        guard let approval else { return }
                        follow = false
                        withAnimation(reducedMotion || AppearanceSettings.shared.reducedMotion ? nil : .default) { proxy.scrollTo("approval:\(approval.turn_id):\(approval.call_id)", anchor: .center) }
                    }

                    if !atBottom && !follow && !items.isEmpty {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Button {
                                    follow = true
                                    withAnimation(reducedMotion || AppearanceSettings.shared.reducedMotion ? nil : .default) { proxy.scrollTo(bottomID, anchor: .bottom) }
                                } label: {
                                    Image(systemName: "arrow.down").font(.body.weight(.semibold)).padding(12)
                                        .background(.regularMaterial, in: Circle()).shadow(radius: 2)
                                }
                                .accessibilityLabel("Jump to latest")
                                .padding(16)
                            }
                        }
                    }
                }
            }
            .onAppear { viewport = outer.size.height }
            .onChange(of: outer.size.height) { _, height in viewport = height }
        }
    }
}

/// Diffs and images render after a jump to the newest row, and a finished turn drops its working
/// row, so lazy rows settle to heights that differ from their estimates. That can leave the offset
/// in blank space past the content. While the reader follows the tail, re-anchor whenever the
/// settled geometry leaves the bottom; their own scroll stops following until they rest at the end.
private struct TailFollower: ViewModifier {
    @Binding var follow: Bool
    let anchor: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) { content.modifier(TailFollowerGeometry(follow: $follow, anchor: anchor)) } else { content }
    }
}

@available(iOS 18.0, *)
private struct TailFollowerGeometry: ViewModifier {
    @Binding var follow: Bool
    let anchor: () -> Void
    @State private var phase: ScrollPhase = .idle
    @State private var gap: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, next in
                phase = next
                if next == .interacting { follow = false }
                if next == .idle, !follow, abs(gap) <= bottomSlack { follow = true }
            }
            // Points between the current offset and the last reachable one; negative is past the end.
            .onScrollGeometryChange(for: CGFloat.self) { g in
                let last = max(-g.contentInsets.top, g.contentSize.height + g.contentInsets.bottom - g.containerSize.height)
                return last - g.contentOffset.y
            } action: { _, next in
                gap = next
                if follow, phase == .idle, abs(next) > bottomSlack { anchor() }
            }
    }
}

/// The initial offset is the newest row. iOS 18 limits the anchor to the initial offset so it
/// never fights `scrollPosition` when content changes; iOS 17 applies it to size changes too.
private struct BottomAnchor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.defaultScrollAnchor(.bottom, for: .initialOffset)
        } else {
            content.defaultScrollAnchor(.bottom)
        }
    }
}

private struct PageHeader: View {
    let page: ChatPage?
    let loadOlder: () -> Void

    var body: some View {
        HStack {
            Spacer()
            if let page {
                if page.loading {
                    ProgressView().controlSize(.small)
                    Text("Loading earlier messages…") .font(VerdeTheme.ui(13)).foregroundStyle(.secondary)
                } else if page.has_older {
                    Button("Load earlier messages", action: loadOlder) .font(VerdeTheme.ui(13))
                } else {
                    Text("Start of conversation") .font(VerdeTheme.ui(12)).foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(8)
    }
}

private struct StopBar: View {
    let state: TranscriptState
    let stop: () -> Void

    var body: some View {
        if state.turn != nil {
            HStack {
                Text(state.stopping ? "Stopping the current turn…" : "The agent is working.") .font(VerdeTheme.ui(14))
                Spacer()
                if state.stopping {
                    Button("Stopping…") {}.buttonStyle(.bordered).disabled(true)
                } else {
                    Button("Stop", action: stop).buttonStyle(.borderedProminent).tint(.red).disabled(!state.canStop)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.bar)
            .accessibilityIdentifier("stop-bar")
        }
    }
}

// MARK: - Rows

private struct TranscriptRow: View {
    let item: TranscriptItem
    let model: TranscriptModel
    let turnStartedAt: Int64?

    var body: some View {
        switch item {
        case .message(let row): MessageRow(row: row, model: model)
        case .tool(let row): ToolCard(row: row, child: false, disclosure: model.disclosure)
        case .toolGroup(let rows, let subagent):
            ToolGroupCard(id: item.id, rows: rows, subagent: subagent, turnStartedAt: turnStartedAt, disclosure: model.disclosure)
        case .think(let row): ThinkCard(row: row, model: model)
        case .diff(let row): DiffCard(id: row.id, text: row.body, source: model, disclosure: model.disclosure)
        case .notice(let row):
            if row.author == "git" {
                GitCommitNoticeCard(bodyText: row.body)
            } else { NoticeRow(row: row, model: model) }
        case .usage(_, let usage): UsageCard(usage: usage)
        case .childNotification(let row, let notifications):
            // A batched delivery stacks its rows tightly in one container with thin dividers.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(notifications.enumerated()), id: \.offset) { index, notification in
                    if index > 0 { Divider().overlay(VerdeTheme.border) }
                    ChildResultRow(row: row, index: index, notification: notification, model: model)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VerdeTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(VerdeTheme.border))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        case .working(let turn, let waiting): WorkingRow(turn: turn, waitingApproval: waiting)
        case .approval(let approval): ApprovalCard(approval: approval, controller: model.approvals, disclosure: model.disclosure)
        }
    }
}

private struct MessageRow: View {
    let row: ChatRow
    let model: TranscriptModel
    @Environment(\.compactChat) private var compact

    var body: some View {
        let mine = row.role == "user"
        // A parent agent's steer shows only its words, labelled apart from the human's turns.
        let steer = parentSteerBody(role: row.role, body: row.body)
        let shown = steer ?? row.body
        if steer == nil && isVoiceSpeaker(row.author) {
            VoiceMessageRow(row: row, mine: mine, compact: compact)
        } else if compact && steer == nil {
            CompactMessageRow(row: row, model: model, mine: mine, shown: shown)
        } else {
            regular(mine: mine, steer: steer, shown: shown)
        }
    }

    private func regular(mine: Bool, steer: String?, shown: String) -> some View {
        HStack {

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if steer != nil {
                        Label("Parent agent", systemImage: "arrow.turn.down.right").font(.caption.weight(.medium))
                            .foregroundStyle(VerdeTheme.accent)
                    } else {
                        Text(mine ? "You" : (row.author.isEmpty ? "Assistant" : row.author)).font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    if let label = deliveryLabel(row.delivery) {
                        Text(label) .font(VerdeTheme.ui(10)).foregroundStyle(row.delivery == "failed" ? Color.red : Color.secondary)
                    }
                }
                if !row.attachments.isEmpty {
                    AttachmentStrip(browse: model.browse, workspaceID: model.workspaceID, threadID: model.threadID, row: row, longest: 160)
                }
                if !shown.isEmpty {
                    // User text is verbatim (web parity); assistant output goes through the core AST.
                    if mine { Text(shown) .font(VerdeTheme.ui(15)).textSelection(.enabled) }
                    else { MarkdownText(text: streamTail(row), model: model) }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(mine ? VerdeTheme.user : VerdeTheme.assistant,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                if steer != nil { RoundedRectangle(cornerRadius: 12).stroke(VerdeTheme.accent.opacity(0.5)) }
            }
            .contextMenu { Button("Copy message") { UIPasteboard.general.string = shown } }
        }
        .accessibilityIdentifier("message-row")
    }
}

/// A live voice turn (consecutive lines grouped by `groupVoiceRows`): yours styled like a typed
/// message (a right-aligned bubble in the Companion sheet), the companion's as assistant text on
/// the left, each under a small mic and "<speaker> · voice".
private struct VoiceMessageRow: View {
    let row: ChatRow
    let mine: Bool
    let compact: Bool

    private var speaker: String {
        if mine { return "You" }
        let name = voiceSpeakerName(row.author)
        return name.isEmpty ? "Companion" : name
    }

    var body: some View {
        content
            .contextMenu { Button("Copy message") { UIPasteboard.general.string = row.body } }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(speaker + ", by voice: " + row.body)
            .accessibilityIdentifier("message-row")
    }

    private var label: some View {
        HStack(spacing: 4) {
            Image(systemName: "mic.fill").font(.system(size: compact ? 9 : 10)).accessibilityHidden(true)
            Text(speaker + " · voice").font(compact ? VerdeTheme.ui(11) : Font.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var content: some View {
        if compact && mine {
            HStack(alignment: .bottom, spacing: 0) {
                Spacer(minLength: 56)
                VStack(alignment: .trailing, spacing: 2) {
                    label
                    Text(row.body).font(VerdeTheme.ui(14)).textSelection(.enabled)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(VerdeTheme.user, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        } else if compact {
            VStack(alignment: .leading, spacing: 2) {
                label
                Text(row.body).font(VerdeTheme.ui(14)).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                label
                Text(row.body).font(VerdeTheme.ui(15)).textSelection(.enabled)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(mine ? VerdeTheme.user : VerdeTheme.assistant, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// Companion sheet: your messages as compact right-aligned bubbles, replies as plain text.
private struct CompactMessageRow: View {
    let row: ChatRow
    let model: TranscriptModel
    let mine: Bool
    let shown: String

    var body: some View {
        let delivery = deliveryLabel(row.delivery)
        HStack(alignment: .bottom, spacing: 0) {
            if mine { Spacer(minLength: 56) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                if !row.attachments.isEmpty {
                    AttachmentStrip(browse: model.browse, workspaceID: model.workspaceID, threadID: model.threadID, row: row,
                                    longest: 120, alignment: mine ? .trailing : .leading)
                }
                if !shown.isEmpty {
                    if mine {
                        Text(shown).font(VerdeTheme.ui(14)).textSelection(.enabled)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(VerdeTheme.user, in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        MarkdownText(text: streamTail(row), model: model)
                    }
                }
                if let delivery {
                    Text(delivery).font(VerdeTheme.ui(10)).foregroundStyle(row.delivery == "failed" ? Color.red : Color.secondary)
                }
            }
            .frame(maxWidth: mine ? nil : .infinity, alignment: mine ? .trailing : .leading)
            .contextMenu { Button("Copy message") { UIPasteboard.general.string = shown } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel((mine ? "You: " : (row.author.isEmpty ? "Reply: " : row.author + ": ")) + shown)
        .accessibilityIdentifier("message-row")
    }
}

private func childStatusColor(_ status: ChildStatus) -> Color {
    switch status {
    case .completed: return VerdeTheme.accent
    case .blocked, .waiting_approval: return VerdeTheme.warning
    case .failed: return VerdeTheme.danger
    default: return VerdeTheme.muted
    }
}

/// A linked child chat's result in the parent transcript: a compact row (status dot, child title,
/// status, chevron) with a one-line summary, expanding to the full reply and an Open chat action.
/// Rows the human must act on start expanded. The envelope's turn id and footer stay hidden.
private struct ChildResultRow: View {
    @Environment(\.openRoute) private var openRoute
    let row: ChatRow
    /// Position within a batched delivery.
    let index: Int
    let notification: ChildNotification
    let model: TranscriptModel

    var body: some View {
        let child = model.linkedThread(notification.childID)
        let title = childTitle(childID: notification.childID, knownTitle: child?.title)
        // Per message and child, held by the transcript model for this screen session.
        let key = "\(row.id):child:\(index)"
        let fallback = notification.status.expandedByDefault
        let expanded = model.disclosure.flag(key, fallback)
        let reply = notification.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 6) {
            Button { model.disclosure.toggle(key, fallback) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        StatusDot(color: childStatusColor(notification.status), label: notification.status.label)
                        Text(title).font(VerdeTheme.ui(15, bold: true)).lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(notification.status.label).font(VerdeTheme.ui(12))
                            .foregroundStyle(childStatusColor(notification.status)).lineLimit(1).fixedSize()
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    if !expanded {
                        let summary = childReplySummary(notification.reply)
                        Text(summary.isEmpty ? "No reply" : summary).font(VerdeTheme.ui(13))
                            .foregroundStyle(summary.isEmpty ? VerdeTheme.muted : Color.secondary)
                            .lineLimit(1).truncationMode(.tail).padding(.leading, 17)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(expanded ? "Collapse" : "Expand")
            if expanded {
                if reply.isEmpty {
                    Text("No reply").font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.muted)
                } else {
                    MarkdownText(text: reply, model: model)
                }
                HStack {
                    Spacer()
                    Button("Open chat") {
                        openRoute(.thread(workspace: child?.workspace_id ?? model.workspaceID, thread: notification.childID))
                    }
                    .accessibilityIdentifier("child-open-chat")
                }
                .font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.accent).buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu { Button("Copy reply") { UIPasteboard.general.string = notification.reply } }
        .accessibilityIdentifier("child-notification")
    }
}

private struct StatusDot: View {
    let color: Color
    let label: String
    var body: some View { Circle().fill(color).frame(width: 9, height: 9).accessibilityLabel(label) }
}

private func toolColor(_ row: ChatRow) -> Color {
    commandFailed(row) ? .red : commandRunning(row) ? .accentColor : .secondary
}

private let toolPreviewLines = 40

private struct ToolCard: View {
    let row: ChatRow
    let child: Bool
    let disclosure: DisclosureStore
    @Environment(\.compactChat) private var compact

    var body: some View {
        let key = "\(row.id):tool"
        let expanded = disclosure.flag(key, commandFailed(row))
        let all = disclosure.flag(key + ":all")
        VStack(alignment: .leading, spacing: 0) {
            Button { disclosure.toggle(key, commandFailed(row)) } label: {
                HStack(spacing: 8) {
                    StatusDot(color: toolColor(row), label: toolStatusLabel(row))
                    Text(row.author.isEmpty ? "Tool" : row.author).font(.subheadline.weight(.medium))
                    Text(commandPreview(row.body)) .font(VerdeTheme.ui(13)).foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(expanded ? "▾" : "▸").foregroundStyle(.secondary)
                }
                .font(compact ? VerdeTheme.ui(12) : nil)
                .padding(.horizontal, compact ? 2 : 12).padding(.vertical, compact ? 4 : 10)
                .frame(minHeight: compact ? 44 : nil)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Collapse" : "Expand")
            if expanded {
                let (shown, truncated) = all ? (row.body.trimmingCharacters(in: .whitespacesAndNewlines), false)
                    : leadingLines(row.body, toolPreviewLines)
                ScrollView(.horizontal) {
                    Text(shown).font(VerdeTheme.mono()).fixedSize().textSelection(.enabled).padding(.horizontal, 12)
                }
                HStack(spacing: 16) {
                    Button("Copy output") { UIPasteboard.general.string = row.body }
                    if truncated { Button("Show all \(countLines(row.body)) lines") { disclosure.setFlag(key + ":all", true) } }
                }
                 .font(VerdeTheme.ui(12))
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(compact ? Color.clear : child ? VerdeTheme.background : VerdeTheme.assistant,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if !compact { RoundedRectangle(cornerRadius: 10).stroke(commandRunning(row) ? Color.accentColor : VerdeTheme.border) }
        }
    }
}

private struct ToolGroupCard: View {
    let id: String
    let rows: [ChatRow]
    let subagent: Bool
    let turnStartedAt: Int64?
    let disclosure: DisclosureStore
    @Environment(\.compactChat) private var compact

    var body: some View {
        let counts = toolCounts(rows)
        let expanded = disclosure.flag(id, counts.failed > 0)
        VStack(alignment: .leading, spacing: 0) {
            Button { disclosure.toggle(id, counts.failed > 0) } label: {
                HStack(spacing: 8) {
                    StatusDot(color: counts.failed > 0 ? .red : counts.running > 0 ? .accentColor : .secondary,
                              label: counts.failed > 0 ? "Some failed" : counts.running > 0 ? "Running" : "Completed")
                    // Only a running group ticks; finished groups never schedule a timeline.
                    TimelineView(.periodic(from: .now, by: counts.running > 0 && turnStartedAt != nil ? 1 : 3600)) { context in
                        Text(toolGroupSummary(rows, subagent: subagent,
                                              elapsed: turnStartedAt.map { elapsedLabel($0, nowMs(context.date)) }))
                             .font(VerdeTheme.ui(13)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(expanded ? "▾" : "▸").foregroundStyle(.secondary)
                }
                .padding(.horizontal, compact ? 2 : 12).padding(.vertical, compact ? 4 : 12)
                .frame(minHeight: compact ? 44 : nil)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Collapse" : "Expand")
            if expanded {
                VStack(spacing: 6) {
                    ForEach(rows, id: \.id) { ToolCard(row: $0, child: true, disclosure: disclosure) }
                }
                .padding(.horizontal, compact ? 0 : 8).padding(.leading, compact ? 12 : 0).padding(.bottom, compact ? 2 : 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(compact ? Color.clear : VerdeTheme.assistant, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if !compact { RoundedRectangle(cornerRadius: 10).stroke(counts.running > 0 && counts.failed == 0 ? Color.accentColor : VerdeTheme.border) }
        }
    }
}

private struct ThinkCard: View {
    let row: ChatRow
    let model: TranscriptModel

    var body: some View {
        let key = "\(row.id):think"
        let expanded = model.disclosure.flag(key)
        VStack(alignment: .leading, spacing: 4) {
            Button { model.disclosure.toggle(key) } label: {
                HStack(spacing: 6) {
                    Text(expanded ? "▾" : "▸")
                    Text(commandRunning(row) ? "Thinking…" : "Thought")
                }
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Collapse" : "Expand")
            if expanded && !row.body.isEmpty {
                MarkdownText(text: streamTail(row), model: model).padding(.leading, 12).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NoticeRow: View {
    let row: ChatRow
    let model: TranscriptModel
    @Environment(\.compactChat) private var compact

    var body: some View {
        if isVoiceAuthor(row.author) {
            // Live conversation markers ("🎙 Live voice · …", "→ Asked Moss: …") as one quiet line.
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "waveform").font(.system(size: 10)).foregroundStyle(VerdeTheme.subtle).accessibilityHidden(true)
                Text(row.body).font(VerdeTheme.ui(compact ? 12 : 13)).foregroundStyle(VerdeTheme.muted).lineLimit(3)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2).padding(.horizontal, compact ? 0 : 4)
            .contextMenu { Button("Copy") { UIPasteboard.general.string = row.body } }
            .accessibilityElement(children: .combine)
        } else {
            regular
        }
    }

    private var regular: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !row.author.isEmpty { Text(row.author) .font(VerdeTheme.ui(10)).foregroundStyle(.secondary) }
            MarkdownText(text: row.body, model: model)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct UsageCard: View {
    let usage: ChatUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(usage.provider.prefix(1).uppercased() + usage.provider.dropFirst()) usage").font(.subheadline.weight(.semibold))
            ForEach(Array(usage.limits.enumerated()), id: \.offset) { _, limit in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(limit.label) .font(VerdeTheme.ui(13))
                        Spacer()
                        Text("\(limit.percent_left)% left") .font(VerdeTheme.ui(13))
                    }
                    ProgressView(value: Double(min(limit.percent_left, 100)), total: 100)
                        .accessibilityLabel("\(limit.label) \(limit.percent_left)% left")
                    if !limit.reset.isEmpty { Text(limit.reset) .font(VerdeTheme.ui(10)).foregroundStyle(.secondary) }
                }
            }
            ForEach(Array((usage.stats + usage.recent).enumerated()), id: \.offset) { _, stat in
                HStack {
                    Text(stat.label) .font(VerdeTheme.ui(13))
                    Spacer()
                    Text(stat.value) .font(VerdeTheme.ui(13))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VerdeTheme.assistant, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct WorkingRow: View {
    let turn: ChatTurn
    let waitingApproval: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                StatusPip(active: !waitingApproval, attention: waitingApproval)
                Text(workingLabel(turn, waitingApproval: waitingApproval,
                                  elapsed: turn.started_at_ms.map { elapsedLabel($0, nowMs(context.date)) }))
                    .font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 4).padding(.vertical, 4)
        }
        .accessibilityIdentifier("working-row")
    }
}
