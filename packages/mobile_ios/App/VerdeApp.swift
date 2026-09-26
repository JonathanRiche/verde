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
    @State private var homePath: [BrowseRoute] = []
    @State private var workspacesPath: [BrowseRoute] = []
    @State private var monitor = NetworkMonitor()

    var body: some View {
        let actions = BrowseActions(hosts: { tab = .hosts }, pair: {
            tab = .hosts
            hosts.showPairing(hosts.active)
        })
        TabView(selection: $tab) {
            BrowseStack(model: browse, actions: actions, path: $homePath) { HomeScreen(model: browse, actions: actions) }
                .tabItem { Label("Home", systemImage: "house") }.tag(RootTab.home)
            BrowseStack(model: browse, actions: actions, path: $workspacesPath) { WorkspacesScreen(model: browse, actions: actions) }
                .tabItem { Label("Workspaces", systemImage: "square.stack") }.tag(RootTab.workspaces)
            HostsScreen(model: hosts) { tab = .home }
                .tabItem { Label("Hosts", systemImage: "desktopcomputer") }.tag(RootTab.hosts)
        }
        .onChange(of: hosts.active) { _, _ in
            // Routes belong to the previous host's projections.
            homePath = []
            workspacesPath = []
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // `.inactive` (app switcher, system sheets) keeps the current state.
            if phase != .inactive { hosts.foreground(phase == .active) }
        }
        .task {
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
