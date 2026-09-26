import SwiftUI

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
    static var warning: Color { AppearanceSettings.shared.color("warning", fallback: 0xfbbf24, light: 0xa36800) }
    static var danger: Color { AppearanceSettings.shared.color("diff_remove", fallback: 0xff6464, light: 0xb52828) }
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
            Text("Verde").font(VerdeTheme.display()).tracking(-0.72)
        }.accessibilityElement(children: .ignore).accessibilityLabel("Verde")
    }
}
struct ProviderGlyph: View {
    let provider: String?
    var body: some View {
        let name = provider == "codex" ? "openai" : provider ?? ""
        if ["openai", "claude", "cursor", "opencode", "pi", "fx", "grok", "muse", "amp"].contains(name) {
            Image(uiImage: UIImage(named: "provider_" + name) ?? UIImage()).resizable()
                .renderingMode(["openai", "cursor", "fx", "grok", "pi"].contains(name) ? .template : .original)
                .scaledToFit().frame(width: 18, height: 18).foregroundStyle(VerdeTheme.text).accessibilityHidden(true)
        } else { Image(systemName: "bubble.left").frame(width: 18, height: 18).foregroundStyle(VerdeTheme.subtle).accessibilityHidden(true) }
    }
}

struct Pulse: ViewModifier {
    let active: Bool
    var minimum = 0.35
    var period = 1.6
    @Environment(\.accessibilityReduceMotion) private var reduced
    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active || reduced || AppearanceSettings.shared.reducedMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            content.opacity(active && !reduced && !AppearanceSettings.shared.reducedMotion ? minimum + (1 - minimum) * (1 - cos(phase * 2 * .pi)) / 2 : 1)
        }
    }
}
struct StatusPip: View {
    var active = false
    var attention = false
    var body: some View {
        Circle().fill(attention ? VerdeTheme.warning : active ? VerdeTheme.accent : VerdeTheme.subtle)
            .frame(width: 6, height: 6).modifier(Pulse(active: active)).accessibilityLabel(attention ? "Needs attention" : active ? "Working" : "Idle")
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
    var body: some View { Button(action: open) { Image(systemName: "line.3.horizontal").frame(width: 32, height: 32) }.accessibilityLabel("Open workspace drawer") }
}
struct VerdeNavigation: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar { ToolbarItem(placement: .topBarLeading) { DrawerButton() } }
            .navigationBarTitleDisplayMode(.inline)
    }
}
