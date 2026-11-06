import SwiftUI
import Observation

enum AppearanceMode: String, CaseIterable {
    case system, light, dark = "verde"
    case tokyoNight = "tokyo-night", catppuccin, catppuccinLatte = "catppuccin-latte"
    case gruvbox, kanagawa, matteBlack = "matte-black", osakaJade = "osaka-jade", ristretto
    case host
    var preset: BundledTheme? { BundledTheme.all.first { $0.id == rawValue } }
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        case .host: return "Host theme"
        default: return preset?.name ?? rawValue
        }
    }
}
struct BundledTheme: Decodable {
    let id: String
    let name: String
    let colors: [String: String]
    var palette: HostPalette { HostPalette(colors: colors) }
    // Presets ship offline with both apps from the same website-derived asset.
    static let all: [BundledTheme] = {
        guard let url = Bundle.main.url(forResource: "themes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let themes = try? JSONDecoder().decode([BundledTheme].self, from: data) else {
            assertionFailure("Bundled themes are missing or invalid")
            return []
        }
        return themes
    }()
}
struct HostPalette: Decodable {
    let colors: [String: String]
    var reduced_motion: Bool? = nil
    var dark: Bool {
        guard let value = colors["background"], let components = Self.components(value) else { return true }
        return components.0 * 0.2126 + components.1 * 0.7152 + components.2 * 0.0722 < 0.5
    }
    static func components(_ value: String) -> (Double, Double, Double, Double)? {
        guard value.first == "#", [7, 9].contains(value.count), let hex = UInt32(value.dropFirst(), radix: 16) else { return nil }
        let rgba = value.count == 7 ? (hex << 8) | 255 : hex
        return (Double(rgba >> 24) / 255, Double((rgba >> 16) & 255) / 255, Double((rgba >> 8) & 255) / 255, Double(rgba & 255) / 255)
    }
    func color(_ key: String) -> Color? {
        guard let raw = colors[key], let c = Self.components(raw) else { return nil }
        return Color(.sRGB, red: c.0, green: c.1, blue: c.2, opacity: c.3)
    }
}

@Observable final class AppearanceSettings {
    static let shared = AppearanceSettings()
    var mode: AppearanceMode { didSet { defaults.set(mode.rawValue, forKey: "ios.appearance") } }
    private(set) var palette: HostPalette?
    private(set) var notice: String?
    private let defaults: UserDefaults
    private var revision = UUID()
    private var paletteHost: String?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = AppearanceMode(rawValue: defaults.string(forKey: "ios.appearance") ?? "") ?? .system
    }
    var scheme: ColorScheme? {
        switch mode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        default: return activePalette?.dark == false ? .light : .dark
        }
    }
    /// `scheme` with System resolved to the phone's current appearance. A sheet that was given a
    /// forced scheme keeps it when handed nil, so sheets open while the theme changes use this (I6-5).
    var resolvedScheme: ColorScheme {
        if let scheme { return scheme }
        let style = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.traitCollection.userInterfaceStyle
        return style == .dark ? .dark : .light
    }
    var activePalette: HostPalette? { mode == .host ? palette : mode.preset?.palette }
    var reducedMotion: Bool { mode == .host && palette?.reduced_motion == true }
    @MainActor func refresh(_ browse: BrowseModel) async {
        let stamp = UUID(); revision = stamp; notice = nil
        if paletteHost != browse.hostID || mode != .host { palette = nil; paletteHost = nil }
        VerdeTheme.configure()
        guard mode == .host else { return }
        guard let session = browse.session else { notice = "Choose a paired host to load its theme."; return }
        let hostID = browse.hostID
        await session.start()
        guard let host = session.host else { notice = "Connect to the host to load its theme."; return }
        do {
            let bytes = try await host.fetchFile(path: "/", kind: .theme, limit: 64 * 1024)
            let value = try JSONDecoder().decode(HostPalette.self, from: bytes.data)
            guard value.color("background") != nil, value.color("text") != nil else { throw FileProblem.unreadable }
            guard !Task.isCancelled, stamp == revision, hostID == browse.hostID else { return }
            palette = value; paletteHost = hostID
            VerdeTheme.configure()
        } catch {
            guard !Task.isCancelled, stamp == revision else { return }
            notice = "Host theme unavailable. Showing verde dark until you reconnect or retry."
        }
    }
    func color(_ key: String, fallback: UInt32, light: UInt32? = nil) -> Color {
        if let palette = activePalette {
            if let value = palette.color(key) { return value }
            let role = ["heading1": "warning", "heading2": "warning", "heading3": "accent"][key]
            if let role, let value = palette.color(role) { return value }
        }
        if mode == .light, let light { return Color(hex: light) }
        if mode == .system, let light {
            return Color(uiColor: UIColor { traits in UIColor(Color(hex: traits.userInterfaceStyle == .dark ? fallback : light)) })
        }
        return Color(hex: fallback)
    }
}

/// The Theme row's helper: what the current choice does.
func themeHelpText(_ mode: AppearanceMode) -> String {
    switch mode {
    case .system: return "System follows your device's Light or Dark appearance automatically."
    case .light: return "Light keeps verde light, whatever your device's appearance."
    case .dark: return "Dark keeps verde dark, whatever your device's appearance."
    case .host: return "Host theme uses the theme set in verde on your computer."
    default: return "\(mode.label) is a fixed theme; it doesn't follow your device's Light or Dark appearance."
    }
}

/// "0.1.0 (1)" from the bundle.
func appVersionLabel(_ info: [String: Any]?) -> String {
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else { return version }
    return "\(version) (\(build))"
}

/// Licence texts shipped with the app (fonts and glyphs), by display name.
private let bundledLicences: [(String, String)] = [
    ("Noto Sans", "NotoSans-OFL-1.1"), ("Cal Sans", "CalSans-OFL"),
    ("JetBrains Mono Nerd Font", "JetBrainsMonoNerdFont-OFL"), ("Symbols Nerd Font", "SymbolsNerdFont-LICENSE"),
]

/// Settings (S8): Appearance, Notifications, Security, Companion, Hosts, then About, in the same
/// order as Android. Commit messages (read-only, set on the computer) sit after Companion.
/// The drawer button when Settings sits in the content pane and the sidebar is hidden.
private struct EmbeddedNavigation: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.modifier(VerdeNavigation()) } else { content }
    }
}

struct AppSettings: View {
    let lock: AppLock
    let browse: BrowseModel
    let push: PushRegistry
    /// In the content pane beside the sidebar (I11-6): no Done, the sidebar is the way out.
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @State private var appearance = AppearanceSettings.shared
    @AppStorage(CompanionBubbleStore.hiddenKey) private var companionBubbleHidden = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Theme", selection: $appearance.mode) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }.pickerStyle(.navigationLink)
                    if appearance.mode == .host {
                        Button("Reload host theme") { Task { await appearance.refresh(browse) } }
                        if let notice = appearance.notice { Text(notice).font(VerdeTheme.ui(13)) }
                    }
                } header: { SectionTitle("Appearance") } footer: {
                    Text(themeHelpText(appearance.mode) + " Animations follow Reduce Motion in iOS Accessibility settings.")
                        .font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted)
                }
                NotificationSettingsSection(registry: push)
                SecuritySettings(lock: lock)
                Section {
                    Toggle("Companion bubble", isOn: Binding(get: { !companionBubbleHidden }, set: { companionBubbleHidden = !$0 }))
                } header: { SectionTitle("Companion") } footer: {
                    Text("A shortcut to your companion on hosts that support it: on Home and Workspaces, and as an avatar in the top bar of other screens.")
                        .font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted)
                }
                CommitSettingsSection(browse: browse)
                hostsSection
                aboutSection
            }
            // S32 / I14-6: sentence-case headers in sheets too (the root setting stops at a sheet).
            .headerProminence(.increased)
            // Section headers keep the case they're written in (S7), including the shared sections.
            .textCase(nil)
            .scrollContentBackground(.hidden).background(VerdeTheme.background)
            .modifier(ReadableListWidth())
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { if !embedded { BarButton("Done", bold: true) { dismiss() } } }
            .modifier(EmbeddedNavigation(enabled: embedded))
            .modifier(RootCompanionToolbar())
        }.preferredColorScheme(appearance.resolvedScheme).tint(VerdeTheme.accent).foregroundStyle(VerdeTheme.text).font(VerdeTheme.ui())
    }

    /// Paired hosts with their status; tapping one makes it the active host.
    private var hostsSection: some View {
        let hosts = browse.hosts
        return Section {
            if hosts.rows.isEmpty { Text("No hosts yet. Add one from Hosts.").foregroundStyle(VerdeTheme.muted) }
            ForEach(hosts.rows, id: \.saved.id) { row in
                let status = hostStatus(row)
                let current = hosts.active == row.saved.id
                Button { _ = hosts.select(row.saved.id) } label: {
                    HStack(spacing: 10) {
                        Circle().fill(hostDotColor(row)).frame(width: 8, height: 8).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.saved.label).foregroundStyle(VerdeTheme.text)
                            Text(status).font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.muted)
                        }
                        Spacer(minLength: 8)
                        if current { Image(systemName: "checkmark").foregroundStyle(VerdeTheme.accent).accessibilityHidden(true) }
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.saved.label), \(status)")
                .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
                .accessibilityHint(current ? "" : "Switches to this host.")
            }
        } header: { SectionTitle("Hosts") } footer: {
            Text("Add, rename or sign out of hosts from Hosts.").font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted)
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: appVersionLabel(Bundle.main.infoDictionary))
            LabeledContent("Client core", value: ClientCore.version)
            NavigationLink("Open-source licences") { LicencesPage() }
            Link(destination: URL(string: "https://github.com/JonathanRiche/verde")!) {
                HStack { Text("Source code").foregroundStyle(VerdeTheme.text); Spacer(); Image(systemName: "arrow.up.right").foregroundStyle(VerdeTheme.subtle) }
            }
        } header: { SectionTitle("About") }
        .accessibilityIdentifier("settings-about")
    }
}

/// One row per bundled font, each opening its licence (I3-12).
private struct LicencesPage: View {
    var body: some View {
        List {
            TitledSection("Fonts and symbols") {
                ForEach(bundledLicences, id: \.1) { licence in
                    NavigationLink { LicenceText(title: licence.0, resource: licence.1) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(licence.0)
                            Text(licence.1.contains("OFL") ? "SIL Open Font License 1.1" : "MIT License")
                                .font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.muted)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden).background(VerdeTheme.background)
        .navigationTitle("Licences").navigationBarTitleDisplayMode(.inline)
    }
}

/// A licence's text, reflowed into paragraphs (the files hard-wrap at 70 columns), selectable.
private struct LicenceText: View {
    let title: String
    let resource: String

    var body: some View {
        let text = Bundle.main.url(forResource: resource, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(licenceParagraphs(text ?? "This licence text is missing from the app.").enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph).font(VerdeTheme.ui(14)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textSelection(.enabled)
            .padding(16)
        }
        .background(VerdeTheme.background)
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}

/// One blank-line block: rulers ("-----") are dropped, and an all-caps heading line ("PREAMBLE")
/// stands as its own paragraph instead of running into the text after it (I6-9).
func licenceBlockParagraphs(_ block: String) -> [String] {
    var out: [String] = []
    var current: [String] = []
    func flush() { if !current.isEmpty { out.append(current.joined(separator: " ")); current = [] } }
    for raw in block.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if line.allSatisfy({ $0 == "-" || $0 == "=" || $0 == "_" }) { flush(); continue }
        let letters = line.filter(\.isLetter)
        // A heading opens its block, is short, all caps and has no closing full stop.
        if current.isEmpty, !letters.isEmpty, letters == letters.uppercased(), line.count <= 40, !line.hasSuffix(".") {
            out.append(line); continue
        }
        current.append(line)
    }
    flush()
    return out
}

/// Hard-wrapped licence text as paragraphs: blank lines separate them, the lines within one join.
func licenceParagraphs(_ text: String) -> [String] {
    text.replacingOccurrences(of: "\r\n", with: "\n")
        .components(separatedBy: "\n\n")
        .flatMap(licenceBlockParagraphs)
        .filter { !$0.isEmpty }
}
