import SwiftUI
import Observation

enum AppearanceMode: String, CaseIterable { case verde, host, system
    var label: String { switch self { case .verde: return "Verde dark"; case .host: return "Host theme"; case .system: return "System" } }
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
        mode = AppearanceMode(rawValue: defaults.string(forKey: "ios.appearance") ?? "") ?? .verde
    }
    var scheme: ColorScheme? { mode == .system ? nil : mode == .host && palette?.dark == false ? .light : .dark }
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
            notice = "Host theme unavailable. Showing Verde dark until you reconnect or retry."
        }
    }
    func color(_ key: String, fallback: UInt32, light: UInt32? = nil) -> Color {
        if mode == .host, let value = palette?.color(key) { return value }
        if mode == .system, let light {
            return Color(uiColor: UIColor { traits in UIColor(Color(hex: traits.userInterfaceStyle == .dark ? fallback : light)) })
        }
        return Color(hex: fallback)
    }
}

struct AppSettings: View {
    let lock: AppLock
    let browse: BrowseModel
    @Environment(\.dismiss) private var dismiss
    @State private var appearance = AppearanceSettings.shared
    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $appearance.mode) { ForEach(AppearanceMode.allCases, id: \.self) { Text($0.label).tag($0) } }
                    if appearance.mode == .host {
                        Button("Reload host theme") { Task { await appearance.refresh(browse) } }
                        if let notice = appearance.notice { Text(notice).font(VerdeTheme.ui(13)) }
                    }
                    Text("Animations follow Reduce Motion in iOS Accessibility settings and the host theme when supplied.").font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted)
                }
                CommitSettingsSection(browse: browse)
                SecuritySettings(lock: lock)
            }.scrollContentBackground(.hidden).background(VerdeTheme.background)
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }.preferredColorScheme(appearance.scheme).tint(VerdeTheme.accent).foregroundStyle(VerdeTheme.text).font(VerdeTheme.ui())
    }
}
