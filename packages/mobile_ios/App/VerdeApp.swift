import SwiftUI
import VerdeClient

enum ClientCore {
    // vc_version returns static storage; copy it into Swift and never free it.
    static var version: String { String(cString: vc_version()) }
}

@main
struct VerdeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var hosts: HostsModel
    @State private var browse: BrowseModel
    @State private var push: PushRegistry
    @State private var companion: CompanionModel
    /// Companion voice (speech-to-text and spoken replies), shared by the bubble and the sheet.
    @State private var companionVoice: CompanionVoice
    /// Real-time voice conversation with the Companion.
    @State private var live: LiveVoice

    init() {
        SharedFile.cleanup()
        VerdeTheme.configure()
        let hosts = HostsModel.live(deviceLabel: UIDevice.current.name)
        let push = PushRegistry.live()
        push.hosts = hosts
        hosts.onPushChange = { [weak push] id in push?.hostChanged(id) }
        AppDelegate.registry = push
        PushInbox.shared.forward = { [weak hosts] target in
            guard let host = hosts?.session(target.hostID)?.host, let workspace = target.workspaceID,
                  let thread = target.threadID, let turn = target.turnID else { return }
            Task {
                try? await host.send(.push_received(EventPushReceived(now_ms: 0, wall_time_ms: 0, workspace_id: workspace,
                    thread_id: thread, turn_id: turn, kind: target.kind)))
            }
        }
        _hosts = State(initialValue: hosts)
        let browse = BrowseModel(hosts: hosts, cache: hosts.cache)
        _browse = State(initialValue: browse)
        let companion = CompanionModel(browse: browse)
        let voice = CompanionVoice()
        _companion = State(initialValue: companion)
        _companionVoice = State(initialValue: voice)
        _live = State(initialValue: LiveVoice(companion: companion, speech: voice))
        _push = State(initialValue: push)
    }

    var body: some Scene {
        WindowGroup { RootView(hosts: hosts, browse: browse, push: push, companion: companion, companionVoice: companionVoice, live: live) }
    }
}

enum RootTab: Hashable { case home, workspaces, hosts }

private struct PairingSheet: Identifiable { let id: String }

/// Owns app-wide signals: scene phase → foreground/background, NWPathMonitor →
/// network_changed, and pairing links. HostsModel fans each out to every host core.
struct RootView: View {
    let hosts: HostsModel
    let browse: BrowseModel
    let push: PushRegistry
    let companion: CompanionModel
    let companionVoice: CompanionVoice
    let live: LiveVoice
    @State private var inbox = PushInbox.shared
    /// A notification's chat, opened once the host switch has cleared the old routes.
    @State private var routeAfterSwitch: BrowseRoute?
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
    @State private var companionSheet = false
    @State private var companionSettings = false
    /// The Live call bar's captions and full view, shared with the Companion sheet.
    @State private var livePill = LivePillState()

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
                if companion.available {
                    CompanionBubbleLayer(model: companion, voice: companionVoice, live: live, sheetOpen: companionSheet, visible: bubbleVisible,
                                         open: { companionSheet = true }, settings: { companionSettings = true })
                        .zIndex(3)
                        .sheet(isPresented: $companionSheet) {
                            CompanionSheet(model: companion, browse: browse, voice: companionVoice, live: live, pill: livePill, open: { route in
                                companionSheet = false
                                if tab == .hosts { tab = .home }
                                drawer = false
                                path.append(route)
                            }, showHome: {
                                companionSheet = false
                                drawer = false
                                tab = .home
                                path = []
                            }, onHosts: { companionSheet = false; tab = .hosts })
                            .presentationDetents([.medium, .large])
                            .presentationDragIndicator(.visible)
                            .preferredColorScheme(appearance.scheme)
                        }
                        .sheet(isPresented: $companionSettings) {
                            CompanionSettings(model: companion, browse: browse).preferredColorScheme(appearance.scheme)
                        }
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
        .background(LiveCallBar(live: live, companion: companion, pill: livePill, call: live.phase != .idle, covered: lock.covered,
                                prepare: prepareLiveTarget, present: presentLiveTarget).frame(width: 0, height: 0))
        .sheet(isPresented: $settings) { AppSettings(lock: lock, browse: browse, push: push) }
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
            companionVoice.cancel()
            companionVoice.stopSpeaking()
            live.end()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            lock.phase(.active)
            hosts.foreground(lock.loaded && !lock.locked)
            Task { await push.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in lock.inactive = true }
        .onChange(of: hosts.active) { _, _ in
            live.end()
            // Routes belong to the previous host's projections.
            path = routeAfterSwitch.map { [$0] } ?? []
            routeAfterSwitch = nil
            drawer = false
        }
        .onChange(of: live.active) { _, active in if !active { livePill.expanded = false } }
        .onChange(of: inbox.pending, initial: true) { _, _ in openNotification() }
        .onChange(of: hosts.loading) { _, _ in openNotification() }
        .onChange(of: visibleThread, initial: true) { _, key in VisibleThread.shared.set(key) }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // `.inactive` (app switcher, system sheets) keeps the current state.
            lock.phase(phase)
            if phase != .inactive { hosts.foreground(phase == .active && lock.loaded && !lock.locked) }
        }
    }

    /// The chat on screen (`host/workspace/thread`) for foreground notification suppression.
    private var visibleThread: String? {
        // The Companion sheet shows the companion's own chat.
        if companionSheet { return companion.visibleKey() }
        guard tab != .hosts, !drawer, !settings, let host = hosts.active,
              case .thread(let workspace, let thread)? = path.last else { return nil }
        return [host, workspace, thread].joined(separator: "/")
    }

    /// The bubble stays out of the drawer and off the companion's own chat screen.
    private var bubbleVisible: Bool {
        guard !drawer, !settings, !companionSettings else { return false }
        if let conversation = companion.conversation, tab != .hosts,
           case .thread(let workspace, let thread)? = path.last,
           workspace == conversation.workspace, thread == conversation.thread { return false }
        return true
    }

    /// The call bar's full view or voice settings: closes the app's own sheets over where it opens
    /// (the bar then waits for them to go) and reports what it opens over.
    private func prepareLiveTarget(_ target: LiveBarTarget) -> LiveBarBase {
        if target == .fullView { livePill.expanded = true }
        drawer = false
        if companionSheet {
            livePill.closeSheetChildren()
            return .companionSheet
        }
        if target == .voiceSettings && companionSettings { return .handled }
        settings = false
        companionSettings = false
        if hosts.pairing != nil { hosts.showPairing(nil) }
        return .app
    }

    private func presentLiveTarget(_ target: LiveBarTarget, over base: LiveBarBase) {
        switch (target, base) {
        case (.fullView, .app): companionSheet = true
        case (.voiceSettings, .app): companionSettings = true
        case (.voiceSettings, .companionSheet): livePill.openVoiceSettings()
        default: break
        }
    }

    /// A tapped notification or action: switch to its host and open the chat, handing any
    /// approval or reply to the chat screen.
    private func openNotification() {
        guard !hosts.loading, inbox.pending != nil, let target = inbox.take(), hosts.row(target.hostID) != nil else { return }
        var route: BrowseRoute?
        if let workspace = target.workspaceID, let thread = target.threadID {
            route = .thread(workspace: workspace, thread: thread)
            switch target.action {
            case .approve: ApprovalHandoff.put(host: target.hostID, workspace: workspace, thread: thread, .init(decision: .approve, turnID: target.turnID))
            case .deny: ApprovalHandoff.put(host: target.hostID, workspace: workspace, thread: thread, .init(decision: .deny, turnID: target.turnID))
            case .reply(let text): PromptHandoff.put(host: target.hostID, workspace: workspace, thread: thread, text: text)
            case .open: break
            }
        }
        settings = false
        drawer = false
        companionSheet = false
        companionSettings = false
        if tab == .hosts { tab = .home }
        if hosts.active != target.hostID {
            routeAfterSwitch = route
            if !hosts.select(target.hostID) { routeAfterSwitch = nil }
        } else if let route {
            if path.last != route { path = [route] }
            NotificationCenter.default.post(name: .verdeChatHandoff, object: nil)
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
