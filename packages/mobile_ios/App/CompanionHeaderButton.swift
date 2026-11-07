import SwiftUI
import UIKit

/*
 * The Companion docked into a screen's top bar. The floating bubble stays on the top-level lists
 * (Home, Workspaces, Hosts); every pushed screen shows this 40-point avatar instead, so the bubble
 * never covers a transcript, a diff or an approval. Same actions as the bubble: tap opens the
 * Companion, a double tap starts Live (a tap ends it), touch and hold talks.
 */

/// What the header avatar needs from the root view. Nil while the bubble is off (hidden, a
/// docked companion pane on wide windows, or no companion on this host).
struct CompanionHeaderEntry {
    let model: CompanionModel
    let voice: CompanionVoice
    let live: LiveVoice
    let open: () -> Void
    let settings: () -> Void
}

private struct CompanionEntryKey: EnvironmentKey { static let defaultValue: CompanionHeaderEntry? = nil }

extension EnvironmentValues {
    var companionEntry: CompanionHeaderEntry? {
        get { self[CompanionEntryKey.self] }
        set { self[CompanionEntryKey.self] = newValue }
    }
}

/// The floating bubble shows only on the top-level lists; pushed screens dock it in their top bar.
func floatingBubbleAllowed(tab: RootTab, pathDepth: Int) -> Bool { !tab.showsBrowse || pathDepth == 0 }

/// Adds the header avatar as the screen's leading trailing-bar item. Screens with a "⋯" menu
/// place `CompanionHeaderButton` themselves, just before it.
struct CompanionToolbar: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar { ToolbarItem(placement: .topBarTrailing) { CompanionHeaderButton() } }
    }
}

/// Home, Workspaces, Hosts and Settings beside a hidden sidebar: no bubble floats there on wide
/// windows, so the header carries the avatar (U1 iPad). Phones keep their floating bubble.
struct RootCompanionToolbar: ViewModifier {
    var enabled = true
    @Environment(\.adaptive) private var adaptive
    func body(content: Content) -> some View {
        content.toolbar {
            if enabled && adaptive.tier.docked { ToolbarItem(placement: .topBarTrailing) { CompanionHeaderButton() } }
        }
    }
}

struct CompanionHeaderButton: View {
    /// The chat on screen; the avatar stays off the companion's own conversation.
    var workspace: String? = nil
    var thread: String? = nil
    @Environment(\.companionEntry) private var entry
    @AppStorage(CompanionBubbleStore.hiddenKey) private var hidden = false

    var body: some View {
        if let entry, !hidden, let active = entry.model.active, !ownChat(entry.model) {
            CompanionHeaderFace(entry: entry, active: active)
        }
    }

    private func ownChat(_ model: CompanionModel) -> Bool {
        guard let conversation = model.conversation, let workspace, let thread else { return false }
        return conversation.workspace == workspace && conversation.thread == thread
    }
}

private struct CompanionHeaderFace: View {
    let entry: CompanionHeaderEntry
    let active: RosterEntry
    @State private var press: PressIntent?
    @State private var pressStart = Date()
    @State private var holdTask: Task<Void, Never>?
    @State private var tapTask: Task<Void, Never>?
    @State private var cancelArmed = false

    private static let diameter: CGFloat = 40

    var body: some View {
        let badge = entry.model.badgeCount
        let failed = entry.model.failedCount
        face
            .overlay(alignment: .topTrailing) { badgeView(badge, failed: failed) }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in changed(value) }
                .onEnded { value in ended(value) })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(bubbleAccessibilityLabel(name: active.name, count: badge, failed: failed))
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(entry.live.active ? "Ends the live conversation." : "Opens your companion. Touch and hold to talk, or use the Talk live action.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if entry.live.active { entry.live.end() } else { entry.open() } }
            .accessibilityAction(named: entry.live.active ? "End live conversation" : "Talk live") { entry.live.toggle() }
            .accessibilityAction(named: "Settings") { entry.settings() }
            .accessibilityIdentifier("companion-header")
    }

    private var accessibilityValue: String {
        if entry.live.active { return "Live conversation" }
        if entry.voice.listening { return "Listening" }
        return entry.voice.speaking ? "Speaking" : entry.model.accessibilityStatus
    }

    private var ring: Color {
        if press == .talk { return cancelArmed ? VerdeTheme.danger : VerdeTheme.accent }
        return entry.live.active ? VerdeTheme.accent : VerdeTheme.border
    }

    private var face: some View {
        let presence = entry.model.presence
        let d = Self.diameter
        return ZStack {
            Circle().fill(VerdeTheme.panel)
            Circle().stroke(ring, lineWidth: press == .talk || entry.live.active ? 2 : 1)
            CompanionAvatar(character: active.character, pose: presence.pose, failure: presence.failure, width: d * 0.62)
        }
        .frame(width: d, height: d)
    }

    @ViewBuilder private func badgeView(_ badge: Int, failed: Int) -> some View {
        if badge == 0 && failed > 0 {
            Circle().fill(VerdeTheme.danger).frame(width: 10, height: 10)
                .overlay(Circle().stroke(VerdeTheme.panel, lineWidth: 1.5))
                .offset(x: 1, y: 1)
                .accessibilityHidden(true)
        } else if badge > 0 {
            Text(badge > 99 ? "99+" : "\(badge)")
                .font(VerdeTheme.ui(10, bold: true)).foregroundStyle(Color.white)
                .padding(.horizontal, 4).frame(minWidth: 17, minHeight: 17)
                .background(VerdeTheme.danger, in: Capsule())
                .overlay(Capsule().stroke(VerdeTheme.panel, lineWidth: 1.5))
                .offset(x: 2, y: -1)
                .accessibilityHidden(true)
        }
    }

    private func distance(_ value: DragGesture.Value) -> CGFloat {
        (value.translation.width * value.translation.width + value.translation.height * value.translation.height).squareRoot()
    }

    private func changed(_ value: DragGesture.Value) {
        if press == nil {
            press = .undecided
            pressStart = Date()
            cancelArmed = false
            holdTask?.cancel()
            if !entry.live.active {
                holdTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(Int(PressRules.holdDelay * 1000)))
                    guard !Task.isCancelled, press == .undecided else { return }
                    startTalking()
                }
            }
        }
        if press == .talk { cancelArmed = talkCancelled(distance: distance(value)) }
        else if press == .undecided && distance(value) > PressRules.slop { press = .reposition; holdTask?.cancel() }
    }

    private func startTalking() {
        holdTask?.cancel()
        press = .talk
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { @MainActor in
            if !(await entry.voice.start()) { UINotificationFeedbackGenerator().notificationOccurred(.error) }
        }
    }

    private func ended(_ value: DragGesture.Value) {
        holdTask?.cancel()
        let intent = press ?? .undecided
        let cancelled = cancelArmed || talkCancelled(distance: distance(value))
        press = nil
        cancelArmed = false
        switch intent {
        case .talk:
            if cancelled { entry.voice.cancel(); return }
            Task { @MainActor in
                if let text = await entry.voice.finish() {
                    entry.voice.pendingPrompt = text
                    entry.open()
                }
            }
        case .undecided: tapped()
        case .reposition: break
        }
    }

    /// Tap opens the sheet, double tap starts Live; while Live, a tap ends it.
    private func tapped() {
        if entry.live.active {
            tapTask?.cancel(); tapTask = nil
            entry.live.end()
            return
        }
        if let pending = tapTask {
            pending.cancel()
            tapTask = nil
            Task { await entry.live.start() }
            return
        }
        tapTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(PressRules.doubleTapWindow * 1000)))
            guard !Task.isCancelled else { return }
            tapTask = nil
            entry.open()
        }
    }
}
