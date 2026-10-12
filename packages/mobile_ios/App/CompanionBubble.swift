import SwiftUI
import UIKit

/*
 * The Companion as a floating chat-head over every main screen: drag to either edge, a badge for
 * what needs the user, a short speech-bubble chip when something new arrives, tap to open the
 * Companion sheet. Placement math and the pop-up trigger are pure and unit tested.
 */

enum CompanionBubbleStore {
    static let hiddenKey = "companion.bubble.hidden"
    static let edgeKey = "companion.bubble.edge"
    static let fractionKey = "companion.bubble.fraction"
}

enum BubbleEdge: String { case leading, trailing }

/// Where the bubble may sit inside the overlay's (safe-area, keyboard-aware) bounds.
struct BubbleLayout: Equatable {
    static let diameter: CGFloat = 56
    static let margin: CGFloat = 12
    /// Clears the navigation bar's controls.
    static let topReserve: CGFloat = 52
    /// Clears the chat composer and Home's floating "New chat" button.
    static let bottomReserve: CGFloat = 96

    var size: CGSize
    var diameter: CGFloat = BubbleLayout.diameter
    var margin: CGFloat = BubbleLayout.margin
    var top: CGFloat = BubbleLayout.topReserve
    var bottom: CGFloat = BubbleLayout.bottomReserve

    var minY: CGFloat { top + margin + diameter / 2 }
    /// Never above `minY`, even when the keyboard leaves little room.
    var maxY: CGFloat { max(minY, size.height - bottom - margin - diameter / 2) }

    func x(_ edge: BubbleEdge) -> CGFloat {
        edge == .leading ? margin + diameter / 2 : max(margin + diameter / 2, size.width - margin - diameter / 2)
    }

    /// The resting center for a saved edge and vertical fraction (0 = top, 1 = bottom).
    func center(edge: BubbleEdge, fraction: Double) -> CGPoint {
        let f = CGFloat(min(max(fraction.isFinite ? fraction : 1, 0), 1))
        return CGPoint(x: x(edge), y: minY + (maxY - minY) * f)
    }

    /// Snaps a dropped center to the nearest side edge, clamped vertically.
    func snap(_ point: CGPoint) -> (edge: BubbleEdge, fraction: Double) {
        let edge: BubbleEdge = point.x < size.width / 2 ? .leading : .trailing
        let span = maxY - minY
        let y = min(max(point.y, minY), maxY)
        return (edge, span > 0 ? Double((y - minY) / span) : 0)
    }
}

/// Badge: approvals and blocked chats across workspaces (crew included) plus the companion's own
/// pending approval.
func companionBadgeCount(needsYou: Int, ownApproval: Bool) -> Int { needsYou + (ownApproval ? 1 : 0) }

func needsYouPhrase(_ count: Int) -> String { count == 1 ? "1 thing needs you" : "\(count) things need you" }

func bubbleAccessibilityLabel(name: String, count: Int) -> String { "\(name), \(needsYouPhrase(count))" }

/// Decides when the collapsed bubble shows its speech-bubble chip: only for needs-you items it
/// hasn't seen before, or a companion reply newer than the last one seen. The first observation
/// only primes it, and anything observed while the sheet is open counts as seen.
struct BubblePopupTracker {
    private(set) var seen: Set<String> = []
    private(set) var reply: String?
    private(set) var primed = false

    mutating func update(needs: [String], reply next: String?, name: String, badge: Int, collapsed: Bool) -> String? {
        let current = Set(needs)
        let fresh = !current.subtracting(seen).isEmpty
        let replied = next != nil && next != reply
        let wasPrimed = primed
        seen = current
        reply = next
        primed = true
        guard wasPrimed, collapsed else { return nil }
        if fresh { return "\(name): \(needsYouPhrase(max(badge, 1)))" }
        if replied { return "\(name) replied" }
        return nil
    }
}

/// The overlay layer: place it above the main navigation in the root view.
struct CompanionBubbleLayer: View {
    let model: CompanionModel
    /// Hold-to-talk: the transcript is handed to the sheet (`pendingPrompt`), which sends it.
    let voice: CompanionVoice
    /// Live conversation: double-tap starts it, a tap ends it.
    let live: LiveVoice
    /// The sheet is open: hide the bubble and poll faster.
    let sheetOpen: Bool
    /// Hidden on the companion's own chat screen, the drawer, etc. (polling continues).
    let visible: Bool
    let open: () -> Void
    let settings: () -> Void

    @AppStorage(CompanionBubbleStore.hiddenKey) private var hidden = false
    @AppStorage(CompanionBubbleStore.edgeKey) private var edgeRaw = BubbleEdge.trailing.rawValue
    @AppStorage(CompanionBubbleStore.fractionKey) private var fraction = 0.72
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CGPoint?
    @State private var tracker = BubblePopupTracker()
    @State private var chip: String?
    @State private var chipTask: Task<Void, Never>?
    /// The current press on the bubble: tap, hold-to-talk or reposition.
    @State private var press: PressIntent?
    @State private var pressStart = Date()
    @State private var holdTask: Task<Void, Never>?
    @State private var cancelArmed = false
    /// A first tap waiting to see whether a second one makes it a double-tap.
    @State private var tapTask: Task<Void, Never>?

    private var edge: BubbleEdge { BubbleEdge(rawValue: edgeRaw) ?? .trailing }
    private var pollKey: String { [model.browse.hostID ?? "", String(scenePhase == .active), String(sheetOpen), String(hidden)].joined(separator: "/") }
    private var animation: Animation? { reduceMotion || AppearanceSettings.shared.reducedMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82) }

    var body: some View {
        GeometryReader { geometry in
            let layout = BubbleLayout(size: geometry.size)
            if !hidden, visible, !sheetOpen, let active = model.active {
                let rest = layout.center(edge: edge, fraction: fraction)
                let point = drag ?? rest
                bubble(active, layout: layout)
                    .position(point)
                    // One gesture: a still hold talks, early movement repositions, a quick release taps.
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: NamedCoordinateSpace.named("companion-bubble"))
                        .onChanged { value in pressChanged(value, layout) }
                        .onEnded { value in pressEnded(value, layout) })
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .coordinateSpace(.named("companion-bubble"))
        // Polls ~4s with the sheet open, ~8s otherwise, only while the app is active.
        .task(id: pollKey) {
            guard scenePhase == .active, !hidden || sheetOpen else { return }
            await model.poll(every: sheetOpen ? .seconds(4) : .seconds(8))
        }
        .onChange(of: popupSignature, initial: true) { _, _ in notePopup() }
        .onDisappear { chipTask?.cancel() }
    }

    /// Keeps the dragged bubble on screen.
    private func clamped(_ point: CGPoint, _ layout: BubbleLayout) -> CGPoint {
        CGPoint(x: min(max(point.x, layout.diameter / 2), max(layout.diameter / 2, layout.size.width - layout.diameter / 2)),
                y: min(max(point.y, layout.minY), layout.maxY))
    }

    private func distance(_ value: DragGesture.Value) -> CGFloat {
        (value.translation.width * value.translation.width + value.translation.height * value.translation.height).squareRoot()
    }

    private func pressChanged(_ value: DragGesture.Value, _ layout: BubbleLayout) {
        if press == nil {
            press = .undecided
            pressStart = Date()
            cancelArmed = false
            holdTask?.cancel()
            // Push-to-talk is off while a live conversation runs.
            if !live.active { holdTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Int(PressRules.holdDelay * 1000)))
                guard !Task.isCancelled, press == .undecided else { return }
                startTalking()
            } }
        }
        let current = press ?? .undecided
        let next = classifyPress(current, elapsed: Date().timeIntervalSince(pressStart), distance: distance(value))
        if current == .undecided && next == .talk && !live.active { startTalking() }
        if current == .undecided && next == .reposition { press = .reposition; holdTask?.cancel(); chip = nil }
        switch press {
        case .reposition?: drag = clamped(value.location, layout)
        case .talk?: cancelArmed = talkCancelled(distance: distance(value))
        default: break
        }
    }

    private func startTalking() {
        holdTask?.cancel()
        press = .talk
        chip = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { @MainActor in
            if !(await voice.start()) { UINotificationFeedbackGenerator().notificationOccurred(.error) }
        }
    }

    private func pressEnded(_ value: DragGesture.Value, _ layout: BubbleLayout) {
        holdTask?.cancel()
        let intent = press ?? .undecided
        let cancelled = cancelArmed || talkCancelled(distance: distance(value))
        press = nil
        cancelArmed = false
        switch intent {
        case .reposition:
            let snapped = layout.snap(value.location)
            edgeRaw = snapped.edge.rawValue
            fraction = snapped.fraction
            withAnimation(animation) { drag = nil }
        case .talk:
            if cancelled {
                voice.cancel()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                return
            }
            Task { @MainActor in
                if let text = await voice.finish() {
                    voice.pendingPrompt = text
                    open()
                } else if let notice = voice.notice {
                    showChip(notice)
                }
            }
        case .undecided:
            guard distance(value) <= PressRules.slop else { return }
            tapped()
        }
    }

    /// Tap opens the sheet, double-tap starts Live; while Live, a tap ends it.
    private func tapped() {
        if live.active {
            tapTask?.cancel(); tapTask = nil
            live.end()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }
        if let pending = tapTask {
            pending.cancel()
            tapTask = nil
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Task { await live.start() }
            return
        }
        tapTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(PressRules.doubleTapWindow * 1000)))
            guard !Task.isCancelled else { return }
            tapTask = nil
            open()
        }
    }

    private var popupSignature: String {
        model.needsYou.map(\.id).joined(separator: "|") + "#" + (model.replyKey ?? "")
    }

    private func notePopup() {
        guard let active = model.active else { return }
        let text = tracker.update(needs: model.needsYou.map(\.id), reply: model.replyKey, name: active.name,
                                  badge: model.badgeCount, collapsed: !sheetOpen && visible && !hidden)
        guard let text, press == nil else { return }
        showChip(text)
    }

    private func showChip(_ text: String) {
        chipTask?.cancel()
        withAnimation(animation) { chip = text }
        // The bubble is one accessibility element; speak the chip instead of showing it silently.
        UIAccessibility.post(notification: .announcement, argument: text)
        chipTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(animation) { chip = nil }
        }
    }

    private func bubble(_ active: RosterEntry, layout: BubbleLayout) -> some View {
        let presence = model.presence
        let badge = model.badgeCount
        let running = model.crew.contains { $0.attention == .running } || presence.pose == .working
        let d = layout.diameter
        let liveOn = live.active
        let liveLevel = max(live.inputLevel, live.outputLevel)
        let still = reduceMotion || AppearanceSettings.shared.reducedMotion
        return ZStack {
            if liveOn {
                // Level ring while Live.
                Circle().stroke(VerdeTheme.accent.opacity(0.35 + 0.5 * liveLevel), lineWidth: 4)
                    .scaleEffect(still ? 1.12 : 1.08 + 0.25 * liveLevel)
                    .animation(still ? nil : .easeOut(duration: 0.12), value: liveLevel)
            }
            Circle().fill(VerdeTheme.panel)
                .shadow(color: .black.opacity(0.28), radius: 6, y: 3)
            Circle().stroke(running ? VerdeTheme.accent : VerdeTheme.border, lineWidth: running ? 2 : 1)
                .modifier(Pulse(active: running, minimum: 0.4))
            CompanionAvatar(character: active.character, pose: presence.pose, failure: presence.failure, width: d * 0.6)
        }
        .frame(width: d, height: d)
        .overlay(alignment: .topTrailing) {
            if badge > 0 {
                Text(badge > 99 ? "99+" : "\(badge)")
                    .font(VerdeTheme.ui(11, bold: true)).foregroundStyle(Color.white)
                    .padding(.horizontal, 5).frame(minWidth: 20, minHeight: 20)
                    .background(VerdeTheme.danger, in: Capsule())
                    .overlay(Capsule().stroke(VerdeTheme.background, lineWidth: 1.5))
                    .offset(x: 4, y: -4)
            }
        }
        .overlay(alignment: .bottom) {
            if liveOn {
                Text(live.phase == .connecting ? "…" : "Live")
                    .font(VerdeTheme.ui(10, bold: true)).foregroundStyle(VerdeTheme.background)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(VerdeTheme.accent, in: Capsule())
                    .offset(y: 8)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: edge == .leading ? .leading : .trailing) {
            if press == .talk {
                // Live transcript while holding.
                HStack(spacing: 8) {
                    LevelMeter(level: voice.level, color: cancelArmed ? VerdeTheme.danger : VerdeTheme.accent)
                    Text(cancelArmed ? "Release to cancel" : voice.notice ?? (voice.partial.isEmpty ? "Listening…" : voice.partial))
                        .font(VerdeTheme.ui(13)).lineLimit(3).multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(VerdeTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(cancelArmed ? VerdeTheme.danger : VerdeTheme.accent))
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                .frame(width: 240, alignment: edge == .leading ? .leading : .trailing)
                .offset(x: edge == .leading ? d + 8 : -(d + 8))
                .allowsHitTesting(false)
            } else if let chip {
                Button(action: open) {
                    Text(chip).font(VerdeTheme.ui(13)).lineLimit(2).multilineTextAlignment(.leading)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(VerdeTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(VerdeTheme.border))
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .frame(width: 220, alignment: edge == .leading ? .leading : .trailing)
                .offset(x: edge == .leading ? d + 8 : -(d + 8))
                .transition(.opacity)
                .accessibilityLabel(chip)
            }
        }
        .contentShape(Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bubbleAccessibilityLabel(name: active.name, count: badge))
        .accessibilityValue(liveOn ? "Live conversation" : voice.listening ? "Listening" : voice.speaking ? "Speaking" : presence.status)
        .accessibilityHint(liveOn ? "Ends the live conversation." : "Opens your companion. Touch and hold to talk, or use the Talk live action.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if liveOn { live.end() } else { open() } }
        .accessibilityAction(named: liveOn ? "End live conversation" : "Talk live") { live.toggle() }
        .accessibilityAction(named: "Settings") { settings() }
        .accessibilityAction(named: "Hide bubble") { hidden = true }
        .accessibilityIdentifier("companion-bubble")
    }
}
