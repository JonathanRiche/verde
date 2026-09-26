import SwiftUI

/// The web palette and the Android baseline, shared by every native screen.
enum VerdeTheme {
    static let background = Color(hex: 0x0d1213)
    static let panel = Color(hex: 0x20272a)
    static let alternate = Color(hex: 0x28292e)
    static let mutedPanel = Color(hex: 0x38393e)
    static let border = Color(hex: 0x3c474c)
    static let text = Color(hex: 0xf0f0f5)
    static let muted = Color(hex: 0xb9bbc3)
    static let subtle = Color(hex: 0x787887)
    static let accent = Color(hex: 0x50c878)
    static let warning = Color(hex: 0xfbbf24)
    static let danger = Color(hex: 0xff6464)
    static let user = Color(hex: 0x2a4636)
    static let assistant = Color(hex: 0x161c1e)
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
            Image(uiImage: UIImage(named: "provider_" + name) ?? UIImage()).resizable().scaledToFit().frame(width: 18, height: 18).accessibilityHidden(true)
        } else { Image(systemName: "bubble.left").frame(width: 18, height: 18).foregroundStyle(VerdeTheme.subtle).accessibilityHidden(true) }
    }
}

struct Pulse: ViewModifier {
    let active: Bool
    var minimum = 0.35
    var period = 1.6
    @Environment(\.accessibilityReduceMotion) private var reduced
    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active || reduced)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            content.opacity(active && !reduced ? minimum + (1 - minimum) * (1 - cos(phase * 2 * .pi)) / 2 : 1)
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
