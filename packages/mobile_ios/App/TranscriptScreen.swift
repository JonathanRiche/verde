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
        .navigationTitle(model?.thread?.thread.title ?? fallbackTitle ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let summary = model?.thread?.thread {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(summary.title.isEmpty ? "Chat" : summary.title).font(.headline).lineLimit(1)
                        Text([summary.provider, summary.model].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
        }
        // Focus is released after a short delay (or by the model's owner check once it is gone),
        // so a quick return to this chat doesn't churn the core's focus slot.
        .onDisappear { model?.setVisible(false) }
    }
}

private struct TranscriptBody: View {
    let model: TranscriptModel
    let browse: BrowseModel
    let onHosts: () -> Void

    var body: some View {
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
            ChatComposer(model: model.input)
        }
        .environment(\.openURL, OpenURLAction { url in
            // File citations open in the I-09 viewer; until then they are inert, never sent to the system.
            if url.scheme == citationScheme { return .handled }
            return safeLinkUrl(url.absoluteString) != nil ? .systemAction : .discarded
        })
    }
}

private struct BannerCard: View {
    let banner: Banner
    let retry: () -> Void
    let hosts: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(banner.text).font(.subheadline).accessibilityIdentifier("transcriptBanner")
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
    let model: TranscriptModel
    let page: ChatPage?
    let approval: ChatApproval?
    let turn: ChatTurn?

    @State private var position: String?
    @State private var atBottom = true
    @State private var viewport: CGFloat = 0
    @State private var cardVisible = false

    /// Changes whenever the bottom of the transcript grows (new row, streaming delta, turn state).
    private func tailKey(_ items: [TranscriptItem]) -> String {
        var key = "\(items.count)|\(items.last?.id ?? "")"
        if case .message(let row) = items.last { key += "|\(row.body.utf16.count)" }
        if case .working(let turn, let waiting) = items.last { key += "|\(turn.status)|\(waiting)" }
        return key
    }

    var body: some View {
        let items = model.items
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ZStack(alignment: .top) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
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
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    .coordinateSpace(name: "transcript")
                    .scrollPosition(id: $position)
                    .modifier(BottomAnchor())
                    .accessibilityIdentifier("transcript-list")
                    .onPreferenceChange(BottomOffsetKey.self) { maxY in
                        let bottom = maxY - viewport <= bottomSlack
                        if bottom != atBottom { atBottom = bottom }
                    }
                    .onChange(of: tailKey(items)) {
                        // `atBottom` still describes the layout before this change.
                        if atBottom { proxy.scrollTo(bottomID, anchor: .bottom) }
                    }

                    ApprovalBanner(approval: approval, cardVisible: cardVisible, controller: model.approvals) {
                        guard let approval else { return }
                        withAnimation { proxy.scrollTo("approval:\(approval.turn_id):\(approval.call_id)", anchor: .center) }
                    }

                    if !atBottom && !items.isEmpty {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Button {
                                    withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) }
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
                    Text("Loading earlier messages…").font(.footnote).foregroundStyle(.secondary)
                } else if page.has_older {
                    Button("Load earlier messages", action: loadOlder).font(.footnote)
                } else {
                    Text("Start of conversation").font(.caption).foregroundStyle(.tertiary)
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
                Text(state.stopping ? "Stopping the current turn…" : "The agent is working.").font(.subheadline)
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
        case .notice(let row): NoticeRow(row: row, model: model)
        case .usage(_, let usage): UsageCard(usage: usage)
        case .working(let turn, let waiting): WorkingRow(turn: turn, waitingApproval: waiting)
        case .approval(let approval): ApprovalCard(approval: approval, controller: model.approvals, disclosure: model.disclosure)
        }
    }
}

private struct MessageRow: View {
    let row: ChatRow
    let model: TranscriptModel

    var body: some View {
        let mine = row.role == "user"
        HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(mine ? "You" : (row.author.isEmpty ? "Assistant" : row.author)).font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    if let label = deliveryLabel(row.delivery) {
                        Text(label).font(.caption2).foregroundStyle(row.delivery == "failed" ? Color.red : Color.secondary)
                    }
                }
                if !row.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            // Host images need an authenticated fetch the core doesn't offer yet; name only.
                            ForEach(row.attachments, id: \.local_id) { attachment in
                                Text((attachment.mime.hasPrefix("image/") ? "Image · " : "") + basename(attachment.name))
                                    .font(.caption).lineLimit(1).padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                            }
                        }
                    }
                }
                if !row.body.isEmpty {
                    // User text is verbatim (web parity); assistant output goes through the core AST.
                    if mine { Text(row.body).font(.body).textSelection(.enabled) }
                    else { MarkdownText(text: streamTail(row), model: model) }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: mine ? nil : .infinity, alignment: .leading)
            .background(mine ? Color.accentColor.opacity(0.15) : Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12))
            .contextMenu { Button("Copy message") { UIPasteboard.general.string = row.body } }
        }
        .accessibilityIdentifier("message-row")
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

    var body: some View {
        let key = "\(row.id):tool"
        let expanded = disclosure.flag(key, commandFailed(row))
        let all = disclosure.flag(key + ":all")
        VStack(alignment: .leading, spacing: 0) {
            Button { disclosure.toggle(key, commandFailed(row)) } label: {
                HStack(spacing: 8) {
                    StatusDot(color: toolColor(row), label: toolStatusLabel(row))
                    Text(row.author.isEmpty ? "Tool" : row.author).font(.subheadline.weight(.medium))
                    Text(commandPreview(row.body)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(expanded ? "▾" : "▸").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Collapse" : "Expand")
            if expanded {
                let (shown, truncated) = all ? (row.body.trimmingCharacters(in: .whitespacesAndNewlines), false)
                    : leadingLines(row.body, toolPreviewLines)
                ScrollView(.horizontal) {
                    Text(shown).font(.footnote.monospaced()).fixedSize().textSelection(.enabled).padding(.horizontal, 12)
                }
                HStack(spacing: 16) {
                    Button("Copy output") { UIPasteboard.general.string = row.body }
                    if truncated { Button("Show all \(countLines(row.body)) lines") { disclosure.setFlag(key + ":all", true) } }
                }
                .font(.caption)
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(child ? Color(uiColor: .systemBackground) : Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(commandRunning(row) ? Color.accentColor : Color(uiColor: .separator)))
    }
}

private struct ToolGroupCard: View {
    let id: String
    let rows: [ChatRow]
    let subagent: Bool
    let turnStartedAt: Int64?
    let disclosure: DisclosureStore

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
                            .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(expanded ? "▾" : "▸").foregroundStyle(.secondary)
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Collapse" : "Expand")
            if expanded {
                VStack(spacing: 6) {
                    ForEach(rows, id: \.id) { ToolCard(row: $0, child: true, disclosure: disclosure) }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(counts.running > 0 && counts.failed == 0 ? Color.accentColor : Color(uiColor: .separator)))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !row.author.isEmpty { Text(row.author).font(.caption2).foregroundStyle(.secondary) }
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
                        Text(limit.label).font(.footnote)
                        Spacer()
                        Text("\(limit.percent_left)% left").font(.footnote)
                    }
                    ProgressView(value: Double(min(limit.percent_left, 100)), total: 100)
                        .accessibilityLabel("\(limit.label) \(limit.percent_left)% left")
                    if !limit.reset.isEmpty { Text(limit.reset).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            ForEach(Array((usage.stats + usage.recent).enumerated()), id: \.offset) { _, stat in
                HStack {
                    Text(stat.label).font(.footnote)
                    Spacer()
                    Text(stat.value).font(.footnote)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct WorkingRow: View {
    let turn: ChatTurn
    let waitingApproval: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(workingLabel(turn, waitingApproval: waitingApproval,
                                  elapsed: turn.started_at_ms.map { elapsedLabel($0, nowMs(context.date)) }))
                    .font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 4).padding(.vertical, 4)
        }
        .accessibilityIdentifier("working-row")
    }
}
