import SwiftUI
import VerdeClient

enum ClientCore {
    // vc_version returns static storage; copy it into Swift and never free it.
    static var version: String { String(cString: vc_version()) }
}

@main
struct VerdeApp: App {
    @State private var hosts: HostsModel
    @State private var browse: BrowseModel

    init() {
        SharedFile.cleanup()
        VerdeTheme.configure()
        let hosts = HostsModel.live(deviceLabel: UIDevice.current.name)
        _hosts = State(initialValue: hosts)
        _browse = State(initialValue: BrowseModel(hosts: hosts, cache: hosts.cache))
    }

    var body: some Scene {
        WindowGroup { RootView(hosts: hosts, browse: browse) }
    }
}

enum RootTab: Hashable { case home, workspaces, hosts }

private struct PairingSheet: Identifiable { let id: String }

/// Owns app-wide signals: scene phase → foreground/background, NWPathMonitor →
/// network_changed, and pairing links. HostsModel fans each out to every host core.
struct RootView: View {
    let hosts: HostsModel
    let browse: BrowseModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: RootTab = .home
    @State private var path: [BrowseRoute] = []
    @State private var drawer = false
    /// Drawer scope (nil = All Workspaces); survives drawer open/close, resets per host.
    @State private var workspaceScope: String?
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var monitor = NetworkMonitor()
    @State private var lock = AppLock()
    @State private var appearance = AppearanceSettings.shared
    @State private var settings = false

    @ViewBuilder private var shell: some View {
        let actions = BrowseActions(hosts: { tab = .hosts }, pair: {
            tab = .hosts
            hosts.showPairing(hosts.active)
        })
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Group {
                    if tab == .hosts { HostsScreen(model: hosts) { tab = .home; path = [] } }
                    else {
                        BrowseStack(model: browse, actions: actions, path: $path) {
                            if tab == .home { HomeScreen(model: browse, actions: actions) }
                            else { WorkspacesScreen(model: browse, actions: actions) }
                        }
                    }
                }.allowsHitTesting(!drawer).accessibilityHidden(drawer)
                if drawer {
                    Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { drawer = false }.accessibilityLabel("Close workspace drawer").accessibilityAddTraits(.isButton)
                    WorkspaceDrawer(browse: browse, selected: path.last, tab: tab, scope: $workspaceScope, close: { drawer = false }, open: { route in
                        if tab == .hosts { tab = .home }
                        path.append(route); drawer = false
                    }, root: { next in tab = next; path = []; drawer = false }, settings: { drawer = false; settings = true })
                    .allowsHitTesting(true).disabled(false).zIndex(2)
                    .frame(width: min(380, geometry.size.width * 0.92))
                    .transition(.move(edge: .leading))
                }
            }
            .animation(reducedMotion || appearance.reducedMotion ? nil : .easeOut(duration: 0.2), value: drawer)
            .environment(\.openWorkspaceDrawer, { drawer = true })
            .onChange(of: browse.hostID) { workspaceScope = nil }
            .onChange(of: browse.state.workspaces?.items.map(\.workspace_id)) { _, ids in
                if let scope = workspaceScope, let ids, !ids.contains(scope) { workspaceScope = nil }
            }
            .background(VerdeTheme.background.ignoresSafeArea())
        }
    }

    private var styled: some View {
        shell
        .preferredColorScheme(appearance.scheme)
        .tint(VerdeTheme.accent)
        .foregroundStyle(VerdeTheme.text)
        .font(VerdeTheme.ui())
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 44)
        .accessibilityHidden(lock.covered)
        .background(SecurityShield(lock: lock, covered: lock.covered).frame(width: 0, height: 0))
        .sheet(isPresented: $settings) { AppSettings(lock: lock, browse: browse) }
    }

    private var themeRefreshKey: String {
        [browse.hostID ?? "", appearance.mode.rawValue, browse.state.host?.auth_state ?? "", String(!lock.inactive), String(lock.locked)].joined(separator: "/")
    }
    private var lifecycleContent: some View {
        styled
        .task(id: themeRefreshKey) {
            if !lock.inactive && lock.loaded && !lock.locked { await appearance.refresh(browse) }
        }
        .onChange(of: lock.locked) { _, _ in hosts.foreground(!lock.inactive && lock.loaded && !lock.locked) }
        // The shield owns another UIWindow; UIKit notifications keep its lifecycle
        // independent of the covered SwiftUI view's scene environment.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            lock.phase(.background)
            hosts.foreground(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            lock.phase(.active)
            hosts.foreground(lock.loaded && !lock.locked)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in lock.inactive = true }
        .onChange(of: hosts.active) { _, _ in
            // Routes belong to the previous host's projections.
            path = []
            drawer = false
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // `.inactive` (app switcher, system sheets) keeps the current state.
            lock.phase(phase)
            if phase != .inactive { hosts.foreground(phase == .active && lock.loaded && !lock.locked) }
        }
    }

    var body: some View {
        lifecycleContent
        .task {
            lock.load()
            lock.phase(UIApplication.shared.applicationState == .active ? .active : .inactive)
            hosts.foreground(!lock.inactive && lock.loaded && !lock.locked)
            // Prefer the first path so new cores get start → network → foreground.
            monitor.start { state in
                hosts.network(state)
                hosts.begin()
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            hosts.begin()
        }
        .onOpenURL { url in hosts.open(url: url) }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { hosts.open(url: url) }
        }
        .sheet(item: Binding(get: { hosts.pairing.map(PairingSheet.init) },
                             set: { hosts.showPairing($0?.id) })) { sheet in
            if let session = hosts.session(sheet.id) {
                PairingView(model: session) { hosts.showPairing(nil) }
            }
        }
    }
}
