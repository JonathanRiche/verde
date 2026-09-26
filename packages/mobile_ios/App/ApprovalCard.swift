import SwiftUI
import UIKit

/// Plays approval haptics. Tests replace `perform` to record them.
@MainActor
enum ApprovalHaptics {
    static var perform: (ApprovalFeedback) -> Void = { feedback in
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(feedback == .confirm ? .success : .warning)
    }
}

/// Posts VoiceOver announcements (no-op when VoiceOver is off). Tests replace `post`.
@MainActor
enum ApprovalAnnouncer {
    static var post: (ApprovalAnnouncement) -> Void = { announcement in
        guard UIAccessibility.isVoiceOverRunning else { return }
        let text = NSAttributedString(string: announcement.text, attributes: [
            .accessibilitySpeechAnnouncementPriority: announcement.urgent ? UIAccessibilityPriority.high : UIAccessibilityPriority.default,
        ])
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}

func approvalTitle(_ approval: ChatApproval) -> String {
    approval.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Permission required" : approval.title
}

/// D-09's `approval` renderer: decide inline, with state from the core receipt.
struct ApprovalCard: View {
    let approval: ChatApproval
    let controller: ApprovalController
    let disclosure: DisclosureStore
    @State private var lastPhase: ApprovalPhase?

    var body: some View {
        let phase = approvalPhase(approval, controller.local)
        let preview = approvalPreview(approval)
        let title = approvalTitle(approval)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(Color.orange).frame(width: 9, height: 9).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Approval required").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        .accessibilityLabel("Approval required: \(title)")
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(3)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            ApprovalSummary(preview: preview)
            ApprovalDetails(approval: approval, preview: preview, disclosure: disclosure)
            if let text = phaseText(phase) {
                HStack(spacing: 8) {
                    if case .sending = phase { ProgressView().controlSize(.mini) }
                    Text(text).font(.footnote).foregroundStyle(phase.isFailed ? Color.red : Color.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if phase != .stale && !phase.isSent {
                let sending: ApprovalDecision? = { if case .sending(let d) = phase { return d }; return nil }()
                HStack(spacing: 8) {
                    Spacer()
                    Button { decide(.deny) } label: {
                        Text(sending == .deny ? "Denying…" : "Deny").frame(minWidth: 72, minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Deny: \(title)")
                    Button { decide(.approve) } label: {
                        Text(sending == .approve ? "Approving…" : "Approve").frame(minWidth: 72, minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Approve: \(title)")
                }
                .disabled(!phase.canDecide)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.7)))
        .accessibilityIdentifier("approval-card")
        .onAppear {
            // Announced once when the card appears.
            if lastPhase == nil { ApprovalAnnouncer.post(ApprovalAnnouncement(text: "Approval required: \(title)", urgent: false)) }
            lastPhase = phase
        }
        .onChange(of: phase) { previous, next in
            if let feedback = phaseFeedback(from: previous, to: next) { ApprovalHaptics.perform(feedback) }
            if let announcement = phaseAnnouncement(from: previous, to: next) { ApprovalAnnouncer.post(announcement) }
            lastPhase = next
        }
    }

    private func decide(_ decision: ApprovalDecision) {
        if controller.decide(approval, decision) { ApprovalHaptics.perform(tapFeedback(decision)) }
    }
}

private struct ApprovalSummary: View {
    let preview: ApprovalPreview

    var body: some View {
        if preview.tool != nil || preview.path != nil {
            HStack(spacing: 6) {
                if let tool = preview.tool {
                    Text(tool).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                }
                // Host paths stay abstract on the phone: the file name here, the full request in details.
                if let path = preview.path {
                    Text(basename(path)).font(.footnote.monospaced()).lineLimit(1)
                        .accessibilityLabel("File \(basename(path))")
                }
            }
        }
        if let reason = preview.reason { Text(reason).font(.footnote).lineLimit(4) }
        if let command = preview.command {
            Text("$ \(command)").font(.footnote.monospaced()).lineLimit(6)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Command: \(command)")
        }
        if !preview.changes.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(preview.changes.enumerated()), id: \.offset) { _, line in
                        Text(changePrefix(line.kind) + line.text).font(.footnote.monospaced()).fixedSize()
                            .foregroundStyle(line.kind == .hunk ? Color.secondary : Color.primary)
                            .padding(.horizontal, 10)
                            .background(changeBackground(line.kind))
                    }
                    if preview.changesTruncated { Text("…").font(.footnote.monospaced()).foregroundStyle(.secondary).padding(.horizontal, 10) }
                }
                .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

func changePrefix(_ kind: PreviewKind) -> String {
    switch kind {
    case .add: return "+ "
    case .remove: return "− "
    case .hunk: return ""
    case .context: return "  "
    }
}

private func changeBackground(_ kind: PreviewKind) -> Color {
    switch kind {
    case .add: return Color.green.opacity(0.2)
    case .remove: return Color.red.opacity(0.2)
    default: return .clear
    }
}

private let detailLines = 40

private struct ApprovalDetails: View {
    let approval: ChatApproval
    let preview: ApprovalPreview
    let disclosure: DisclosureStore

    var body: some View {
        if !approval.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Without a structured summary the raw request *is* the summary, so it starts open.
            let structured = preview.command != nil || !preview.changes.isEmpty || preview.tool != nil
            let key = "approval:\(approval.key)"
            let expanded = disclosure.flag(key, !structured)
            let all = disclosure.flag(key + ":all")
            VStack(alignment: .leading, spacing: 4) {
                if structured {
                    Button(expanded ? "▾ Hide full request" : "▸ Show full request") { disclosure.toggle(key, !structured) }
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.vertical, 6)
                }
                if expanded {
                    let (shown, truncated) = all ? (approval.body.trimmingCharacters(in: .whitespacesAndNewlines), false)
                        : leadingLines(approval.body, detailLines)
                    ScrollView(.horizontal) {
                        Text(shown).font(.footnote.monospaced()).fixedSize().textSelection(.enabled)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Approval details")
                    HStack(spacing: 16) {
                        Button("Copy request") { UIPasteboard.general.string = approval.body }
                        if truncated { Button("Show all \(countLines(approval.body)) lines") { disclosure.setFlag(key + ":all", true) } }
                    }
                    .font(.caption)
                }
            }
        }
    }
}

/// Top-of-transcript strip: while an approval is pending and its card is off screen, a tap jumps to
/// it; after an approval leaves, a short notice says how it was resolved.
struct ApprovalBanner: View {
    let approval: ChatApproval?
    let cardVisible: Bool
    let controller: ApprovalController
    let onJump: () -> Void

    var body: some View {
        Group {
            if let approval, !cardVisible {
                let phase = approvalPhase(approval, controller.local)
                Button(action: onJump) {
                    HStack(spacing: 8) {
                        Circle().fill(Color.orange).frame(width: 8, height: 8)
                        Text(phase.canDecide ? "Needs approval · \(approvalTitle(approval))" : phaseText(phase) ?? "Needs approval")
                            .font(.subheadline.weight(.medium)).lineLimit(1)
                        Text("View").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 3)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("approval-banner")
            } else if approval == nil, let outcome = controller.outcome {
                Text(outcome.outcome.text).font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityIdentifier("approval-outcome")
                    .onAppear { ApprovalAnnouncer.post(ApprovalAnnouncement(text: outcome.outcome.text, urgent: false)) }
                    .id(outcome.serial)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}
