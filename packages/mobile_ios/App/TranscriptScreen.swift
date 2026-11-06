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
    @Environment(\.adaptive) private var adaptive

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
        .background {
            if !adaptive.inlineGit { GitChatControls(browse: browse, workspace: workspaceID, thread: threadID, model: git) }
        }
        .overlay(alignment: .bottom) { if let git, !git.sheet { GitActionToastCard(model: git) } }
        .task(id: browse.hostID) {
            let next = GitChangesModel(browse: browse, workspace: workspaceID, thread: threadID)
            git = next; await next.start()
        }
        .background(VerdeTheme.background)
        .navigationTitle(model?.thread?.thread.title ?? fallbackTitle ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // S10: [back] [drawer] title … [companion] [⋯]. Only wide windows add the Commit button;
            // phones reach Git through ⋯ and keep its sheets mounted in the background.
            if adaptive.inlineGit {
                ToolbarItem(placement: .topBarTrailing) { GitChatControls(browse: browse, workspace: workspaceID, thread: threadID, model: git) }
            }
            ToolbarItem(placement: .topBarTrailing) { CompanionHeaderButton(workspace: workspaceID, thread: threadID) }
            ToolbarItem(placement: .topBarTrailing) {
                ManageContainer(browse: browse) { manage in ThreadActions(workspace: workspaceID, thread: threadID, title: model?.thread?.thread.title ?? fallbackTitle ?? "Chat", manage: manage, git: git) }
            }
            if let summary = model?.thread?.thread {
                ToolbarItem(placement: .principal) {
                    // S37: the title takes the bar's whole middle; the provider glyph moves to the
                    // subtitle line and the title shrinks a little before it truncates.
                    VStack(alignment: .center, spacing: 0) {
                        Text(summary.title.isEmpty ? "Chat" : summary.title).font(VerdeTheme.ui(15, bold: true))
                            .lineLimit(1).minimumScaleFactor(0.85)
                        HStack(spacing: 4) {
                            ProviderGlyph(provider: summary.provider, size: 12)
                            Text(rowSubtitle([providerDisplayName(summary.provider), summary.model]) ?? "")
                                .font(VerdeTheme.ui(12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
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

/// Resigns whichever field has the keyboard.
@MainActor func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

private struct CompactChatKey: EnvironmentKey { static let defaultValue = false }
private struct CompanionSpeakerKey: EnvironmentKey { static let defaultValue: String? = nil }

extension EnvironmentValues {
    /// Denser transcript rows (smaller type, tighter spacing, flat tool rows) for the Companion sheet.
    var compactChat: Bool {
        get { self[CompactChatKey.self] }
        set { self[CompactChatKey.self] = newValue }
    }
    /// The companion's name in its own conversation: its replies are spoken as "Sprout", not by
    /// the brain's provider ("Codex").
    var companionSpeaker: String? {
        get { self[CompanionSpeakerKey.self] }
        set { self[CompanionSpeakerKey.self] = newValue }
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
    @Environment(\.adaptive) private var adaptive

    var body: some View {
        GeometryReader { geometry in
            let state = model.state
            VStack(spacing: 0) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if let banner = transcriptBanner(state, nowMs(context.date), sendError: model.input.view?.error, sendNotice: model.input.notice) {
                        BannerCard(banner: banner, retry: {
                            if state.thread?.error != nil { model.retry() } else { Task { await browse.refresh() } }
                        }, hosts: onHosts)
                    }
                }
                ZStack {
                    if let placeholder = transcriptPlaceholder(state) {
                        PlaceholderView(kind: placeholder, retry: model.retry)
                    } else {
                        TranscriptList(model: model, page: state.thread?.page, approval: state.thread?.approval, turn: state.turn,
                                       background: state.thread?.background_tasks ?? [])
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let accessory { accessory }
                ChatComposer(model: model.input, availableHeight: geometry.size.height, availableWidth: geometry.size.width, compact: compactComposer)
                    // Lines up with the transcript's capped text (the card has 8 points of margin).
                    .frame(maxWidth: adaptive.tier.wide && compactComposer == nil ? transcriptTextWidth + 16 : .infinity)
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
            case .some(.retry): Button(action: retry) { Text("Retry").font(VerdeTheme.ui(14, bold: true)).minTarget() }
            case .some(.hosts): Button(action: hosts) { Text("Open hosts").font(VerdeTheme.ui(14, bold: true)).minTarget() }
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
                Button("Retry loading", action: retry).buttonStyle(PrimaryButtonStyle(fullWidth: false))
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .padding(32)
        .accessibilityIdentifier("transcript-placeholder")
    }
}

/// Reading the newest output, with hysteresis: it starts within `bottomSlack` of the end and only
/// stops past `bottomRelease`, so a bar appearing or a row re-measuring can't flip it each pass.
func transcriptAtBottom(_ current: Bool, gap: CGFloat) -> Bool {
    if gap <= bottomSlack { return true }
    if gap > bottomRelease { return false }
    return current
}

/// Past this distance from the end the reader has left the newest output.
let bottomRelease: CGFloat = 120

/// The newest rows include your own message that is still on its way (just sent).
func ownSendAtTail(_ items: [TranscriptItem]) -> Bool {
    items.suffix(3).contains { item in
        if case .message(let row) = item { return row.role == "user" && (row.delivery == "optimistic" || row.delivery == "failed") }
        return false
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
    /// Running background tasks, pinned above the composer (U1).
    var background: [ChatBackgroundTask] = []

    @State private var position: String?
    @State private var atBottom = true
    /// The reader wants the newest output. iOS 18 tracks it from scroll phases so late row
    /// measurements can be followed; iOS 17 mirrors `atBottom`.
    @State private var follow = true
    @State private var viewport: CGFloat = 0
    @State private var cardVisible = false
    @State private var settled = false
    /// "Latest" is shown; follows `wantsLatest` after a short settle so a resize can't flip it
    /// back and forth within one layout pass.
    @State private var showLatest = false
    @Environment(\.compactChat) private var compact
    @Environment(\.adaptive) private var adaptive

    /// Changes whenever the bottom of the transcript grows (new row, streaming delta, turn state).
    private func tailKey(_ items: [TranscriptItem]) -> String {
        var key = "\(items.count)|\(items.last?.id ?? "")"
        if case .message(let row) = items.last { key += "|\(row.body.utf16.count)" }
        if case .working(let turn, let waiting) = items.last { key += "|\(turn.status)|\(waiting)" }
        return key
    }

    private var wantsLatest: Bool { !atBottom && !follow && !model.items.isEmpty }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { outer in list(proxy: proxy, outer: outer) }
        }
        .task(id: wantsLatest) {
            guard wantsLatest else { showLatest = false; return }
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled && wantsLatest { showLatest = true }
        }
    }

    /// The background bar's measured height: the room kept under the last row so the bar, which
    /// overlays the list's bottom edge, never covers a row (I14-1). Only the content's padding
    /// depends on it, never the bar itself, so it can't feed back into its own layout.
    @State private var backgroundBarHeight: CGFloat = 52

    /// I14-2: scrolls the task's row into view and flashes it.
    private func showBackground(_ task: ChatBackgroundTask, _ proxy: ScrollViewProxy) {
        follow = false
        withAnimation(reducedMotion || AppearanceSettings.shared.reducedMotion ? nil : .default) { proxy.scrollTo("b:" + task.row_id, anchor: .center) }
        let key = backgroundHighlightKey(task.row_id)
        model.disclosure.setFlag(key, true)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(2500))
            model.disclosure.setFlag(key, false)
        }
    }

    private func jumpToLatest(_ proxy: ScrollViewProxy) {
        follow = true
        showLatest = false
        withAnimation(reducedMotion || AppearanceSettings.shared.reducedMotion ? nil : .default) { proxy.scrollTo(bottomID, anchor: .bottom) }
    }

    @ViewBuilder private func rows(_ items: [TranscriptItem], lazy: Bool) -> some View {
        PageHeader(page: page, loadOlder: { model.loadOlder(force: true) }).id(headerID)
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            TranscriptRow(item: item, model: model, turnStartedAt: turn?.started_at_ms)
                .frame(maxWidth: (compact ? nil : transcriptRowCap(item, tier: adaptive.tier)) ?? .infinity, alignment: .leading)
                .frame(maxWidth: .infinity)
                .id(item.id)
                .onAppear {
                    // An eager stack shows every row at once; it pages from the scroll position instead.
                    if lazy && index < prefetchItems { model.loadOlder() }
                    if case .approval = item { cardVisible = true }
                }
                .onDisappear { if case .approval = item { cardVisible = false } }
        }
        // The background bar's room sits above the bottom marker, so "scroll to the bottom" leaves
        // the last row clear of the bar (I14-1).
        if !background.isEmpty { Color.clear.frame(height: backgroundBarHeight + 8).accessibilityHidden(true) }
        Color.clear.frame(height: 1).id(bottomID)
            .background(GeometryReader { g in
                Color.clear.preference(key: BottomOffsetKey.self, value: g.frame(in: .named("transcript")).maxY)
            })
    }

    private func list(proxy: ScrollViewProxy, outer: GeometryProxy) -> some View {
                // Observe rows inside the deferred content instead of capturing
                // a snapshot that can stay on the optimistic Sending row.
                let items = model.items
                return ZStack(alignment: .top) {
                    ScrollView {
                        // I6-1: a lazy stack re-estimates rows it hasn't measured whenever content
                        // above the viewport changes height (a tool group collapsing, the composer
                        // resizing) and could loop for minutes placing them. Ordinary chats are laid
                        // out eagerly, so every height is known; only very long ones stay lazy.
                        if items.count <= eagerTranscriptLimit {
                            VStack(alignment: .leading, spacing: compact ? 4 : 8) { rows(items, lazy: false) }
                                .scrollTargetLayout()
                                .padding(.horizontal, compact ? 10 : 12).padding(.vertical, compact ? 6 : 8)
                        } else {
                            LazyVStack(alignment: .leading, spacing: compact ? 4 : 8) { rows(items, lazy: true) }
                                .scrollTargetLayout()
                                .padding(.horizontal, compact ? 10 : 12).padding(.vertical, compact ? 6 : 8)
                        }
                    }
                    .coordinateSpace(name: "transcript")
                    // A bar over the bottom edge (I2-1), drawn as an overlay so it never changes the
                    // scroll view's size or insets: resizing the lazy transcript while scrolled up
                    // made its layout loop (I3-1). It only shows away from the newest output.
                    .overlay(alignment: .bottom) {
                        VStack(spacing: 0) {
                            if showLatest { LatestStrip { jumpToLatest(proxy) } }
                            // U1: running tasks above the composer; a tap shows the task's row.
                            BackgroundTasksBar(tasks: background) { task in showBackground(task, proxy) }
                                .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { height in
                                    guard height > 0 && abs(height - backgroundBarHeight) > 1 else { return }
                                    backgroundBarHeight = height
                                    if follow { proxy.scrollTo(bottomID, anchor: .bottom) }
                                }
                        }
                    }
                    // Scrolling or tapping the transcript puts the keyboard away (I-KB); the tap is
                    // simultaneous, so rows, links and buttons still get it.
                    .scrollDismissesKeyboard(.interactively)
                    .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
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
                    // A resize reflows every row; keep the reader on the row they were reading.
                    .onChange(of: outer.size.width) {
                        if follow { proxy.scrollTo(bottomID, anchor: .bottom) }
                        else if let position { proxy.scrollTo(position, anchor: .top) }
                    }
                    .onPreferenceChange(BottomOffsetKey.self) { maxY in
                        // iOS 18 reads the scroll geometry instead (TailFollower).
                        if #available(iOS 18.0, *) { return }
                        let bottom = transcriptAtBottom(atBottom, gap: maxY - viewport)
                        if bottom != atBottom { atBottom = bottom }
                        if bottom != follow { follow = bottom }
                    }
                    // Your own send always follows to the bottom (I8-4), now and once the new rows
                    // (or a failure) have landed.
                    .onChange(of: model.ownSends) {
                        follow = true
                        proxy.scrollTo(bottomID, anchor: .bottom)
                        Task { @MainActor in
                            for delay in [300, 900] {
                                try? await Task.sleep(for: .milliseconds(delay))
                                if follow { proxy.scrollTo(bottomID, anchor: .bottom) }
                            }
                        }
                    }
                    .onChange(of: tailKey(items)) {
                        // Your own message always brings the transcript to the new turn (I3-6).
                        if ownSendAtTail(items) && !follow { follow = true }
                        // `follow` still describes the layout before this change.
                        if follow { proxy.scrollTo(bottomID, anchor: .bottom) }
                    }
                    .modifier(TailFollower(follow: $follow, atBottom: $atBottom, output: tailKey(items),
                                           nearTop: { model.loadOlder() }) { proxy.scrollTo(bottomID, anchor: .bottom) })

                    ApprovalBanner(approval: approval, cardVisible: cardVisible, controller: model.approvals) {
                        guard let approval else { return }
                        follow = false
                        withAnimation(reducedMotion || AppearanceSettings.shared.reducedMotion ? nil : .default) { proxy.scrollTo("approval:\(approval.turn_id):\(approval.call_id)", anchor: .center) }
                    }

                }
            .onAppear { viewport = outer.size.height }
            .onChange(of: outer.size.height) { old, height in
                viewport = height
                // The keyboard, the composer growing or an attachment strip: a reader at the
                // newest output stays there (I6-2). A reader scrolled up keeps their offset; a
                // programmatic jump there moved the transcript and fed the layout loop.
                if follow && abs(height - old) > 1 { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
    }
}

/// "Latest" under the transcript while the reader is scrolled up; a tap follows the newest output.
private struct LatestStrip: View {
    let jump: () -> Void

    var body: some View {
        Button(action: jump) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down").font(.system(size: 12, weight: .semibold))
                Text("Latest").font(VerdeTheme.ui(13, bold: true))
            }
            .foregroundStyle(VerdeTheme.accent)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(VerdeTheme.panel)
        .overlay(alignment: .top) { Rectangle().fill(VerdeTheme.border).frame(height: 1) }
        .accessibilityLabel("Jump to latest")
        .accessibilityIdentifier("transcript-latest")
    }
}

/// Diffs and images render after a jump to the newest row, and a finished turn drops its working
/// row, so lazy rows settle to heights that differ from their estimates. That can leave the offset
/// in blank space past the content. While the reader follows the tail, re-anchor once the geometry
/// has been quiet for a moment; their own scroll stops following until they rest at the end.
///
/// A jump to the bottom realizes rows at estimated heights, so it moves the geometry again. Anchoring
/// on every change turned that into a loop that threw the transcript around (worst while the
/// composer was resized), so re-anchors wait for the geometry to settle and are capped per output.
private struct TailFollower: ViewModifier {
    @Binding var follow: Bool
    @Binding var atBottom: Bool
    /// Changes with new output; restores the re-anchor allowance.
    let output: String
    /// The reader reached the oldest loaded rows (pages the eager stack).
    var nearTop: () -> Void = {}
    let anchor: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.modifier(TailFollowerGeometry(follow: $follow, atBottom: $atBottom, output: output, nearTop: nearTop, anchor: anchor))
        } else { content }
    }
}

/// Re-anchors allowed per output before following gives up; the reader or new output resets it.
private let tailReanchors = 3
/// Quiet time before a settled geometry is re-anchored.
private let tailSettle: Duration = .milliseconds(150)
/// Chats up to this many rows are laid out eagerly (I6-1).
let eagerTranscriptLimit = 160

/// The scroll geometry the follower reacts to, coarse enough that sub-point re-layouts don't
/// count as changes.
struct TailGeometry: Equatable {
    var gap: CGFloat
    var container: CGFloat
    var nearTop: Bool

    init(offset: CGFloat, insetTop: CGFloat, insetBottom: CGFloat, content: CGFloat, container: CGFloat) {
        let last = max(-insetTop, content + insetBottom - container)
        gap = ((last - offset) / 4).rounded() * 4
        self.container = container.rounded()
        nearTop = offset + insetTop < 400
    }
}

/// Bookkeeping that must not re-render the transcript: writing it on every scroll frame (as
/// `@State`) re-evaluated the scroll view inside its own layout pass.
@available(iOS 18.0, *)
private final class TailState {
    var phase: ScrollPhase = .idle
    var geometry: TailGeometry?
    var allowance = tailReanchors
    var pending: Task<Void, Never>?
}

@available(iOS 18.0, *)
private struct TailFollowerGeometry: ViewModifier {
    @Binding var follow: Bool
    @Binding var atBottom: Bool
    let output: String
    let nearTop: () -> Void
    let anchor: () -> Void
    @State private var tail = TailState()

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, next in
                tail.phase = next
                // Dragging the transcript puts the keyboard away (I3-5).
                if next == .interacting { if follow { follow = false }; tail.pending?.cancel(); dismissKeyboard() }
                if next == .idle, !follow, abs(tail.geometry?.gap ?? 0) <= bottomSlack { follow = true }
            }
            .onScrollGeometryChange(for: TailGeometry.self) { g in
                TailGeometry(offset: g.contentOffset.y, insetTop: g.contentInsets.top, insetBottom: g.contentInsets.bottom,
                             content: g.contentSize.height, container: g.containerSize.height)
            } action: { previous, next in
                tail.geometry = next
                // A resized container (keyboard, composer) is new geometry to follow, not a retry.
                if previous.container != next.container { tail.allowance = tailReanchors }
                if next.nearTop && !previous.nearTop && !follow { nearTop() }
                let bottom = transcriptAtBottom(atBottom, gap: next.gap)
                if bottom != atBottom { atBottom = bottom }
                schedule()
            }
            .onChange(of: follow) { _, following in
                if following { tail.allowance = tailReanchors } else { tail.pending?.cancel() }
            }
            .onChange(of: output) { tail.allowance = tailReanchors }
            .onDisappear { tail.pending?.cancel() }
    }

    /// Restarts the settle timer on each change, so a burst of layout passes anchors once. When the
    /// allowance is spent the transcript stops following and shows Jump to latest instead.
    private func schedule() {
        tail.pending?.cancel()
        guard follow, tail.phase == .idle, abs(tail.geometry?.gap ?? 0) > bottomSlack else { return }
        let tail = tail
        tail.pending = Task { @MainActor in
            try? await Task.sleep(for: tailSettle)
            guard !Task.isCancelled, follow, tail.phase == .idle, abs(tail.geometry?.gap ?? 0) > bottomSlack else { return }
            if tail.allowance > 0 { tail.allowance -= 1; anchor() } else { follow = false }
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
                    Button(action: loadOlder) {
                        Text("Load earlier messages").font(VerdeTheme.ui(13, bold: true)).frame(minHeight: 44).contentShape(Rectangle())
                    }
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
                    Button("Stop", action: stop).buttonStyle(PrimaryButtonStyle(fullWidth: false)).tint(.red).disabled(!state.canStop)
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
        case .tool(let row): ToolCard(row: row, child: false, disclosure: model.disclosure, source: model)
        case .toolGroup(let rows, let subagent):
            ToolGroupCard(id: item.id, rows: rows, subagent: subagent, turnStartedAt: turnStartedAt, disclosure: model.disclosure, source: model)
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
        case .background(let rows): BackgroundTaskCard(rows: rows, disclosure: model.disclosure)
        }
    }
}

private struct MessageRow: View {
    let row: ChatRow
    let model: TranscriptModel
    @Environment(\.compactChat) private var compact
    @State private var selecting = false

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
                    if let label = deliveryLabel(row.delivery), !(mine && row.delivery == "failed") {
                        Text(label) .font(VerdeTheme.ui(10)).foregroundStyle(row.delivery == "failed" ? VerdeTheme.danger : Color.secondary)
                    }
                }
                if !row.attachments.isEmpty {
                    AttachmentStrip(browse: model.browse, workspaceID: model.workspaceID, threadID: model.threadID, row: row, longest: 160)
                }
                if !shown.isEmpty {
                    // Prompts and replies both go through the core's markdown AST (desktop parity).
                    MarkdownText(text: mine ? shown : streamTail(row), model: model)
                }
                if mine && row.delivery == "failed" { FailedSendBar(row: row, model: model) }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(mine ? VerdeTheme.user : VerdeTheme.assistant,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                if steer != nil { RoundedRectangle(cornerRadius: 12).stroke(VerdeTheme.accent.opacity(0.5)) }
            }
            .contextMenu { MessageMenu(text: shown, model: model, selecting: $selecting) }
        }
        .accessibilityIdentifier("message-row")
        .sheet(isPresented: $selecting) { SelectTextSheet(text: renderedPlainText(shown, model: model)) }
    }
}

/// A message that didn't send (S19): why, then Retry (sends the kept draft again) and Remove.
private struct FailedSendBar: View {
    let row: ChatRow
    let model: TranscriptModel

    var body: some View {
        let reason = model.input.notice ?? model.input.view?.error?.message ?? model.thread?.error?.message
        VStack(alignment: .leading, spacing: 4) {
            Label(reason.map { "Not sent. \($0)" } ?? "Not sent.", systemImage: "exclamationmark.circle")
                .font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.danger)
            HStack(spacing: 8) {
                Button("Retry") { model.input.submit() }
                    .buttonStyle(TonalButtonStyle(fullWidth: false)).disabled(!model.input.canSubmit)
                Button("Remove", role: .destructive) { model.removeFailed(row.id); model.input.discardDraft() }
                    .buttonStyle(TonalButtonStyle(destructive: true, fullWidth: false))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("failed-send")
    }
}

/// A message's rendered text: the core's markdown as plain text, else the source.
@MainActor func renderedPlainText(_ text: String, model: TranscriptModel) -> String {
    guard let blocks = model.cachedMarkdown(text)?.value else { return text }
    return markdownPlainText(blocks)
}

/// Long-press on a message: copy it, or select part of its rendered text.
private struct MessageMenu: View {
    let text: String
    let model: TranscriptModel
    @Binding var selecting: Bool

    var body: some View {
        Button { UIPasteboard.general.string = renderedPlainText(text, model: model) } label: { Label("Copy text", systemImage: "doc.on.doc") }
        Button { UIPasteboard.general.string = text } label: { Label("Copy as Markdown", systemImage: "chevron.left.forwardslash.chevron.right") }
        Button { selecting = true } label: { Label("Select text", systemImage: "selection.pin.in.out") }
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

/// Companion sheet: your messages as compact right-aligned bubbles, replies as left-aligned ones.
private struct CompactMessageRow: View {
    let row: ChatRow
    let model: TranscriptModel
    let mine: Bool
    let shown: String
    @Environment(\.companionSpeaker) private var speaker
    @State private var selecting = false

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
                        MarkdownText(text: shown, model: model)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(VerdeTheme.user, in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        // I12-4: replies sit in their own bubble, inset like yours, not on the pane's edge.
                        MarkdownText(text: streamTail(row), model: model)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(VerdeTheme.assistant, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                if let delivery {
                    Text(delivery).font(VerdeTheme.ui(10)).foregroundStyle(row.delivery == "failed" ? Color.red : Color.secondary)
                }
            }
            .frame(maxWidth: mine ? nil : .infinity, alignment: mine ? .trailing : .leading)
            .contextMenu { MessageMenu(text: shown, model: model, selecting: $selecting) }
            .sheet(isPresented: $selecting) { SelectTextSheet(text: renderedPlainText(shown, model: model)) }
            if !mine { Spacer(minLength: 32) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel((mine ? "You: " : (speaker ?? (row.author.isEmpty ? "Reply" : row.author)) + ": ") + shown)
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

private struct ThinkCard: View {
    let row: ChatRow
    let model: TranscriptModel

    var body: some View {
        let key = "\(row.id):think"
        let expanded = model.disclosure.flag(key)
        VStack(alignment: .leading, spacing: 4) {
            Button { model.disclosure.toggle(key) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb").font(.system(size: 12)).accessibilityHidden(true)
                    Text(commandRunning(row) ? "Thinking…" : "Thought")
                    DisclosureChevron(expanded: expanded)
                }
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .frame(minHeight: 44)
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
        // S32: System rows are neutral, as on Android; amber is only for what waits on you.
        .background(VerdeTheme.alternate, in: RoundedRectangle(cornerRadius: 10))
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
                // S13: waiting on you is amber (dot and text); working is the accent.
                Text(workingLabel(turn, waitingApproval: waitingApproval,
                                  elapsed: turn.started_at_ms.map { elapsedLabel($0, nowMs(context.date)) }))
                    .font(.caption.weight(.medium)).foregroundStyle(waitingApproval ? VerdeTheme.warning : VerdeTheme.accent)
            }
            .padding(.horizontal, 4).padding(.vertical, 4)
        }
        .accessibilityIdentifier("working-row")
    }
}
