import SwiftUI

/*
 * Layout by the width the root view actually has, never by device model, so a foldable, an iPad
 * window and a rotated phone all follow the same rules. The math is pure and unit tested; RootView
 * places the panes with it. The panes sit in one ZStack and move by padding and offset, so the
 * navigation stack and an open chat keep their identity (draft, scroll position) across thresholds.
 */

enum AdaptiveTier: Equatable {
    /// Today's layout: overlay drawer, Companion sheet, floating bubble, full composer.
    case phone
    /// One pane, with capped transcript text and the one-row composer controls.
    case single
    /// Permanent sidebar plus content; an open Moss takes the sidebar slot.
    case split
    /// Sidebar, content and, only while it is open, Moss in its own pane.
    case triple

    static let singleMinWidth: CGFloat = 600
    static let splitMinWidth: CGFloat = 700
    static let tripleMinWidth: CGFloat = 1000

    init(width: CGFloat) {
        if width >= Self.tripleMinWidth { self = .triple }
        else if width >= Self.splitMinWidth { self = .split }
        else if width >= Self.singleMinWidth { self = .single }
        else { self = .phone }
    }

    /// Capped transcript text and the one-row composer controls.
    var wide: Bool { self != .phone }
    /// The sidebar is permanent, and Moss and New chat dock into it instead of floating.
    var docked: Bool { self == .split || self == .triple }
}

/// Where each pane goes for a width and the user's choices. Moss gets space only while `mossOpen`.
struct AdaptivePanes: Equatable {
    static let sidebarWidth: CGFloat = 300
    static let mossPaneWidth: CGFloat = 320

    let tier: AdaptiveTier
    /// The chat list is on screen.
    let showsChats: Bool
    /// Moss stays mounted while the chat list covers its slot, so it keeps its place.
    let mossMounted: Bool
    let mossVisible: Bool
    /// Moss uses the sidebar slot rather than its own pane.
    let mossInSlot: Bool
    let mossWidth: CGFloat
    let mossLeading: CGFloat
    let contentLeading: CGFloat
    let contentTrailing: CGFloat

    /// - Parameters:
    ///   - sidebarCollapsed: the user hid the sidebar for a full-width diff or terminal.
    ///   - mossOpen: the user opened Moss; nothing else may set this.
    ///   - chatsPeek: the chat list is showing over Moss in the sidebar slot.
    init(width: CGFloat, sidebarCollapsed: Bool, mossOpen: Bool, chatsPeek: Bool) {
        let tier = AdaptiveTier(width: width)
        let moss = tier.docked && mossOpen
        let slot = tier == .split && moss
        let third = tier == .triple && moss
        self.tier = tier
        showsChats = tier.docked && (slot ? chatsPeek : !sidebarCollapsed)
        mossMounted = moss
        mossVisible = moss && !(slot && chatsPeek)
        mossInSlot = slot
        mossWidth = slot ? Self.sidebarWidth : Self.mossPaneWidth
        mossLeading = third ? max(0, width - Self.mossPaneWidth) : 0
        contentLeading = slot || showsChats ? Self.sidebarWidth : 0
        contentTrailing = third ? Self.mossPaneWidth : 0
    }
}

/// A route opened from the sidebar replaces the content beside it, since the sidebar is the way
/// back; the overlay drawer keeps pushing so the back button returns to where the user was.
func adaptivePath(_ path: [BrowseRoute], opening route: BrowseRoute, docked: Bool) -> [BrowseRoute] {
    docked ? [route] : path + [route]
}

/// About 720: long lines are hard to read. Nil leaves a row the full width.
let transcriptTextWidth: CGFloat = 720

/// Prose rows are capped on wide windows; diffs and tool output (code, terminals) may go wider.
func transcriptRowCap(_ item: TranscriptItem, tier: AdaptiveTier) -> CGFloat? {
    guard tier.wide else { return nil }
    switch item {
    case .diff, .tool, .toolGroup: return nil
    default: return transcriptTextWidth
    }
}

/// What screens below the root need to know about the current layout.
struct AdaptiveContext: Equatable {
    var tier: AdaptiveTier = .phone
    /// The sidebar slot is on screen, holding the chat list or Moss.
    var slotVisible = false
}

private struct AdaptiveContextKey: EnvironmentKey { static let defaultValue = AdaptiveContext() }

extension EnvironmentValues {
    var adaptive: AdaptiveContext {
        get { self[AdaptiveContextKey.self] }
        set { self[AdaptiveContextKey.self] = newValue }
    }
}

extension View {
    /// Out of sight, touch, keyboard focus and VoiceOver, but still mounted so its state survives.
    func adaptivePaneHidden(_ hidden: Bool) -> some View {
        opacity(hidden ? 0 : 1).allowsHitTesting(!hidden).disabled(hidden).accessibilityHidden(hidden)
    }
}

/// Moss beside the chat: its usual screen under a strip with the way out. In the sidebar slot the
/// strip also keeps the chat list one tap away.
struct CompanionPane<Content: View>: View {
    let name: String
    let inSlot: Bool
    let showChats: () -> Void
    let close: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if inSlot {
                    Button(action: showChats) {
                        HStack(spacing: 6) {
                            Image(systemName: "sidebar.left")
                            Text("Chats").font(VerdeTheme.ui(14, bold: true))
                        }
                        .padding(.horizontal, 8).frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows your chat list. \(name) stays open.")
                    .accessibilityIdentifier("companion-pane-chats")
                }
                Spacer(minLength: 0)
                Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("Close \(name)")
                    .accessibilityIdentifier("companion-pane-close")
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 4)
            Divider().overlay(VerdeTheme.border)
            content()
        }
        .background(VerdeTheme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("companion-pane")
    }
}

/// The floating bubble's job while the sidebar is permanent: Moss's status and badge, talk and Live,
/// docked in the sidebar so nothing floats over transcript text. These are ordinary buttons, so a
/// hardware keyboard reaches them; talk is tap to start and tap to send.
struct CompanionDock: View {
    let model: CompanionModel
    let voice: CompanionVoice
    let live: LiveVoice
    /// Moss is open; the row reads as selected.
    let open: Bool
    /// The row itself: opens Moss, or closes it where it has its own pane.
    let toggle: () -> Void
    /// Shows Moss for a finished voice message, which its conversation then sends.
    let reveal: () -> Void
    let settings: () -> Void

    var body: some View {
        if let active = model.active {
            let badge = model.badgeCount
            HStack(spacing: 2) {
                Button(action: toggle) {
                    HStack(spacing: 8) {
                        CompanionAvatar(character: active.character, pose: model.presence.pose, failure: model.presence.failure, width: 28)
                            .overlay(alignment: .topTrailing) { if badge > 0 { badgeView(badge) } }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(active.name).font(VerdeTheme.ui(13, bold: true)).lineLimit(1)
                            status
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).frame(minHeight: 44).contentShape(Rectangle())
                    .background(open ? VerdeTheme.accent.opacity(0.19) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .contextMenu { Button("Settings", action: settings) }
                .accessibilityLabel(bubbleAccessibilityLabel(name: active.name, count: badge))
                .accessibilityValue(model.presence.status)
                .accessibilityAddTraits(open ? .isSelected : [])
                .accessibilityAction(named: "Settings", settings)
                .accessibilityIdentifier("companion-dock")
                talkButton(active.name)
                if voice.listening {
                    Button { voice.cancel() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel("Cancel voice message")
                } else {
                    Button { live.toggle() } label: {
                        Image(systemName: live.active ? "waveform.circle.fill" : "waveform")
                            .font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(live.active ? "End live conversation" : "Talk live")
                    .accessibilityIdentifier("companion-dock-live")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
    }

    @ViewBuilder private var status: some View {
        if voice.listening {
            HStack(spacing: 6) {
                LevelMeter(level: voice.level)
                Text(voice.partial.isEmpty ? "Listening…" : voice.partial).font(VerdeTheme.ui(11)).lineLimit(1).truncationMode(.head)
            }
        } else if let notice = voice.notice {
            Text(notice).font(VerdeTheme.ui(11)).foregroundStyle(VerdeTheme.warning).lineLimit(1)
        } else {
            Text(live.active ? "Live" : model.presence.status).font(VerdeTheme.ui(11)).foregroundStyle(VerdeTheme.muted).lineLimit(1)
        }
    }

    private func badgeView(_ count: Int) -> some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(VerdeTheme.ui(10, bold: true)).foregroundStyle(Color.white)
            .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
            .background(VerdeTheme.danger, in: Capsule())
            .offset(x: 6, y: -6)
            .accessibilityHidden(true)
    }

    @ViewBuilder private func talkButton(_ name: String) -> some View {
        if voice.speaking && !voice.listening {
            Button { voice.stopSpeaking() } label: {
                Image(systemName: "speaker.slash.fill").font(.system(size: 15, weight: .semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Stop reading aloud")
        } else if !live.active {
            // Push-to-talk stays off while a live conversation runs, as on the bubble.
            Button {
                if voice.listening {
                    Task { if let text = await voice.finish() { voice.pendingPrompt = text; reveal() } }
                } else {
                    Task { await voice.start() }
                }
            } label: {
                Image(systemName: voice.listening ? "arrow.up.circle.fill" : "mic.fill")
                    .font(.system(size: 15, weight: .semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel(voice.listening ? "Send voice message" : "Talk to \(name)")
            .accessibilityIdentifier("companion-dock-talk")
        }
    }
}
