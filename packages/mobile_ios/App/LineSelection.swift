import SwiftUI
import Observation

/// "Ask agent about these lines": a line-number tap (or long-press) selection over a text or diff
/// viewer, a bar with Copy / Ask agent, and a sheet that sends the shared `selection_prompt`
/// message to one of the workspace's chats. Selected text and instructions stay in memory and are
/// never logged.
struct PickedLines: Equatable {
    let start: Int
    let end: Int
    let side: String?
    let text: String
}

/// What the prompt formatter needs: an absolute path plus the picked lines.
struct SelectionExcerpt: Equatable {
    let path: String
    let start: Int
    let end: Int
    let side: String?
    let text: String
}

/// A contiguous selection of viewer positions (1-based file lines, or 1-based diff rows).
@MainActor @Observable
final class LineSelection {
    private(set) var anchor: Int?
    private(set) var focus: Int?
    /// Bound by the visible viewer: turns positions into lines and text.
    @ObservationIgnored var source: ((ClosedRange<Int>) -> PickedLines?)?

    var range: ClosedRange<Int>? {
        guard let anchor else { return nil }
        let other = focus ?? anchor
        return min(anchor, other)...max(anchor, other)
    }
    func contains(_ position: Int) -> Bool { range?.contains(position) == true }
    func start(_ position: Int) { anchor = position; focus = position }
    func drag(_ position: Int) { if anchor != nil { focus = position } }
    /// A line-number tap starts a selection, extends it, or clears a single line tapped again.
    func tap(_ position: Int) {
        guard let current = range else { return start(position) }
        if current.lowerBound == position && current.upperBound == position { clear() } else { focus = position }
    }
    func clear() { anchor = nil; focus = nil }
    func picked() -> PickedLines? { range.flatMap { source?($0) } }
}

private struct LineSelectionKey: EnvironmentKey {
    static let defaultValue: LineSelection? = nil
}

extension EnvironmentValues {
    /// Set by `SelectionScope` around a viewer that can ask an agent about its lines.
    var lineSelection: LineSelection? {
        get { self[LineSelectionKey.self] }
        set { self[LineSelectionKey.self] = newValue }
    }
}

var selectedLineColor: Color { VerdeTheme.accent.opacity(0.2) }
/// Monospaced rows of the selectable viewers (the diff font, so gutter widths are known).
let selectableLineFont = Font.system(.footnote, design: .monospaced)

@MainActor func selectableCharWidth() -> CGFloat {
    let font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
    return ("M" as NSString).size(withAttributes: [.font: font]).width
}

/// UTF-16 offsets where each display line starts (a trailing newline adds no empty line).
func fileLineStarts(_ text: String) -> [Int] {
    var starts = [0]
    let units = Array(text.utf16)
    for (i, unit) in units.enumerated() where unit == 10 && i + 1 < units.count { starts.append(i + 1) }
    return starts
}

/// End (exclusive, UTF-16, without the line break) of display line `index`.
private func lineEnd(_ text: NSString, _ starts: [Int], _ index: Int) -> Int {
    var end = index + 1 < starts.count ? starts[index + 1] : text.length
    if end > starts[index] && text.character(at: end - 1) == 10 { end -= 1 }
    if end > starts[index] && text.character(at: end - 1) == 13 { end -= 1 }
    return end
}

/// Lines `range` (1-based) of a text file, without the final newline.
func fileLines(_ text: String, starts: [Int], range: ClosedRange<Int>) -> PickedLines? {
    guard !starts.isEmpty else { return nil }
    let value = text as NSString
    let first = min(max(range.lowerBound, 1), starts.count)
    let last = min(max(range.upperBound, first), starts.count)
    let end = lineEnd(value, starts, last - 1)
    let start = starts[first - 1]
    return PickedLines(start: first, end: last, side: nil, text: value.substring(with: NSRange(location: start, length: max(0, end - start))))
}

/// A text file split once into display lines for the selectable viewer.
final class FileSplit {
    let text: String
    let starts: [Int]
    let lines: [String]
    init(_ text: String) {
        self.text = text
        let starts = fileLineStarts(text)
        let value = text as NSString
        self.starts = starts
        lines = starts.indices.map { i in
            let end = lineEnd(value, starts, i)
            return value.substring(with: NSRange(location: starts[i], length: max(0, end - starts[i])))
        }
    }
}

/// Diff rows `range` (1-based, hunk headers excluded) as lines of one side: the old side when only
/// deletions (and context) are picked, else the new side. Rows not on that side are left out.
func diffLines(_ rows: [DiffRow], range: ClosedRange<Int>) -> PickedLines? {
    guard !rows.isEmpty else { return nil }
    let lower = min(max(range.lowerBound - 1, 0), rows.count)
    let upper = min(max(range.upperBound, 0), rows.count)
    guard lower < upper else { return nil }
    let picked = rows[lower..<upper].filter { $0.kind != "meta" }
    let old = !picked.contains { $0.kind == "add" } && picked.contains { $0.kind == "delete" }
    let side = picked.filter { (old ? $0.oldLine : $0.newLine) != nil }
    let numbers = side.compactMap { old ? $0.oldLine : $0.newLine }.map { Int(clamping: $0) }
    guard let first = numbers.min(), let last = numbers.max() else { return nil }
    return PickedLines(start: first, end: last, side: old ? "old" : "new", text: side.map(\.raw).joined(separator: "\n"))
}

func linesLabel(_ picked: PickedLines) -> String {
    let lines = picked.end > picked.start ? "Lines \(picked.start)–\(picked.end)" : "Line \(picked.start)"
    switch picked.side {
    case "old": return lines + " (old)"
    case "new": return lines + " (new)"
    default: return lines
    }
}

/// Chats the selection can go to: the workspace's top-level, unarchived chats, open and recent first.
func askTargets(_ threads: [ThreadSummary]) -> [ThreadSummary] {
    threads.filter { !$0.archived && listed($0) }.sorted {
        if $0.open != $1.open { return $0.open }
        let a = $0.last_activity_at_ms ?? 0, b = $1.last_activity_at_ms ?? 0
        if a != b { return a > b }
        return $0.thread_id < $1.thread_id
    }
}

/// Ask-agent messages waiting for their chat screen to open; in memory only, keyed by host,
/// workspace and chat, taken once.
@MainActor
enum PromptHandoff {
    private static var pending: [String: String] = [:]
    private static func key(_ host: String?, _ workspace: String, _ thread: String) -> String {
        (host ?? "") + "\u{0}" + workspace + "\u{0}" + thread
    }
    static func put(host: String?, workspace: String, thread: String, text: String) { pending[key(host, workspace, thread)] = text }
    static func take(host: String?, workspace: String, thread: String) -> String? { pending.removeValue(forKey: key(host, workspace, thread)) }
    static func clear() { pending.removeAll() }
}

/// Selection gestures on one viewer row: a tap on the line-number gutter starts or extends a
/// selection; a tap on the text clears a selection it is inside, or extends an active one; a
/// long press starts one. Plain drags still scroll.
struct LineGestures: ViewModifier {
    let selection: LineSelection?
    let position: Int
    /// Width of the line-number gutter from the row's leading edge.
    let gutter: CGFloat

    func body(content: Content) -> some View {
        if let selection {
            content
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { point in
                    if point.x <= gutter { selection.tap(position) }
                    else if selection.contains(position) { selection.clear() }
                    else if selection.range != nil { selection.drag(position) }
                }
                .onLongPressGesture(minimumDuration: 0.45) {
                    selection.start(position)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                .accessibilityAction(named: selection.contains(position) ? "Change selection" : "Select line") { selection.tap(position) }
        } else {
            content
        }
    }
}

/// Plain text with a line-number gutter, for files opened where lines can be asked about.
struct SelectableFileText: View {
    let split: FileSplit
    /// Lines a citation points at; highlighted and scrolled to.
    let target: ClosedRange<Int>?
    @Environment(\.lineSelection) private var selection

    var body: some View {
        let digits = String(split.lines.count).count
        let gutter = CGFloat(digits) * selectableCharWidth() + 20
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(split.lines.indices, id: \.self) { index in
                        let number = index + 1
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(String(number)).foregroundStyle(VerdeTheme.subtle)
                                .frame(width: gutter - 12, alignment: .trailing).padding(.trailing, 12)
                            Text(split.lines[index].isEmpty ? " " : split.lines[index]).foregroundStyle(VerdeTheme.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(selectableLineFont)
                        .padding(.vertical, 1).padding(.trailing, 8)
                        .background(selection?.contains(number) == true ? selectedLineColor
                                    : target?.contains(number) == true ? VerdeTheme.warning.opacity(0.15) : Color.clear)
                        .modifier(LineGestures(selection: selection, position: number, gutter: gutter))
                        .accessibilityIdentifier("file-line")
                        .id(number)
                    }
                }
                .padding(.vertical, 8)
            }
            .onAppear {
                bind()
                if let target { proxy.scrollTo(max(1, target.lowerBound - 3), anchor: .top) }
            }
            .onChange(of: ObjectIdentifier(split)) { bind() }
            .onDisappear { selection?.source = nil }
        }
    }

    private func bind() {
        let split = split
        selection?.source = { fileLines(split.text, starts: split.starts, range: $0) }
    }
}

/// The bar shown while lines are selected.
struct SelectionBar: View {
    let picked: PickedLines?
    let onAsk: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onClear) { Image(systemName: "xmark").frame(width: 36, height: 36) }
                .accessibilityLabel("Clear selection")
            Text(picked.map(linesLabel) ?? "Nothing to ask about").font(VerdeTheme.ui(13, bold: true)).lineLimit(1)
            Spacer(minLength: 0)
            Button("Copy") { if let picked { UIPasteboard.general.string = picked.text } }.disabled(picked == nil)
            Button("Ask agent", action: onAsk).buttonStyle(.borderedProminent).disabled(picked == nil)
                .accessibilityIdentifier("selection-ask")
        }
        .font(VerdeTheme.ui(14))
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(VerdeTheme.alternate)
        .overlay(alignment: .top) { Rectangle().fill(VerdeTheme.border).frame(height: 1) }
        .accessibilityIdentifier("selection-bar")
    }
}

struct AskAgentSheet: View {
    let picked: PickedLines
    let path: String
    let chats: [ThreadSummary]
    let sending: Bool
    let error: String?
    let onCancel: () -> Void
    let onSend: (_ thread: String, _ instruction: String) -> Void
    @State private var chat: String?
    @State private var instruction = ""

    var body: some View {
        let chosen = chats.first { $0.thread_id == chat }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(basename(path)) · \(linesLabel(picked))").font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted)
                        .lineLimit(1).truncationMode(.head)
                    Text(picked.text.split(separator: "\n", omittingEmptySubsequences: false).prefix(6).joined(separator: "\n"))
                        .font(selectableLineFont).lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        .background(VerdeTheme.assistant, in: RoundedRectangle(cornerRadius: 6))
                    Text("SEND TO").font(VerdeTheme.ui(10, bold: true)).tracking(0.8).foregroundStyle(VerdeTheme.subtle).padding(.top, 4)
                    if chats.isEmpty {
                        Text("This workspace has no chats yet. Start one, then try again.").font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.warning)
                    }
                    VStack(spacing: 0) {
                        ForEach(chats, id: \.thread_id) { thread in
                            Button { chat = thread.thread_id } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: thread.thread_id == chat ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(thread.thread_id == chat ? VerdeTheme.accent : VerdeTheme.subtle)
                                    ProviderGlyph(provider: thread.provider)
                                    Text(thread.title.isEmpty ? "Untitled chat" : thread.title).lineLimit(1)
                                    Spacer(minLength: 0)
                                    if activeTurn(thread.status) { Text("working").font(VerdeTheme.ui(11)).foregroundStyle(VerdeTheme.accent) }
                                }.frame(minHeight: 40).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(thread.thread_id == chat ? .isSelected : [])
                            .accessibilityIdentifier("ask-chat-" + thread.thread_id)
                        }
                    }
                    TextField("What should the agent do?", text: $instruction, axis: .vertical)
                        .lineLimit(2...5).disabled(sending)
                        .padding(10).background(VerdeTheme.alternate, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("ask-instruction")
                    if let chosen, activeTurn(chosen.status) {
                        Text("This chat is working; your message goes in as a follow-up.").font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted)
                    }
                    if let error { Text(error).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.warning) }
                }
                .padding(16)
            }
            .background(VerdeTheme.panel)
            .navigationTitle("Ask agent").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel).disabled(sending) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "Sending…" : "Send") { if let chat { onSend(chat, instruction) } }
                        .disabled(sending || chat == nil || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("ask-send")
                }
            }
        }
        .tint(VerdeTheme.accent).foregroundStyle(VerdeTheme.text).font(VerdeTheme.ui())
        .interactiveDismissDisabled(sending)
        .onAppear { if chat == nil { chat = chats.first?.thread_id } }
    }
}

private struct AskRequest: Identifiable {
    let id = UUID()
    let picked: PickedLines
}

/// Wraps a viewer with line selection: provides `lineSelection`, shows the selection bar and the
/// ask sheet, and hands the formatted message to the chosen chat's screen. `path` is the absolute
/// path the selection belongs to (nil disables asking). `roots` name the message's path (default:
/// the workspace folders; diffs pass their repository).
struct SelectionScope<Content: View>: View {
    let browse: BrowseModel
    let explorer: ExplorerModel
    let path: String?
    var roots: [ExplorerRoot]? = nil
    @ViewBuilder let content: () -> Content
    @Environment(\.openRoute) private var openRoute
    @State private var selection = LineSelection()
    @State private var asking: AskRequest?
    @State private var sending = false
    @State private var error: String?
    @State private var opening: BrowseRoute?
    @State private var requestedRoots = false

    var body: some View {
        let workspace = browse.state.workspaces?.items.first { $0.workspace_id == explorer.workspaceID }
        VStack(spacing: 0) {
            content()
                .environment(\.lineSelection, path == nil ? nil : selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if path != nil, selection.range != nil {
                let picked = selection.picked()
                SelectionBar(picked: picked, onAsk: {
                    error = nil
                    if let picked { asking = AskRequest(picked: picked) }
                }, onClear: { selection.clear() })
            }
        }
        // Roots name non-home folders in the message; load them once if nothing cached them yet.
        .onAppear {
            if roots == nil && !requestedRoots && explorer.files?.loaded != true { requestedRoots = true; explorer.loadRoots() }
        }
        .onChange(of: path) { selection.clear() }
        .sheet(item: $asking, onDismiss: {
            if let route = opening { opening = nil; openRoute(route) }
        }) { request in
            AskAgentSheet(picked: request.picked, path: path ?? "", chats: askTargets(workspace?.threads ?? []),
                          sending: sending, error: error, onCancel: { if !sending { asking = nil } }) { thread, instruction in
                send(request.picked, thread: thread, instruction: instruction, workspace: workspace)
            }
        }
    }

    private func send(_ picked: PickedLines, thread: String, instruction: String, workspace: Workspace?) {
        guard let path, !sending else { return }
        sending = true
        error = nil
        Task {
            var named = roots ?? (explorer.files?.roots ?? []).filter { !$0.path.isEmpty }
            if roots == nil && named.isEmpty, let workspace {
                named = [ExplorerRoot(id: homeRoot, name: workspace.label, path: workspace.path, home: true)]
            }
            let text = await explorer.prompt(SelectionExcerpt(path: path, start: picked.start, end: picked.end, side: picked.side, text: picked.text),
                                             roots: named, instruction: instruction)
            sending = false
            guard let text else { error = "Couldn't prepare the message. The selection may be too large."; return }
            PromptHandoff.put(host: browse.hostID, workspace: explorer.workspaceID, thread: thread, text: text)
            selection.clear()
            // The chat opens once the sheet is gone, so the push isn't lost to its dismissal.
            opening = .thread(workspace: explorer.workspaceID, thread: thread)
            asking = nil
        }
    }
}
