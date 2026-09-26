import SwiftUI
import UIKit

/// Block model built from the core's K-11 markdown AST. There is deliberately no Swift markdown
/// parser: when the core cannot render a body (too large, query failure) the source is shown as text.
indirect enum MdBlock: Equatable {
    case paragraph(AttributedString)
    case heading(Int, AttributedString)
    case bullets(ordered: Bool, items: [[MdBlock]])
    case quote([MdBlock])
    case code(String, language: String?)
    case rule
    case table([[AttributedString]])

    var kindName: String {
        switch self {
        case .paragraph: return "Paragraph"
        case .heading: return "Heading"
        case .bullets: return "Bullets"
        case .quote: return "Quote"
        case .code: return "Code"
        case .rule: return "Rule"
        case .table: return "Table"
        }
    }
}

/// A finished render query; `value == nil` means "render the source text as-is".
struct RenderResult<T> {
    let value: T?
    init(_ value: T?) { self.value = value }
}

/// K-11 `highlight` queries for code blocks; the transcript (and later the I-09 file viewer) supply one.
@MainActor
protocol HighlightSource: AnyObject {
    func cachedHighlight(_ code: String, language: String) -> RenderResult<[RenderSpan]>?
    func highlight(_ code: String, language: String) async -> RenderResult<[RenderSpan]>
}

/// Only the link schemes the core admits are ever made tappable.
func safeLinkUrl(_ url: String?) -> URL? {
    guard let value = url?.trimmingCharacters(in: .whitespacesAndNewlines), let colon = value.firstIndex(of: ":") else { return nil }
    guard ["http", "https", "mailto"].contains(value[..<colon].lowercased()) else { return nil }
    return URL(string: value)
}

func citationLabel(_ citation: FileCitation) -> String {
    var label = basename(citation.path)
    if let line = citation.line {
        label += ":\(line)"
        if let end = citation.end_line, end > line { label += "-\(end)" }
    }
    return label
}

/// File citations travel inside the attributed text as private `verde-citation:` links and are
/// routed back through the transcript's `OpenURLAction`; they are never opened by the system.
let citationScheme = "verde-citation"

func citationURL(_ citation: FileCitation) -> URL? {
    var components = URLComponents()
    components.scheme = citationScheme
    var items = [URLQueryItem(name: "path", value: citation.path)]
    if let line = citation.line { items.append(URLQueryItem(name: "line", value: String(line))) }
    if let end = citation.end_line { items.append(URLQueryItem(name: "end", value: String(end))) }
    components.queryItems = items
    return components.url
}

func citation(from url: URL) -> FileCitation? {
    guard url.scheme == citationScheme,
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
          let path = items.first(where: { $0.name == "path" })?.value else { return nil }
    func number(_ name: String) -> UInt64? { items.first { $0.name == name }?.value.flatMap(UInt64.init) }
    return FileCitation(path: path, line: number("line"), end_line: number("end"))
}

// MARK: - AST → blocks

func markdownBlocks(_ nodes: [MarkdownNode]) -> [MdBlock] {
    var out: [MdBlock] = []
    for node in nodes { block(node, into: &out) }
    return out
}

private func block(_ node: MarkdownNode, into out: inout [MdBlock]) {
    switch node.kind {
    case "document": node.children.forEach { block($0, into: &out) }
    case "paragraph": out.append(.paragraph(inline(node.children)))
    case "heading": out.append(.heading(min(max(Int(node.level ?? 1), 1), 6), inline(node.children)))
    case "list":
        out.append(.bullets(ordered: node.ordered == true, items: node.children.map { item in
            var blocks: [MdBlock] = []
            if item.kind == "item" { item.children.forEach { block($0, into: &blocks) } } else { block(item, into: &blocks) }
            return blocks
        }))
    case "quote": out.append(.quote(markdownBlocks(node.children)))
    case "code_block":
        let language = node.language?.trimmingCharacters(in: .whitespaces)
        out.append(.code(node.text ?? "", language: language?.isEmpty == false ? node.language : nil))
    case "thematic_break": out.append(.rule)
    case "table":
        out.append(.table(node.children.filter { $0.kind == "table_row" }.map { row in row.children.map { inline($0.children) } }))
    default:
        // Inline content at block level (e.g. a bare image) becomes its own paragraph.
        out.append(.paragraph(inline([node])))
    }
}

private struct InlineStyle {
    var intent: InlinePresentationIntent = []
    var strike = false
    var underline = false
    var code = false
    var link: URL?
}

private typealias SwiftUIKeys = AttributeScopes.SwiftUIAttributes
private typealias FoundationKeys = AttributeScopes.FoundationAttributes

let inlineCodeBackground = Color(uiColor: .tertiarySystemFill)

private func inline(_ nodes: [MarkdownNode]) -> AttributedString {
    var out = AttributedString()
    for node in nodes { appendInline(node, InlineStyle(), into: &out) }
    return out
}

private func appendInline(_ node: MarkdownNode, _ style: InlineStyle, into out: inout AttributedString) {
    func run(_ text: String, _ s: InlineStyle) {
        guard !text.isEmpty else { return }
        var c = AttributeContainer()
        if !s.intent.isEmpty { c[FoundationKeys.InlinePresentationIntentAttribute.self] = s.intent }
        if s.strike { c[SwiftUIKeys.StrikethroughStyleAttribute.self] = .single }
        if s.underline || s.link != nil { c[SwiftUIKeys.UnderlineStyleAttribute.self] = .single }
        if s.code { c[SwiftUIKeys.BackgroundColorAttribute.self] = inlineCodeBackground }
        if let link = s.link { c[FoundationKeys.LinkAttribute.self] = link }
        out.append(AttributedString(text, attributes: c))
    }
    func children(_ s: InlineStyle) { node.children.forEach { appendInline($0, s, into: &out) } }
    var s = style
    switch node.kind {
    case "text": run(node.text ?? "", style)
    case "emphasis": s.intent.insert(.emphasized); children(s)
    case "strong": s.intent.insert(.stronglyEmphasized); children(s)
    case "strike": s.strike = true; children(s)
    case "code": s.intent.insert(.code); s.code = true; run(node.text ?? "", s)
    case "line_break": run("\n", style)
    case "link":
        if let citation = node.citation, let url = citationURL(citation) {
            s.link = url
            if node.children.isEmpty { run(citationLabel(citation), s) } else { children(s) }
        } else if let url = safeLinkUrl(node.url) {
            s.link = url; children(s)
        } else {
            s.underline = true; children(s)
        }
    case "image":
        // Remote images are never fetched; the alt text stands in.
        s.intent.insert(.emphasized)
        run("[image", s)
        if !node.children.isEmpty { run(": ", s); children(s) }
        run("]", s)
    default: children(style)
    }
}

// MARK: - K-11 spans

/// Maps every UTF-8 byte offset of `text` to its UTF-16 index (continuation bytes map to the start
/// of their character), so K-11 byte spans can style a Swift string. Same table as Android's.
func utf8ToUtf16(_ text: String) -> [Int] {
    var out: [Int] = []
    out.reserveCapacity(text.utf8.count + 1)
    var index = 0
    for scalar in text.unicodeScalars {
        for _ in 0..<UTF8.width(scalar) { out.append(index) }
        index += UTF16.width(scalar)
    }
    out.append(index)
    return out
}

/// A styled range, in UTF-16 indices.
struct DiffRange: Equatable {
    let start: Int
    let end: Int
    let kind: String
}

/// K-11 byte spans mapped to UTF-16 ranges of `text` (clamped; empty ranges dropped).
func highlightRanges(_ text: String, _ spans: [RenderSpan]) -> [DiffRange] {
    if spans.isEmpty { return [] }
    let map = utf8ToUtf16(text)
    let last = UInt64(map.count - 1)
    return spans.compactMap { span in
        let start = map[Int(min(span.start, last))], end = map[Int(min(span.end, last))]
        return end > start ? DiffRange(start: start, end: end, kind: span.kind) : nil
    }
}

struct StyledRange {
    let start: Int
    let end: Int
    let attributes: AttributeContainer
}

/// Builds `text` with attribute ranges (UTF-16 indices on scalar boundaries). Overlaps merge in
/// range order. One sweep, so thousands of highlight spans stay linear.
func styledText(_ text: String, _ ranges: [StyledRange]) -> AttributedString {
    let units = Array(text.utf16)
    let count = units.count
    let valid = ranges.enumerated().compactMap { index, r -> (Int, Int, Int)? in
        let s = min(max(r.start, 0), count), e = min(max(r.end, 0), count)
        return e > s ? (index, s, e) : nil
    }
    if valid.isEmpty { return AttributedString(text) }
    var cuts = Set([0, count])
    for (_, s, e) in valid { cuts.insert(s); cuts.insert(e) }
    let sortedCuts = cuts.sorted()
    let byStart = valid.sorted { $0.1 < $1.1 }
    var next = 0
    var active: [(Int, Int, Int)] = []
    var out = AttributedString()
    for (a, b) in zip(sortedCuts, sortedCuts.dropFirst()) {
        active.removeAll { $0.2 <= a }
        while next < byStart.count && byStart[next].1 <= a { active.append(byStart[next]); next += 1 }
        let segment = String(decoding: units[a..<b], as: UTF16.self)
        if active.isEmpty { out.append(AttributedString(segment)); continue }
        var attributes = AttributeContainer()
        for (index, _, _) in active.sorted(by: { $0.0 < $1.0 }) { attributes = attributes.merging(ranges[index].attributes) }
        out.append(AttributedString(segment, attributes: attributes))
    }
    return out
}

/// Syntax colours for K-11 token kinds (nil: unstyled).
func tokenAttributes(_ kind: String) -> AttributeContainer? {
    var c = AttributeContainer()
    func color(_ value: Color) { c[SwiftUIKeys.ForegroundColorAttribute.self] = value }
    switch kind {
    case "keyword": color(.accentColor); c[FoundationKeys.InlinePresentationIntentAttribute.self] = .stronglyEmphasized
    case "string": color(Color(uiColor: .systemGreen))
    case "number", "constant_name": color(Color(uiColor: .systemOrange))
    case "comment": color(.secondary); c[FoundationKeys.InlinePresentationIntentAttribute.self] = .emphasized
    case "type_name": color(Color(uiColor: .systemPurple))
    case "function_name": color(Color(uiColor: .systemBlue))
    case "property_name": color(Color(uiColor: .systemIndigo))
    case "operator", "punctuation": color(.secondary)
    default: return nil
    }
    return c
}

/// `code` coloured by the core's highlight spans.
func highlighted(_ code: String, _ spans: [RenderSpan]) -> AttributedString {
    styledText(code, highlightRanges(code, spans).compactMap { range in
        tokenAttributes(range.kind).map { StyledRange(start: range.start, end: range.end, attributes: $0) }
    })
}

// MARK: - Views

/// Renders `text` from the core's markdown AST, falling back to the literal source.
struct MarkdownText: View {
    let text: String
    let model: TranscriptModel
    @State private var result: RenderResult<[MdBlock]>?

    var body: some View {
        // A newer body keeps showing the previous render until its own arrives (no plain flash
        // while streaming); a cached render is used at once.
        let current = model.cachedMarkdown(text) ?? result
        Group {
            if let blocks = current?.value {
                MarkdownBlocks(blocks: blocks, source: model).accessibilityIdentifier("markdown")
            } else {
                // Pending (first frame) or unrenderable: the source text, never re-parsed in Swift.
                Text(text).font(.body).textSelection(.enabled).accessibilityIdentifier("plain-text")
            }
        }
        .task(id: text) { result = await model.markdown(text) }
    }
}

struct MarkdownBlocks: View {
    let blocks: [MdBlock]
    let source: HighlightSource

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in MdBlockView(block: block, source: source) }
        }
    }
}

private struct MdBlockView: View {
    let block: MdBlock
    let source: HighlightSource

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(text).font(.body).frame(maxWidth: .infinity, alignment: .leading)
        case .heading(let level, let text):
            Text(text).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        case .bullets(let ordered, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(ordered ? "\(index + 1)." : "•").font(.body).frame(minWidth: 20, alignment: .leading)
                        MarkdownBlocks(blocks: item, source: source)
                    }
                }
            }
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color(uiColor: .separator)).frame(width: 3)
                MarkdownBlocks(blocks: blocks, source: source)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let code, let language):
            CodeBlock(code: code, language: language, source: source)
        case .rule:
            Divider()
        case .table(let rows):
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell).font(index == 0 ? .subheadline.weight(.semibold) : .footnote)
                                    .frame(width: 140, alignment: .leading).padding(6)
                            }
                        }
                        if index < rows.count - 1 { Divider() }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(uiColor: .separator)))
            }
        }
    }
}

struct CodeBlock: View {
    let code: String
    let language: String?
    let source: HighlightSource
    @State private var spans: RenderResult<[RenderSpan]>?

    private var key: String { (language ?? "") + "\u{0}" + code }

    var body: some View {
        let current = language.flatMap { source.cachedHighlight(code, language: $0) } ?? spans
        // Spans index the exact code the core highlighted; only the trailing newline is dropped for display.
        var text = highlighted(code, current?.value ?? [])
        if code.hasSuffix("\n"), let last = text.characters.indices.last { text.removeSubrange(last...) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Copy code") { UIPasteboard.general.string = code.hasSuffix("\n") ? String(code.dropLast()) : code }
                    .font(.caption)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.system(.footnote, design: .monospaced)).fixedSize()
                    .padding(.horizontal, 10).padding(.bottom, 10)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("code-block")
        .task(id: key) {
            guard let language else { return }
            spans = await source.highlight(code, language: language)
        }
    }
}
