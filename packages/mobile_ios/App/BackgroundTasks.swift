import SwiftUI

/*
 * U1: background commands as the desktop shows them (core C10). Each task is one compact row (a
 * terminal glyph, its label in mono, a status and its age); a tap shows the full command with
 * Copy. Consecutive finished tasks share one compact list. Running tasks are also pinned in a
 * slim bar above the composer. The core's task id, log, PID and stop lines are never shown.
 */

/// The status glyph: a spinner while running, ✓, ✕, or a stop square.
struct BackgroundStatusIcon: View {
    let status: String?
    @ScaledMetric(relativeTo: .footnote) private var glyph: CGFloat = 11
    @ScaledMetric(relativeTo: .footnote) private var box: CGFloat = 16

    var body: some View {
        Group {
            switch status ?? "" {
            case "running": ProgressView().controlSize(.mini)
            case "failed": Image(systemName: "xmark").font(.system(size: glyph, weight: .bold)).accessibilityHidden(true)
            case "stopped": Image(systemName: "stop.fill").font(.system(size: glyph * 0.9, weight: .bold)).accessibilityHidden(true)
            default: Image(systemName: "checkmark").font(.system(size: glyph, weight: .bold)).accessibilityRemoveTraits(.isSelected).accessibilityHidden(true)
            }
        }
        .foregroundStyle(backgroundStatusColor(status))
        .frame(width: box, height: box)
        .accessibilityRemoveTraits(.isSelected)
        .accessibilityHidden(true)
    }
}

func backgroundStatusColor(_ status: String?) -> Color {
    switch status ?? "" {
    case "running", "completed": return VerdeTheme.accent
    case "failed": return VerdeTheme.danger
    default: return VerdeTheme.muted
    }
}

/// The time a row names: when it finished, else when it started.
private func backgroundAge(_ row: ChatRow, now: Int64) -> String? {
    (row.background?.finished_at_ms ?? row.background?.started_at_ms ?? row.created_at_ms).map { agoLabel($0, now) }
}

/// The command and Copy, shown under an expanded task.
private struct BackgroundCommand: View {
    let row: ChatRow
    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Text(row.body).font(VerdeTheme.mono(12)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(VerdeTheme.alternate, in: RoundedRectangle(cornerRadius: 8))
            CopyIconButton(label: "Copy command") { row.body }
        }
    }
}

/// The flag that flashes a task's row after the bar scrolls to it (I14-2).
func backgroundHighlightKey(_ rowID: String) -> String { rowID + ":highlight" }

/// One task, or a run of finished ones, in the transcript.
struct BackgroundTaskCard: View {
    let rows: [ChatRow]
    let disclosure: DisclosureStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = Int64(context.date.timeIntervalSince1970 * 1000)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().overlay(VerdeTheme.border) }
                    if rows.count == 1 { single(row, now: now) } else { line(row, now: now) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? VerdeTheme.accent.opacity(0.14) : VerdeTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(highlighted ? VerdeTheme.accent : VerdeTheme.border, lineWidth: highlighted ? 2 : 1))
            .animation(.easeOut(duration: 0.25), value: highlighted)
        }
        .accessibilityIdentifier("background-task")
    }

    private func key(_ row: ChatRow) -> String { row.id + ":background" }
    private var highlighted: Bool { rows.contains { disclosure.flag(backgroundHighlightKey($0.id)) } }

    /// The status and age, never broken mid-word (I14-1): one line each, shrinking a little.
    private func statusLine(_ row: ChatRow, now: Int64) -> some View {
        let status = row.background?.status
        return HStack(spacing: 6) {
            BackgroundStatusIcon(status: status)
            Text(backgroundStatusText(status)).font(VerdeTheme.ui(12, bold: true)).foregroundStyle(backgroundStatusColor(status))
                .lineLimit(1).minimumScaleFactor(0.8).fixedSize(horizontal: true, vertical: false)
            if let age = backgroundAge(row, now: now) {
                Text(age).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }

    /// "▸ pytest -q    ◌ Running · 3 min ago".
    private func single(_ row: ChatRow, now: Int64) -> some View {
        let expanded = disclosure.flag(key(row))
        let status = row.background?.status
        return VStack(alignment: .leading, spacing: 8) {
            Button { disclosure.toggle(key(row)) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "terminal").foregroundStyle(VerdeTheme.muted).accessibilityHidden(true)
                    if dynamicTypeSize.isAccessibilitySize {
                        // Large text: the label on top, the status under it, so neither is cut.
                        VStack(alignment: .leading, spacing: 4) {
                            Text(backgroundLabel(row)).font(VerdeTheme.mono(12)).lineLimit(2).truncationMode(.middle)
                            statusLine(row, now: now)
                        }
                        Spacer(minLength: 4)
                    } else {
                        // S36: up to two lines before the middle ellipsis.
                        Text(backgroundLabel(row)).font(VerdeTheme.mono(12)).lineLimit(2).truncationMode(.middle)
                        Spacer(minLength: 8)
                        statusLine(row, now: now)
                    }
                    DisclosureChevron(expanded: expanded)
                }
                .padding(.vertical, 4)
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Background task, \(backgroundLabel(row)), \(backgroundStatusText(status))\(backgroundAge(row, now: now).map { ", " + $0 } ?? "")")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Hides the command." : "Shows the command.")
            if expanded { BackgroundCommand(row: row) }
        }
        .padding(.horizontal, 12).padding(.vertical, 2)
        .padding(.bottom, expanded ? 10 : 0)
    }

    /// "✓ pytest -q finished · 1 h ago" in a compact list.
    private func line(_ row: ChatRow, now: Int64) -> some View {
        let expanded = disclosure.flag(key(row))
        let status = row.background?.status
        let tail = " " + backgroundStatusText(status).lowercased() + (backgroundAge(row, now: now).map { " · " + $0 } ?? "")
        return VStack(alignment: .leading, spacing: 8) {
            Button { disclosure.toggle(key(row)) } label: {
                HStack(spacing: 8) {
                    BackgroundStatusIcon(status: status)
                    (Text(backgroundLabel(row)).font(VerdeTheme.mono(12)) + Text(tail).font(VerdeTheme.ui(12)).foregroundColor(VerdeTheme.muted))
                        .lineLimit(2).truncationMode(.middle)
                    Spacer(minLength: 4)
                    DisclosureChevron(expanded: expanded)
                }
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(backgroundListLine(row, now: now))
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded { BackgroundCommand(row: row) }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, expanded ? 10 : 0)
    }
}

/// "2 background tasks running" above the composer; a tap shows the first one. No stop action.
struct BackgroundTasksBar: View {
    let tasks: [ChatBackgroundTask]
    let show: (ChatBackgroundTask) -> Void

    var body: some View {
        if let first = tasks.first {
            Button { show(first) } label: {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    // I14-1: wraps at large text rather than being cut off.
                    Text(backgroundBarText(tasks.count)).font(VerdeTheme.ui(13, bold: true)).lineLimit(2).minimumScaleFactor(0.85)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up").font(.caption.weight(.semibold)).foregroundStyle(VerdeTheme.muted)
                }
                .padding(.horizontal, 14).padding(.vertical, 4).frame(minHeight: 44).contentShape(Rectangle())
                .background(VerdeTheme.panel, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(VerdeTheme.border))
            }
            .buttonStyle(.plain)
            .foregroundStyle(VerdeTheme.text)
            .padding(.horizontal, 12).padding(.bottom, 6)
            .accessibilityHint("Shows the running task in the transcript.")
            .accessibilityIdentifier("background-tasks-bar")
        }
    }
}
