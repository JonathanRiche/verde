import SwiftUI
import UIKit

/*
 * Transcript tool calls (desktop ToolRow parity, S2): a per-kind icon, a semibold title, a one-line
 * mono summary, the status as an icon and colour, and a chevron. The whole row toggles; expanded
 * rows show labelled Input / Output / Error sections, with an Edit's unified diff in the patch
 * view's colours and a Copy button in the expanded header. Tool bodies are never logged.
 */

private let toolPreviewLines = 40

/// Running spinner, ✓ or ✕; the label always names the status.
struct ToolStatusIcon: View {
    let failed: Bool
    let running: Bool

    var body: some View {
        Group {
            if running {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: failed ? "xmark" : "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(failed ? VerdeTheme.danger : VerdeTheme.accent)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

/// The disclosure chevron: rotates when open, hidden from VoiceOver (the row says expanded).
struct DisclosureChevron: View {
    let expanded: Bool
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(VerdeTheme.muted)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .frame(width: 16)
            .accessibilityHidden(true)
    }
}

/// A 44-point icon-only Copy button.
struct CopyIconButton: View {
    let label: String
    let text: () -> String

    var body: some View {
        Button { UIPasteboard.general.string = text() } label: {
            Image(systemName: "doc.on.doc").font(.system(size: 14)).foregroundStyle(VerdeTheme.muted).minTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// One tool call. `child` rows sit inside a group as hairline-separated rows; a lone call is a card.
struct ToolCard: View {
    let row: ChatRow
    let child: Bool
    let disclosure: DisclosureStore
    /// Highlights a Read's file output in the shared syntax palette (S13).
    var source: HighlightSource? = nil
    @Environment(\.compactChat) private var compact

    var body: some View {
        let key = "\(row.id):tool"
        let failed = commandFailed(row)
        let expanded = disclosure.flag(key, failed)
        let parts = toolParts(row)
        VStack(alignment: .leading, spacing: 0) {
            ToolHeader(parts: parts, failed: failed, running: commandRunning(row), expanded: expanded, compact: compact,
                       toggle: { disclosure.toggle(key, failed) }, copy: { toolCopyText(row) })
            if expanded {
                ToolDetails(parts: parts, rowID: row.id, disclosure: disclosure, source: source)
                    .padding(.horizontal, compact ? 2 : 12).padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay { outline(failed: failed) }
    }

    private var cardFill: Color { compact || child ? Color.clear : VerdeTheme.assistant }

    @ViewBuilder private func outline(failed: Bool) -> some View {
        if !compact {
            if failed { RoundedRectangle(cornerRadius: 10).stroke(VerdeTheme.danger.opacity(0.7)) }
            else if !child { RoundedRectangle(cornerRadius: 10).stroke(commandRunning(row) ? VerdeTheme.accent : VerdeTheme.border) }
        }
    }
}

private struct ToolHeader: View {
    let parts: ToolParts
    let failed: Bool
    let running: Bool
    let expanded: Bool
    let compact: Bool
    let toggle: () -> Void
    let copy: () -> String

    private var status: String { failed ? "Failed" : running ? "Running" : "Completed" }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggle) { label }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint(expanded ? "Collapse" : "Expand")
                .accessibilityAddTraits(.isButton)
            if expanded { CopyIconButton(label: "Copy tool call", text: copy) }
        }
    }

    private var accessibilityText: String {
        parts.summary.isEmpty ? "\(parts.title), \(status)" : "\(parts.title), \(parts.summary), \(status)"
    }

    private var label: some View {
        HStack(spacing: 10) {
            Image(systemName: toolSymbol(parts.kind))
                .font(.system(size: 14))
                .foregroundStyle(failed ? VerdeTheme.danger : VerdeTheme.muted)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(parts.title).font(VerdeTheme.ui(13, bold: true)).lineLimit(1)
                if !parts.summary.isEmpty {
                    Text(parts.summary).font(VerdeTheme.mono(12)).foregroundStyle(VerdeTheme.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ToolStatusIcon(failed: failed, running: running)
            DisclosureChevron(expanded: expanded)
        }
        .padding(.leading, compact ? 2 : 12).padding(.trailing, expanded ? 0 : (compact ? 2 : 12))
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// Labelled sections of an expanded call; each long section shows its first lines until asked.
private struct ToolDetails: View {
    let parts: ToolParts
    let rowID: String
    let disclosure: DisclosureStore
    let source: HighlightSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let input = parts.input { section("Input", input, key: "input") }
            if let output = parts.output { section("Output", output, key: "output", diff: toolOutputIsDiff(parts), language: toolOutputLanguage(parts)) }
            if let error = parts.error { section("Error", error, key: "error", error: true) }
            if parts.input == nil && parts.output == nil && parts.error == nil {
                Text("No output").font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted)
            }
        }
    }

    private func section(_ title: String, _ text: String, key: String, diff: Bool = false, error: Bool = false, language: String? = nil) -> some View {
        let flag = "\(rowID):tool:\(key):all"
        let all = disclosure.flag(flag)
        let cut = all ? (text, false) : leadingLines(text, toolPreviewLines)
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(VerdeTheme.ui(11, bold: true)).foregroundStyle(error ? VerdeTheme.danger : VerdeTheme.muted)
                .accessibilityAddTraits(.isHeader)
            ToolText(text: cut.0, diff: diff, error: error, language: language, source: source)
            if cut.1 {
                Button("Show all \(countLines(text)) lines") { disclosure.setFlag(flag, true) }
                    .font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.accent)
                    .buttonStyle(.plain).frame(minHeight: 44)
            }
        }
    }
}

/// Mono, selectable, scrolling sideways inside a rounded well.
private struct ToolText: View {
    let text: String
    let diff: Bool
    let error: Bool
    var language: String? = nil
    var source: HighlightSource? = nil
    @State private var spans: RenderResult<[RenderSpan]>?

    var body: some View {
        ScrollView(.horizontal) {
            content
                .font(VerdeTheme.mono(12))
                .fixedSize()
                .textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VerdeTheme.alternate, in: RoundedRectangle(cornerRadius: 8))
        .task(id: (language ?? "") + "\u{0}" + text) {
            guard let language, let source, !diff, !error else { return }
            spans = await source.highlight(text, language: language)
        }
    }

    private var current: [RenderSpan]? {
        guard let language, let source else { return nil }
        return (source.cachedHighlight(text, language: language) ?? spans)?.value
    }

    @ViewBuilder private var content: some View {
        if diff { Text(toolDiffText(text)) }
        else if !error, let current { Text(highlighted(text, current)).foregroundStyle(VerdeTheme.text) }
        else { Text(text).foregroundStyle(error ? VerdeTheme.danger : VerdeTheme.text) }
    }
}

/// Unified diff lines in the patch view's palette.
func toolDiffText(_ text: String) -> AttributedString {
    var out = AttributedString()
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    for (index, line) in lines.enumerated() {
        var piece = AttributedString(String(line) + (index < lines.count - 1 ? "\n" : ""))
        switch toolDiffLine(line) {
        case .hunk:
            piece.foregroundColor = VerdeTheme.muted
            piece.backgroundColor = hunkBackground
        case .add:
            piece.foregroundColor = addColor
            piece.backgroundColor = addColor.opacity(0.12)
        case .delete:
            piece.foregroundColor = deleteColor
            piece.backgroundColor = deleteColor.opacity(0.12)
        case .context:
            piece.foregroundColor = VerdeTheme.text
        }
        out.append(piece)
    }
    return out
}

/// Two or more calls (or subagents) behind one header: a few kind icons, "4 tool calls · 1 failed".
struct ToolGroupCard: View {
    let id: String
    let rows: [ChatRow]
    let subagent: Bool
    let turnStartedAt: Int64?
    let disclosure: DisclosureStore
    var source: HighlightSource? = nil
    @Environment(\.compactChat) private var compact

    var body: some View {
        let counts = toolCounts(rows)
        let expanded = disclosure.flag(id, counts.failed > 0)
        VStack(alignment: .leading, spacing: 0) {
            Button { disclosure.toggle(id, counts.failed > 0) } label: { header(counts, expanded: expanded) }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint(expanded ? "Collapse" : "Expand")
            if expanded { children }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(compact ? Color.clear : VerdeTheme.assistant, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            // One outline: the failing child carries the error outline, not the group too.
            if !compact { RoundedRectangle(cornerRadius: 10).stroke(counts.running > 0 && counts.failed == 0 ? VerdeTheme.accent : VerdeTheme.border) }
        }
    }

    private var children: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().overlay(VerdeTheme.border.opacity(0.6)).padding(.leading, compact ? 0 : 42) }
                ToolCard(row: row, child: true, disclosure: disclosure, source: source)
            }
        }
        .padding(.leading, compact ? 12 : 0).padding(.bottom, compact ? 2 : 4)
        .overlay(alignment: .top) { if !compact { Divider().overlay(VerdeTheme.border.opacity(0.6)) } }
    }

    private func header(_ counts: ToolCounts, expanded: Bool) -> some View {
        HStack(spacing: 10) {
            ToolIconStack(kinds: rows.map(toolKind))
            // Only a running group ticks; finished groups never schedule a timeline.
            TimelineView(.periodic(from: .now, by: counts.running > 0 && turnStartedAt != nil ? 1 : 3600)) { context in
                Text(toolGroupSummary(rows, subagent: subagent,
                                      elapsed: turnStartedAt.map { elapsedLabel($0, Int64(context.date.timeIntervalSince1970 * 1000)) }))
                    .font(VerdeTheme.ui(13, bold: true)).foregroundStyle(counts.failed > 0 ? VerdeTheme.danger : VerdeTheme.text)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ToolStatusIcon(failed: counts.failed > 0, running: counts.running > 0)
            DisclosureChevron(expanded: expanded)
        }
        .padding(.horizontal, compact ? 2 : 12).padding(.vertical, 6)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// Up to three distinct kind icons, overlapping slightly.
private struct ToolIconStack: View {
    let kinds: [String]

    var body: some View {
        let distinct = kinds.reduce(into: [String]()) { out, kind in if !out.contains(kind) { out.append(kind) } }
        HStack(spacing: -4) {
            ForEach(Array(distinct.prefix(3)), id: \.self) { kind in
                Image(systemName: toolSymbol(kind)).font(.system(size: 10))
                    .foregroundStyle(VerdeTheme.muted)
                    .frame(width: 18, height: 18)
                    .background(VerdeTheme.alternate, in: Circle())
                    .overlay(Circle().stroke(VerdeTheme.assistant, lineWidth: 1))
            }
        }
        .frame(minWidth: 20, alignment: .leading)
        .accessibilityHidden(true)
    }
}
