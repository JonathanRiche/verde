import SwiftUI
import UIKit

/// Files listed before "Show more files"; rows shown per expanded file before "Show more lines".
let diffFilePage = 30
let diffInlineLines = 200
let diffMoreLines = 400
/// Past this many inline rows only the lazily laid out full-screen view shows the rest.
let diffInlineMax = 1_200
/// Rows per Text inside an inline hunk, bounding each text layout.
private let diffChunkRows = 80
/// Very large pasteboard writes are refused, never truncated (Android parity).
let diffMaxCopyUnits = 256 * 1024

/// Disclosure state for transcript cards. Lives in the transcript model so it survives lazy cell
/// recycling; keys are `<row id>:<part>`.
@MainActor
@Observable
final class DisclosureStore {
    private var flags: [String: Bool] = [:]
    private var numbers: [String: Int] = [:]
    private var sets: [String: Set<Int>] = [:]

    func flag(_ key: String, _ fallback: Bool = false) -> Bool { flags[key] ?? fallback }
    func setFlag(_ key: String, _ value: Bool) { flags[key] = value }
    func toggle(_ key: String, _ fallback: Bool = false) { flags[key] = !(flags[key] ?? fallback) }
    func binding(_ key: String, _ fallback: Bool = false) -> Binding<Bool> {
        Binding(get: { self.flag(key, fallback) }, set: { self.setFlag(key, $0) })
    }
    func number(_ key: String, _ fallback: Int) -> Int { numbers[key] ?? fallback }
    func setNumber(_ key: String, _ value: Int) { numbers[key] = value }
    func members(_ key: String) -> Set<Int> { sets[key] ?? [] }
    func toggleMember(_ key: String, _ member: Int) {
        var set = sets[key] ?? []
        if set.contains(member) { set.remove(member) } else { set.insert(member) }
        sets[key] = set
    }
}

private let addColor = Color(uiColor: .systemGreen)
private let deleteColor = Color(uiColor: .systemRed)
private let diffFont = Font.system(.footnote, design: .monospaced)

private func copy(_ text: String) { UIPasteboard.general.string = text }

/// The D-07 "Changed files" card for a VERDE_DIFF_V2 row.
struct DiffCard: View {
    let id: String
    let text: String
    let source: DiffRenderSource
    let disclosure: DisclosureStore
    @State private var index: RenderResult<DiffIndexView>?
    @State private var diffBody: DiffBody?

    var body: some View {
        let current = source.cachedIndex(text) ?? index
        let files = current?.value?.files
        let wrap = disclosure.binding("\(id):wrap")
        let limit = disclosure.number("\(id):files", diffFilePage)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(files.map { "Changed files · \($0.count)" } ?? "Changed files")
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                // One file: its own row already shows the counts.
                if let files, files.count > 1 {
                    let totals = diffTotals(files)
                    DiffCounts(added: totals.additions, removed: totals.deletions)
                }
                Toggle("Wrap lines", isOn: wrap).toggleStyle(.button).font(.caption).controlSize(.small)
            }
            .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 6)
            Divider()
            if let note = note(current, files) {
                Text(note).font(.footnote).foregroundStyle(.secondary).padding(12)
            }
            if let files {
                let diffBody = self.diffBody ?? DiffBody(text)
                ForEach(Array(files.prefix(limit).enumerated()), id: \.offset) { i, entry in
                    if i > 0 { Divider().opacity(0.5) }
                    DiffFileSection(key: "\(id):\(i)", entry: entry, diffBody: diffBody, source: source, wrap: wrap.wrappedValue,
                                    defaultExpanded: files.count == 1, disclosure: disclosure)
                }
                if files.count > limit {
                    let more = files.count - limit
                    Button("Show \(min(more, diffFilePage)) more files · \(more) hidden") {
                        disclosure.setNumber("\(id):files", limit + diffFilePage)
                    }
                    .font(.footnote).padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(uiColor: .separator)))
        .accessibilityIdentifier("diff-card")
        .task(id: text) {
            if diffBody?.body != text { diffBody = DiffBody(text) }
            index = await source.index(text)
        }
    }

    private func note(_ index: RenderResult<DiffIndexView>?, _ files: [DiffIndexEntry]?) -> String? {
        if index == nil { return "Loading changes…" }
        guard let files else { return "This diff couldn't be decoded on the phone." }
        return files.isEmpty ? "Diff data is empty or could not be restored." : nil
    }
}

private struct DiffCounts: View {
    let added: UInt64
    let removed: UInt64
    var body: some View {
        (Text("+\(added)").foregroundColor(addColor) + Text(" ") + Text("−\(removed)").foregroundColor(deleteColor))
            .font(.caption.monospaced())
            .accessibilityLabel("\(added) added, \(removed) removed")
    }
}

private struct DiffFileSection: View {
    let key: String
    let entry: DiffIndexEntry
    let diffBody: DiffBody
    let source: DiffRenderSource
    let wrap: Bool
    let defaultExpanded: Bool
    let disclosure: DisclosureStore

    var body: some View {
        let expanded = disclosure.flag("\(key):open", defaultExpanded)
        VStack(alignment: .leading, spacing: 0) {
            Button { disclosure.toggle("\(key):open", defaultExpanded) } label: {
                HStack(spacing: 8) {
                    Text(expanded ? "▾" : "▸").foregroundStyle(.secondary)
                    Text(entry.path).font(.footnote.monospaced()).lineLimit(1).truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    DiffCounts(added: entry.additions, removed: entry.deletions)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Collapse \(entry.path)" : "Expand \(entry.path)")
            if expanded { DiffFileBody(key: key, entry: entry, diffBody: diffBody, source: source, wrap: wrap, disclosure: disclosure) }
        }
    }
}

private struct DiffFileBody: View {
    let key: String
    let entry: DiffIndexEntry
    let diffBody: DiffBody
    let source: DiffRenderSource
    let wrap: Bool
    let disclosure: DisclosureStore
    @State private var record: DiffRecord?
    @State private var render: DiffFileRender?
    @State private var fullScreen = false

    var body: some View {
        let budget = disclosure.number("\(key):budget", diffInlineLines)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button("Copy path") { copy(entry.path) }
                let patch = record?.patch
                let copyable = patch.map { $0.utf16.count <= diffMaxCopyUnits } ?? false
                Button(patch != nil && !copyable ? "Patch too large to copy" : "Copy patch") { if let patch { copy(patch) } }
                    .disabled(!copyable)
                if case .parsed(let model) = render, !model.hunks.isEmpty {
                    Button("Full screen") { fullScreen = true }
                }
            }
            .font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
            switch render {
            case nil:
                DiffNote(text: "Rendering…")
            case .source(let patch):
                DiffSourceText(patch: patch, budget: budget) { disclosure.setNumber("\(key):budget", budget + diffMoreLines) }
            case .parsed(let model):
                if model.binary { DiffNote(text: "Binary file — not shown.") }
                else if model.hunks.isEmpty { DiffNote(text: "No line changes.") }
                else {
                    DiffHunks(key: key, model: model, wrap: wrap, budget: budget, disclosure: disclosure) {
                        if budget >= diffInlineMax { fullScreen = true } else { disclosure.setNumber("\(key):budget", budget + diffMoreLines) }
                    }
                }
            }
        }
        .padding(.bottom, 6)
        .task(id: "\(entry.start):\(entry.patch_start):\(entry.end)") {
            guard let record = diffBody.record(entry) else { render = .source(""); return }
            self.record = record
            render = await renderDiffFile(source, record, path: entry.path)
        }
        .fullScreenCover(isPresented: $fullScreen) {
            if case .parsed(let model) = render {
                DiffFullScreen(path: entry.path, model: model, initialWrap: wrap, patch: record?.patch)
            }
        }
    }
}

private struct DiffNote: View {
    let text: String
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
    }
}

/// The core couldn't parse this record (too big or malformed): its source text, never reparsed.
private struct DiffSourceText: View {
    let patch: String
    let budget: Int
    let onMore: () -> Void
    var body: some View {
        let (shown, truncated) = leadingLines(patch, budget)
        VStack(alignment: .leading, spacing: 4) {
            DiffNote(text: "Too large or unusual to render as a diff here; showing the patch text.")
            ScrollView(.horizontal) {
                Text(shown).font(diffFont).fixedSize().padding(.horizontal, 12).textSelection(.enabled)
            }
            .accessibilityIdentifier("diff-lines")
            if truncated { Button("Show more lines", action: onMore).font(.footnote).padding(.horizontal, 12) }
        }
    }
}

private struct DiffHunks: View {
    let key: String
    let model: DiffFileModel
    let wrap: Bool
    let budget: Int
    let disclosure: DisclosureStore
    let onMore: () -> Void

    private struct Shown { let index: Int; let hunk: DiffHunkModel; let rows: ArraySlice<DiffRow>?; let collapsed: Bool }

    var body: some View {
        let collapsed = disclosure.members("\(key):collapsed")
        var left = budget
        var hidden = 0
        var shown: [Shown] = []
        for (i, hunk) in model.hunks.enumerated() {
            let isCollapsed = collapsed.contains(i)
            if left <= 0 { if !isCollapsed { hidden += hunk.rows.count }; continue }
            if isCollapsed { shown.append(Shown(index: i, hunk: hunk, rows: nil, collapsed: true)); continue }
            let rows = hunk.rows.prefix(left)
            hidden += hunk.rows.count - rows.count
            left -= rows.count
            shown.append(Shown(index: i, hunk: hunk, rows: rows, collapsed: false))
        }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(shown, id: \.index) { item in
                HStack(spacing: 6) {
                    Button { disclosure.toggleMember("\(key):collapsed", item.index) } label: {
                        HStack(spacing: 6) {
                            Text(item.collapsed ? "▸" : "▾").foregroundStyle(.secondary)
                            Text(item.hunk.header).font(.caption2.monospaced()).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(item.collapsed ? "Expand hunk" : "Collapse hunk")
                    Button("Copy hunk") { copy(hunkPatch(item.hunk)) }.font(.caption)
                }
                .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.08))
                if let rows = item.rows { DiffLines(rows: Array(rows), width: model.numberWidth, wrap: wrap) }
            }
            if hidden > 0 {
                Button(budget >= diffInlineMax ? "Open full screen · \(hidden) more lines" : "Show more lines · \(hidden) remaining", action: onMore)
                    .font(.footnote).padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
    }
}

/// One row as attributed text: gutter, then the text with syntax colours and word highlights.
/// `pad` spaces extend the line background to a common width when rows scroll together.
func diffRowText(_ row: DiffRow, width: Int, pad: Int = 0) -> AttributedString {
    let gutter = diffGutter(row, width: width)
    let text = gutter + row.text + String(repeating: " ", count: max(0, pad))
    let base = gutter.utf16.count
    var ranges: [StyledRange] = []
    var line = AttributeContainer()
    switch row.kind {
    case "add": line[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = addColor.opacity(0.12)
    case "delete": line[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = deleteColor.opacity(0.12)
    default: break
    }
    ranges.append(StyledRange(start: 0, end: text.utf16.count, attributes: line))
    var gutterStyle = AttributeContainer()
    gutterStyle[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] =
        row.kind == "add" ? addColor : row.kind == "delete" ? deleteColor : Color.secondary
    ranges.append(StyledRange(start: 0, end: base, attributes: gutterStyle))
    if row.kind == "meta" {
        var meta = AttributeContainer()
        meta[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = .secondary
        meta[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self] = .emphasized
        ranges.append(StyledRange(start: base, end: base + row.text.utf16.count, attributes: meta))
    }
    for s in row.syntax { if let style = tokenAttributes(s.kind) { ranges.append(StyledRange(start: base + s.start, end: base + s.end, attributes: style)) } }
    for w in row.words {
        var word = AttributeContainer()
        word[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = (w.kind == "delete" ? deleteColor : addColor).opacity(0.34)
        ranges.append(StyledRange(start: base + w.start, end: base + w.end, attributes: word))
    }
    return styledText(text, ranges)
}

/// Chunked rows of one hunk: scrolled horizontally together (one Text per 80 rows, padded so line
/// backgrounds span the row), or wrapped one row per line under the gutter.
private struct DiffLines: View {
    let rows: [DiffRow]
    let width: Int
    let wrap: Bool

    var body: some View {
        Group {
            if wrap {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        Text(diffRowText(row, width: width)).font(diffFont)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(lineBackground(row.kind))
                    }
                }
                .padding(.horizontal, 8)
            } else {
                let columns = rows.map(\.text.count).max() ?? 0
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(stride(from: 0, to: rows.count, by: diffChunkRows)), id: \.self) { start in
                            Text(chunk(rows[start..<min(start + diffChunkRows, rows.count)], columns: columns))
                                .font(diffFont).fixedSize()
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .accessibilityIdentifier("diff-lines")
    }

    private func chunk(_ slice: ArraySlice<DiffRow>, columns: Int) -> AttributedString {
        var out = AttributedString()
        for (i, row) in slice.enumerated() {
            if i > 0 { out.append(AttributedString("\n")) }
            out.append(diffRowText(row, width: width, pad: columns - row.text.count + 1))
        }
        return out
    }
}

private func lineBackground(_ kind: String) -> Color {
    kind == "add" ? addColor.opacity(0.12) : kind == "delete" ? deleteColor.opacity(0.12) : .clear
}

/// Whole-file view: a LazyVStack of rows, so even 4,096-line patches lay out only what's visible.
private struct DiffFullScreen: View {
    let path: String
    let model: DiffFileModel
    let patch: String?
    @State private var wrap: Bool
    @Environment(\.dismiss) private var dismiss

    init(path: String, model: DiffFileModel, initialWrap: Bool, patch: String?) {
        self.path = path
        self.model = model
        self.patch = patch
        _wrap = State(initialValue: initialWrap)
    }

    private enum Item: Hashable { case header(Int), line(Int, Int) }

    var body: some View {
        let items = model.hunks.enumerated().flatMap { h, hunk in [Item.header(h)] + hunk.rows.indices.map { Item.line(h, $0) } }
        // Monospace rows: the widest bounds the scrollable content width.
        let columns = model.hunks.flatMap(\.rows).map { $0.text.count }.max() ?? 0
        let charWidth = ("M" as NSString).size(withAttributes: [.font: UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)]).width
        let contentWidth = CGFloat(columns + model.numberWidth * 2 + 4) * charWidth + 16
        NavigationStack {
            ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items, id: \.self) { item in
                        switch item {
                        case .header(let h):
                            Text(model.hunks[h].header).font(.caption2.monospaced())
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.accentColor.opacity(0.08))
                        case .line(let h, let r):
                            let row = model.hunks[h].rows[r]
                            Text(diffRowText(row, width: model.numberWidth)).font(diffFont)
                                .fixedSize(horizontal: !wrap, vertical: true)
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(lineBackground(row.kind))
                        }
                    }
                }
                .frame(minWidth: wrap ? nil : contentWidth, alignment: .leading)
            }
            .accessibilityIdentifier("diff-full-screen")
            .navigationTitle(basename(path))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close diff")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Toggle("Wrap lines", isOn: $wrap).toggleStyle(.button)
                    Button("Copy patch") { if let patch { copy(patch) } }
                        .disabled(patch.map { $0.utf16.count > diffMaxCopyUnits } ?? true)
                }
            }
        }
    }
}
