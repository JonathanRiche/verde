import Foundation

/// D-07 diff card data layer (Android DiffModel.kt parity). The core owns all diff parsing:
/// `diff_index` locates each VERDE_DIFF_V2 file record, `diff` parses one record into
/// hunks/lines/word spans, and `highlight` supplies syntax spans. This file only maps those results
/// onto display rows (UTF-8 byte offsets to UTF-16 indices, tab expansion) and formats copies.
/// There is deliberately no Swift diff parser.
@MainActor
protocol DiffRenderSource: HighlightSource {
    func cachedIndex(_ body: String) -> RenderResult<DiffIndexView>?
    func index(_ body: String) async -> RenderResult<DiffIndexView>
    func cachedDiff(_ text: String) -> RenderResult<DiffView>?
    func diff(_ text: String) async -> RenderResult<DiffView>
}

/// A `diff_index` body whose byte offsets can be sliced back into per-file record strings.
final class DiffBody {
    let body: String
    private lazy var bytes = Array(body.utf8)
    init(_ body: String) { self.body = body }

    /// Byte range [start, end) of the body; the core only reports ranges on UTF-8 boundaries.
    private func slice(_ start: UInt64, _ end: UInt64) -> String? {
        guard start <= end, end <= UInt64(bytes.count) else { return nil }
        return String(decoding: bytes[Int(start)..<Int(end)], as: UTF8.self)
    }

    /// The file's record re-wrapped as a one-file VERDE_DIFF_V2 body, plus its bare patch.
    func record(_ entry: DiffIndexEntry) -> DiffRecord? {
        guard let record = slice(entry.start, entry.end), let patch = slice(entry.patch_start, entry.end) else { return nil }
        return DiffRecord(text: diffMarker + record, patch: patch)
    }
}

struct DiffRecord: Equatable {
    let text: String
    let patch: String
}

/// Languages the core ships grammars for (K-11); anything else renders without syntax colours.
func diffLanguage(_ path: String) -> String? {
    let name = path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
    guard let dot = name.lastIndex(of: ".") else { return nil }
    switch name[name.index(after: dot)...].lowercased() {
    case "js", "mjs", "cjs": return "js"
    case "jsx": return "jsx"
    case "ts", "mts", "cts": return "ts"
    case "tsx": return "tsx"
    case "json": return "json"
    default: return nil
    }
}

/// One unified-view row. `text` is display text (tabs expanded); `raw` is the core's line text,
/// used for copies. `words` are the core's word-level change spans, `syntax` its highlight spans,
/// both in UTF-16 indices of `text`.
struct DiffRow: Equatable {
    let kind: String
    let raw: String
    let text: String
    let oldLine: UInt64?
    let newLine: UInt64?
    let words: [DiffRange]
    let syntax: [DiffRange]
}

struct DiffHunkModel: Equatable {
    let header: String
    let rows: [DiffRow]
}

struct DiffFileModel: Equatable {
    let binary: Bool
    let hunks: [DiffHunkModel]
    let numberWidth: Int
    var lineCount: Int { hunks.reduce(0) { $0 + $1.rows.count } }
}

/// What an expanded file shows: the core's parse, or (when the core can't render it) its source.
enum DiffFileRender: Equatable {
    case parsed(DiffFileModel)
    case source(String)
}

let diffTabWidth = 4

func hunkHeader(_ hunk: DiffHunk) -> String {
    "@@ -\(hunk.old_start),\(hunk.old_count) +\(hunk.new_start),\(hunk.new_count) @@"
}

/// The hunk as a unified-diff fragment (header plus prefixed lines), for "Copy hunk".
func hunkPatch(_ hunk: DiffHunkModel) -> String {
    var out = hunk.header
    for row in hunk.rows {
        out += "\n"
        switch row.kind {
        case "add": out += "+"
        case "delete": out += "-"
        case "context": out += " "
        default: break
        }
        out += row.raw
    }
    return out + "\n"
}

/// Parses one file through the core and attaches syntax spans. Returns `.source` when the core
/// cannot render the record (budget, malformed), so the patch shows as plain text.
@MainActor
func renderDiffFile(_ source: DiffRenderSource, _ record: DiffRecord, path: String) async -> DiffFileRender {
    guard let files = await source.diff(record.text).value?.files, !files.isEmpty else { return .source(record.patch) }
    let hunks = files.flatMap(\.hunks)
    var oldSpans: [RenderSpan] = [], newSpans: [RenderSpan] = []
    if let language = diffLanguage(path), !hunks.isEmpty {
        oldSpans = await sideSpans(source, sideText(hunks, old: true), language)
        newSpans = await sideSpans(source, sideText(hunks, old: false), language)
    }
    return .parsed(diffFileModel(binary: files.contains(where: \.binary) && hunks.isEmpty, hunks, oldSpans: oldSpans, newSpans: newSpans))
}

/// The core caps utility text at 64 KiB; bigger sides skip syntax colouring.
private let maxHighlightUnits = 60 * 1024

@MainActor
private func sideSpans(_ source: DiffRenderSource, _ text: String, _ language: String) async -> [RenderSpan] {
    if text.isEmpty || text.utf16.count > maxHighlightUnits { return [] }
    return await source.highlight(text, language: language).value ?? []
}

/// One side of the file (old: context + deleted, new: context + added) joined by newlines, so the
/// grammar sees consecutive lines with their surrounding context.
func sideText(_ hunks: [DiffHunk], old: Bool) -> String {
    var lines: [String] = []
    for hunk in hunks { for line in hunk.lines where onSide(line, old: old) { lines.append(line.text) } }
    return lines.joined(separator: "\n")
}

private func onSide(_ line: DiffLine, old: Bool) -> Bool {
    line.kind != "meta" && (old ? line.old_line != nil : line.new_line != nil)
}

func diffFileModel(binary: Bool, _ hunks: [DiffHunk], oldSpans: [RenderSpan], newSpans: [RenderSpan]) -> DiffFileModel {
    let old = SideCursor(oldSpans), new = SideCursor(newSpans)
    var maxNumber: UInt64 = 1
    let models = hunks.map { hunk in
        DiffHunkModel(header: hunkHeader(hunk), rows: hunk.lines.map { line in
            let oldSyntax = onSide(line, old: true) ? old.take(line.text) : nil
            let newSyntax = onSide(line, old: false) ? new.take(line.text) : nil
            maxNumber = max(maxNumber, line.old_line ?? 0, line.new_line ?? 0)
            return diffRow(line, (line.kind == "delete" ? oldSyntax : (newSyntax ?? oldSyntax)) ?? [])
        })
    }
    return DiffFileModel(binary: binary, hunks: models, numberWidth: String(maxNumber).count)
}

/// Walks one side's joined text line by line, cutting the (ordered) highlight spans per line.
private final class SideCursor {
    private let spans: [RenderSpan]
    private var offset: UInt64 = 0
    private var next = 0
    init(_ spans: [RenderSpan]) { self.spans = spans }

    /// Byte-relative spans of the next line of this side, which is `text`.
    func take(_ text: String) -> [RenderSpan] {
        let start = offset
        let end = start + UInt64(text.utf8.count)
        offset = end + 1
        if spans.isEmpty { return [] }
        while next < spans.count && spans[next].end <= start { next += 1 }
        var out: [RenderSpan] = []
        var i = next
        while i < spans.count && spans[i].start < end {
            let span = spans[i]
            let s = max(span.start, start) - start, e = min(span.end, end) - start
            if e > s { out.append(RenderSpan(start: s, end: e, kind: span.kind)) }
            i += 1
        }
        return out
    }
}

private func diffRow(_ line: DiffLine, _ syntax: [RenderSpan]) -> DiffRow {
    let raw = Array(line.text.utf16)
    // Tabs become spaces up to the next stop so every row keeps a monospace column grid.
    var display: [UInt16] = []
    display.reserveCapacity(raw.count)
    var toDisplay = [Int](repeating: 0, count: raw.count + 1)
    for (i, unit) in raw.enumerated() {
        toDisplay[i] = display.count
        if unit == 9 {
            display.append(contentsOf: repeatElement(32, count: diffTabWidth - display.count % diffTabWidth))
        } else {
            display.append(unit)
        }
    }
    toDisplay[raw.count] = display.count
    let bytes = utf8ToUtf16(line.text)
    let last = UInt64(bytes.count - 1)
    func ranges(_ spans: [RenderSpan]) -> [DiffRange] {
        spans.compactMap { span in
            let start = toDisplay[bytes[Int(min(span.start, last))]], end = toDisplay[bytes[Int(min(span.end, last))]]
            return end > start ? DiffRange(start: start, end: end, kind: span.kind) : nil
        }
    }
    return DiffRow(kind: line.kind, raw: line.text, text: String(decoding: display, as: UTF16.self),
                   oldLine: line.old_line, newLine: line.new_line, words: ranges(line.spans), syntax: ranges(syntax))
}

/// Plain-text rendering of a file model for golden tests: gutter, sign, text with word spans in
/// ⟦…⟧, then syntax spans as `kind@start-end` (display UTF-16 indices). Byte-identical to Android.
func diffGolden(_ model: DiffFileModel) -> String {
    var out = ""
    if model.binary { out += "binary\n" }
    for hunk in model.hunks {
        out += hunk.header + "\n"
        for row in hunk.rows {
            out += diffGutter(row, width: model.numberWidth)
            var text = Array(row.text.utf16)
            for w in row.words.sorted(by: { $0.start > $1.start }) {
                text = Array(text[0..<w.start]) + Array("⟦".utf16) + Array(text[w.start..<w.end]) + Array("⟧".utf16) + Array(text[w.end...])
            }
            out += String(decoding: text, as: UTF16.self)
            if !row.syntax.isEmpty { out += "  | " + row.syntax.map { "\($0.kind)@\($0.start)-\($0.end)" }.joined(separator: " ") }
            out += "\n"
        }
    }
    return out
}

private func padStart(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
}

/// `old new s ` gutter: right-aligned one-based numbers (blank when absent) and the change sign.
func diffGutter(_ row: DiffRow, width: Int) -> String {
    if row.kind == "meta" { return String(repeating: " ", count: width * 2 + 4) }
    let sign = row.kind == "add" ? "+" : row.kind == "delete" ? "-" : " "
    return padStart(row.oldLine.map { String($0) } ?? "", width) + " " + padStart(row.newLine.map { String($0) } ?? "", width) + " " + sign + " "
}

/// Card totals from the writer's per-file header counts (web parity).
func diffTotals(_ files: [DiffIndexEntry]) -> (additions: UInt64, deletions: UInt64) {
    files.reduce((UInt64(0), UInt64(0))) { ($0.0 + $1.additions, $0.1 + $1.deletions) }
}
