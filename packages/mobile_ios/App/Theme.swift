import SwiftUI
import UIKit

/// The web palette and the Android baseline, shared by every native screen.
enum VerdeTheme {
    static var background: Color { AppearanceSettings.shared.color("background", fallback: 0x0d1213, light: 0xf5f7f6) }
    static var panel: Color { AppearanceSettings.shared.color("panel", fallback: 0x20272a, light: 0xffffff) }
    static var alternate: Color { AppearanceSettings.shared.color("panel_alt", fallback: 0x28292e, light: 0xe9eeeb) }
    static var mutedPanel: Color { AppearanceSettings.shared.color("panel_muted", fallback: 0x38393e, light: 0xdde5e0) }
    static var border: Color { AppearanceSettings.shared.color("border", fallback: 0x3c474c, light: 0xc2ccc6) }
    static var text: Color { AppearanceSettings.shared.color("text", fallback: 0xf0f0f5, light: 0x15221b) }
    static var muted: Color { AppearanceSettings.shared.color("text_muted", fallback: 0xb9bbc3, light: 0x46594e) }
    static var subtle: Color { AppearanceSettings.shared.color("text_subtle", fallback: 0x787887, light: 0x607267) }
    static var accent: Color { AppearanceSettings.shared.color("accent", fallback: 0x50c878, light: 0x197d43) }
    static var heading1: Color { AppearanceSettings.shared.color("heading1", fallback: 0xf5c84a, light: 0x805b00) }
    static var heading2: Color { AppearanceSettings.shared.color("heading2", fallback: 0xf6d27a, light: 0x86620d) }
    static var heading3: Color { AppearanceSettings.shared.color("heading3", fallback: 0x99dcb3, light: 0x197d43) }
    static var warning: Color { AppearanceSettings.shared.color("warning", fallback: 0xfbbf24, light: 0xa36800) }
    /// Added lines in diffs (patch view and transcript edits); removed lines use `danger`.
    static var diffAdd: Color { AppearanceSettings.shared.color("diff_add", fallback: 0x54b76b, light: 0x1d7f3a) }
    static var danger: Color { AppearanceSettings.shared.color("diff_remove", fallback: 0xff6464, light: 0xb52828) }
    /// Android's attention badge uses errorContainer/onErrorContainer, rather
    /// than bright error text. Host themes tint their own panel and text.
    static var attentionBackground: Color {
        if AppearanceSettings.shared.activePalette != nil {
            return danger.opacity(0.18)
        }
        return AppearanceSettings.shared.color("attention_background", fallback: 0x422829, light: 0xf6dddd)
    }
    static func status(_ status: String, attention: Bool = false) -> Color {
        if status == "failed" { return danger }
        if attention || status == "waiting_approval" { return warning }
        if ["working", "running", "accepted", "waiting"].contains(status) { return accent }
        return subtle
    }
    static var user: Color { AppearanceSettings.shared.color("selection", fallback: 0x2a4636, light: 0xd8eddf) }
    static var assistant: Color { AppearanceSettings.shared.color("background", fallback: 0x161c1e, light: 0xffffff) }
    static func ui(_ size: CGFloat = 15, bold: Bool = false) -> Font { .custom(bold ? "NotoSans-Bold" : "NotoSans-Regular", size: size, relativeTo: .body) }
    static func display(_ size: CGFloat = 24) -> Font { .custom("CalSans-Regular", size: size, relativeTo: .title2) }
    static func mono(_ size: CGFloat = 13) -> Font { .custom("JetBrainsMonoNF-Regular", size: size, relativeTo: .body) }

    @MainActor static func configure() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(panel)
        appearance.shadowColor = UIColor(border)
        appearance.titleTextAttributes = [.foregroundColor: UIColor(text), .font: UIFont(name: "NotoSans-Bold", size: 15) ?? UIFont.boldSystemFont(ofSize: 15)]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UITableView.appearance().backgroundColor = UIColor(background)
        UICollectionView.appearance().backgroundColor = UIColor(background)
    }
}

extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1) }
}

struct VerdeWordmark: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(uiImage: UIImage(named: "verde_logo") ?? UIImage()).resizable().renderingMode(.template).scaledToFit().frame(width: 26, height: 26).foregroundStyle(VerdeTheme.accent)
            Text("verde").font(VerdeTheme.display()).tracking(-0.72)
        }.accessibilityElement(children: .ignore).accessibilityLabel("verde")
    }
}
struct ProviderGlyph: View {
    let provider: String?
    /// A fixed size; nil grows with Dynamic Type from 18 up to 26 points (U1 iPad).
    var size: CGFloat? = nil
    @ScaledMetric(relativeTo: .footnote) private var scaled: CGFloat = 18
    var body: some View {
        let size = self.size ?? providerGlyphSize(scaled)
        let name = provider == "codex" ? "openai" : provider ?? ""
        if ["openai", "claude", "cursor", "opencode", "pi", "fx", "grok", "muse", "amp", "antigravity"].contains(name) {
            Image(uiImage: UIImage(named: "provider_" + name) ?? UIImage()).resizable()
                .renderingMode(["openai", "cursor", "fx", "grok", "pi"].contains(name) ? .template : .original)
                .scaledToFit().frame(width: size, height: size).foregroundStyle(VerdeTheme.text).accessibilityHidden(true)
        } else { Image(systemName: "bubble.left").frame(width: size, height: size).foregroundStyle(VerdeTheme.subtle).accessibilityHidden(true) }
    }
}

struct Pulse: ViewModifier {
    let active: Bool
    var minimum = 0.35
    var period = 1.6
    @Environment(\.accessibilityReduceMotion) private var reduced
    func body(content: Content) -> some View {
        // 12 frames a second is smooth for a 1.6 s fade and keeps idle screens cheap (I10-6).
        TimelineView(.animation(minimumInterval: 1 / 12, paused: !active || reduced || AppearanceSettings.shared.reducedMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            content.opacity(active && !reduced && !AppearanceSettings.shared.reducedMotion ? minimum + (1 - minimum) * (1 - cos(phase * 2 * .pi)) / 2 : 1)
        }
    }
}
/// The scaled provider glyph, capped so chips and rows keep their layout.
func providerGlyphSize(_ scaled: CGFloat) -> CGFloat { min(26, max(18, scaled)) }

/// A sheet's toolbar text button with a 44-point target (I10-8); the bar's own buttons draw a
/// 29-point one.
struct BarButton: View {
    let title: String
    var bold = false
    let action: () -> Void
    init(_ title: String, bold: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.bold = bold; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(title).fontWeight(bold ? .semibold : .regular).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
    }
}
struct StatusPip: View {
    var active = false
    var attention = false
    var failed = false
    var body: some View {
        Circle().fill(failed ? VerdeTheme.danger : attention ? VerdeTheme.warning : active ? VerdeTheme.accent : VerdeTheme.subtle)
            .frame(width: 6, height: 6).modifier(Pulse(active: active && !attention && !failed)).accessibilityLabel(failed ? "Failed" : attention ? "Needs attention" : active ? "Working" : "Idle")
    }
}
private struct DrawerActionKey: EnvironmentKey { static let defaultValue: () -> Void = {} }
extension EnvironmentValues {
    var openWorkspaceDrawer: () -> Void {
        get { self[DrawerActionKey.self] }
        set { self[DrawerActionKey.self] = newValue }
    }
}
struct DrawerButton: View {
    @Environment(\.openWorkspaceDrawer) private var open
    @Environment(\.adaptive) private var adaptive
    var body: some View {
        // With a permanent sidebar this only ever brings back a hidden one.
        Button(action: open) { Image(systemName: adaptive.tier.docked ? "sidebar.left" : "line.3.horizontal").frame(width: 44, height: 44).contentShape(Rectangle()) }
            .accessibilityLabel(adaptive.tier.docked ? "Show sidebar" : "Open workspace drawer")
            // I11-8: distinct from the sidebar's own Hide button (both draw `sidebar.left`).
            .accessibilityIdentifier(adaptive.tier.docked ? "sidebar-show" : "drawer-open")
            .keyboardShortcut(adaptive.tier.docked ? KeyboardShortcut("\\", modifiers: .command) : nil)
    }
}
/// iOS 26 wraps toolbar items in Liquid Glass, so toolbar controls draw their own
/// panel and border only on earlier systems; otherwise they nest a box in the glass.
struct ToolbarChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            // I12-7: the outline stays inside the bar; the 44-point target stays as it is.
            content.background {
                RoundedRectangle(cornerRadius: 9).fill(VerdeTheme.panel)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(VerdeTheme.border))
                    .padding(.vertical, 6)
            }
        }
    }
}
struct VerdeNavigation: ViewModifier {
    @Environment(\.adaptive) private var adaptive
    func body(content: Content) -> some View {
        content.toolbar { if !adaptive.slotVisible { ToolbarItem(placement: .topBarLeading) { DrawerButton() } } }
            .navigationBarTitleDisplayMode(.inline)
    }
}

extension VerdeTheme {
    /// Text and icons on an accent fill (the theme's background reads on its own accent).
    static var onAccent: Color { background }
    /// Disabled fills and their content: the same muted pair in light and dark.
    static var disabledFill: Color { mutedPanel }
    static var disabledContent: Color { subtle }
}

/// A screen's primary action: a full-width accent fill with on-accent text (S6).
struct PrimaryButtonStyle: ButtonStyle {
    /// False for an inline action (Commit, Retry, Ask agent) that sizes to its label.
    var fullWidth = true
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VerdeTheme.ui(16, bold: true))
            .foregroundStyle(enabled ? VerdeTheme.onAccent : VerdeTheme.disabledContent)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: fullWidth ? 50 : 44)
            .background(enabled ? VerdeTheme.accent : VerdeTheme.disabledFill, in: RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// A secondary action beside or under a primary one: a tonal fill (S6). `destructive` uses the
/// error colour for its text.
struct TonalButtonStyle: ButtonStyle {
    var destructive = false
    var fullWidth = true
    /// Matches a primary button's 50-point height beside it (Deny next to Approve).
    var tall = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VerdeTheme.ui(15, bold: true))
            .foregroundStyle(enabled ? (destructive ? VerdeTheme.danger : VerdeTheme.text) : VerdeTheme.disabledContent)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: tall ? 50 : 44)
            .background(VerdeTheme.alternate, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(VerdeTheme.border))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// A form's primary action as its own list row, without the row's background.
struct PrimaryRow: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(PrimaryButtonStyle())
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }
}

/// At least a 44-point hit target around a small control (S4).
struct MinTarget: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }
}

extension View {
    func minTarget() -> some View { modifier(MinTarget()) }
}

/// Keeps the list's last rows clear of the floating companion bubble.
struct BubbleReserve: ViewModifier {
    @Environment(\.companionBubbleShown) private var shown
    var enabled = true
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            // Opaque, so rows never scroll beneath the bubble resting there (I3-7).
            if shown && enabled {
                // Down through the home-indicator area too, so no row shows below the band (I6-9).
                VerdeTheme.background.frame(height: bubbleListReserve)
                    .background(VerdeTheme.background.ignoresSafeArea(edges: .bottom))
                    .accessibilityHidden(true)
            }
        }
    }
}


/// Makes the back button on the screens pushed from this one a plain chevron (Pass 16): the
/// system otherwise labels it with this screen's title ("‹ Home") on wide windows, while the
/// drawer footer marks the current screen's own section.
struct MinimalBackTitle: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); apply() }
        override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); apply() }
        private func apply() {
            var current: UIViewController? = parent
            while let controller = current {
                if let navigation = controller.navigationController, navigation.viewControllers.contains(controller) {
                    controller.navigationItem.backButtonDisplayMode = .minimal
                    return
                }
                current = controller.parent
            }
        }
    }
}

extension View {
    /// Screens pushed from this one show a plain chevron back button.
    func minimalBackTitle() -> some View { background(MinimalBackTitle().frame(width: 0, height: 0).accessibilityHidden(true)) }
}
