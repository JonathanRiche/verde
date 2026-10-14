import Foundation
import Observation

/// Companion state for the selected host: the machine roster, the active companion's crew and the
/// cross-workspace "needs you" list. Conversation, composer and approvals reuse the chat screens on
/// `(home_workspace_id, thread_id)`. Nothing here is logged.
@MainActor @Observable
final class CompanionModel {
    static let pollInterval: Duration = .seconds(4)

    /// The live channel: the host core's companion intents and `companion` view.
    static let liveRPC: (_ hostID: String, _ session: PairingModel) -> CompanionRPC? = { _, session in CoreCompanionRPC(session: session) }
    /// Resolves the companion channel for a host; tests substitute a scripted daemon.
    static var makeRPC = liveRPC

    let browse: BrowseModel
    private(set) var snapshot: RosterSnapshot?
    private(set) var crewLinks: [CrewLink] = []
    private(set) var notice: String?
    private(set) var saving = false
    private(set) var creatingThread = false
    /// Set when this host answered that it doesn't know the companion methods.
    private(set) var unsupportedHost: String?
    @ObservationIgnored private var boundHost: String?
    @ObservationIgnored private var channel: (host: String, rpc: CompanionRPC)?
    /// Keeps the not-yet-saved starter Sprout the same companion across refreshes.
    @ObservationIgnored private(set) var starterID = Roster.newID()

    init(browse: BrowseModel) { self.browse = browse }

    // MARK: Derived state

    private func rpc(_ hostID: String?) -> CompanionRPC? {
        guard let hostID, let session = browse.hosts.session(hostID) else { return nil }
        if let channel, channel.host == hostID { return channel.rpc }
        guard let made = Self.makeRPC(hostID, session) else { return nil }
        channel = (hostID, made)
        return made
    }

    /// The bubble and sheet appear only when this host can serve the roster; older hosts (the core
    /// reports `supported: false`, or a call answered "unknown method") show no Companion.
    var available: Bool {
        guard let id = browse.hostID else { return false }
        return unsupportedHost != id && coreSupported(id) && rpc(id) != nil
    }

    private func coreSupported(_ hostID: String) -> Bool {
        guard let data = browse.hosts.session(hostID)?.store.snapshots["companion"],
              let view = (try? JSONDecoder().decode(CompanionQuery.self, from: data))?.data else { return true }
        return view.supported
    }

    /// Home for a new or homeless companion: the most recently used open workspace.
    var defaultHome: String? { mostRecentOpenWorkspace(browse.state.workspaces?.items ?? [])?.workspace_id }

    /// The saved roster, or the starter Sprout before anything was saved.
    var roster: Roster? {
        guard var roster = snapshot?.roster else { return nil }
        roster.normalize(home: defaultHome, starterID: starterID)
        return roster.companions.isEmpty ? nil : roster
    }
    var active: RosterEntry? { roster?.active }

    /// The active companion's chat, once it exists.
    var conversation: (workspace: String, thread: String)? {
        guard let active, !active.home_workspace_id.isEmpty, !active.thread_id.isEmpty else { return nil }
        return (active.home_workspace_id, active.thread_id)
    }

    var crew: [CrewLink] { crewRows(crewLinks, home: active?.home_workspace_id ?? "") }

    var needsYou: [NeedsYouItem] {
        needsYouItems(home: browse.state.home, workspaces: browse.state.workspaces, crew: crew, companion: conversation)
    }

    /// The sheet's activity panel: crew plus every other chat running on the machine.
    var activity: [ActivityItem] {
        let state = browse.state
        return activityItems(crew: crew, home: state.home, workspaces: state.workspaces, companion: conversation,
                             hidden: browse.companionThreads)
    }

    /// Chats running machine-wide (crew included, the companion's own turn not).
    var runningCount: Int { activity.filter { $0.attention == .running }.count }

    private var threadSummary: ThreadSummary? {
        guard let conversation else { return nil }
        return browse.state.workspaces?.items.first { $0.workspace_id == conversation.workspace }?
            .threads.first { $0.thread_id == conversation.thread }
    }
    private var threadStatus: String? { threadSummary?.status }

    /// A companion turn is running in its chat (live transcript saves wait for it).
    var conversationBusy: Bool { threadStatus.map(activeTurn) ?? false }

    /// The bubble badge: everything in "Needs you" plus the companion's own pending approval.
    var badgeCount: Int { companionBadgeCount(needsYou: needsYou.count, ownApproval: threadStatus == "waiting_approval") }

    /// Changes when the companion finishes a turn (its chat went quiet with newer activity); the
    /// bubble pops "<Name> replied" for a change it hasn't seen.
    var replyKey: String? {
        guard let summary = threadSummary, !activeTurn(summary.status), let at = summary.last_activity_at_ms else { return nil }
        return summary.thread_id + "@" + String(at)
    }

    var presence: CompanionPresence {
        let status = threadStatus
        let host = browse.state.host
        return companionPresence(needsYou: badgeCount,
                                 crewRunning: runningCount,
                                 working: status.map(activeTurn) ?? false, failed: status == "failed",
                                 connected: browse.state.networkAvailable && host?.phase == "ready")
    }

    // MARK: Effects

    private func resetIfHostChanged() {
        guard boundHost != browse.hostID else { return }
        boundHost = browse.hostID
        snapshot = nil
        crewLinks = []
        notice = nil
        starterID = Roster.newID()
    }

    private func failed(_ error: Error, host: String) {
        guard browse.hostID == host else { return }
        switch error as? CompanionRPCError {
        case .unsupported?: unsupportedHost = host
        case .conflict?: notice = "Another device changed your companions. Try again."
        default: notice = "Couldn't reach your companion. It will retry shortly."
        }
    }

    /// One roster + crew read. Cheap; called by `poll` while the screen is visible.
    func refresh() async {
        resetIfHostChanged()
        guard let host = browse.hostID, let rpc = rpc(host), unsupportedHost != host,
              browse.state.host?.phase == "ready" else { return }
        let client = CompanionClient(rpc: rpc)
        do {
            let next = try await client.roster()
            guard browse.hostID == host else { return }
            // A save that landed while this read was in flight is newer; keep it.
            if !saving, next.revision >= (snapshot?.revision ?? 0) { snapshot = next }
            notice = nil
            if let conversation {
                let links = try await client.crew(workspace: conversation.workspace, thread: conversation.thread)
                if browse.hostID == host { crewLinks = links }
            } else {
                crewLinks = []
            }
        } catch { failed(error, host: host) }
    }

    /// Refreshes every `interval` until cancelled (sheet state changed or the scene went inactive).
    func poll(every interval: Duration = CompanionModel.pollInterval) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: interval)
        }
    }

    /// Saves a roster change, re-applying it on a revision conflict.
    @discardableResult
    func update(_ change: @escaping (inout Roster) -> Bool) async -> Bool {
        resetIfHostChanged()
        guard !saving, let host = browse.hostID, let rpc = rpc(host) else { return false }
        saving = true
        defer { saving = false }
        let client = CompanionClient(rpc: rpc)
        do {
            let base: RosterSnapshot
            if let snapshot { base = snapshot } else { base = try await client.roster() }
            let next = try await client.update(base, home: defaultHome, starterID: starterID, change)
            guard browse.hostID == host else { return false }
            snapshot = next
            notice = nil
            return true
        } catch {
            failed(error, host: host)
            return false
        }
    }

    func select(_ id: String) async {
        crewLinks = []
        await update { $0.select(id) }
        await refresh()
    }

    /// The active companion's chat, creating it in its home workspace (with its preferred brain)
    /// and saving it to the roster on first use. Another device that bound a thread first wins.
    func ensureConversation() async -> (workspace: String, thread: String)? {
        if let conversation { return conversation }
        guard !creatingThread, let active, let host = browse.hostID else { return nil }
        let home = active.home_workspace_id.isEmpty ? defaultHome : active.home_workspace_id
        guard let home else {
            notice = "Add a workspace on the computer first."
            return nil
        }
        creatingThread = true
        defer { creatingThread = false }
        let manage = ManageModel(browse: browse)
        await manage.start()
        await manage.select(home, ChatSelection(provider: active.provider.isEmpty ? nil : active.provider,
                                                model: active.model.isEmpty ? nil : active.model))
        guard browse.hostID == host else { return nil }
        guard let job = await manage.createThread(home), let thread = job.thread_id else {
            notice = manage.notice ?? "Couldn't start your companion's chat."
            return nil
        }
        let workspace = job.workspace_id ?? home
        let id = active.id
        await update { $0.bindThread(id, workspace: workspace, thread: thread) }
        return conversation
    }

    // MARK: Brain switch and conversations

    /// The brain switch this phone asked for (its failures are shown; others' are not).
    @ObservationIgnored private var switchIntent: String?

    /// The host's latest brain switch.
    var brainSwitch: BrainSwitchState? { snapshot?.brainSwitch }

    /// "Handing off to Codex…" while a switch runs; this phone's failure afterwards.
    var brainSwitchText: String? {
        guard let state = brainSwitch else { return nil }
        if state.status == "failed" && state.intent_id != switchIntent { return nil }
        return brainSwitchStatusText(state, name: active?.name ?? "Your companion")
    }

    /// Switches the active companion's provider on the same conversation. Returns an error message.
    func switchBrain(provider: String, model modelID: String?, brief: Bool) async -> String? {
        let name = active?.name ?? "Your companion"
        guard let host = browse.hostID, let rpc = rpc(host), let id = active?.id else { return brainSwitchErrorText(nil, name: name) }
        if conversationBusy { return brainSwitchErrorText("companion_busy", name: name) }
        do {
            let state = try await CompanionClient(rpc: rpc).switchBrain(companionID: id, provider: provider, model: modelID, brief: brief)
            guard browse.hostID == host else { return nil }
            switchIntent = state?.intent_id
            if let state, var current = snapshot { current.brainSwitch = state; snapshot = current }
            if state?.status == "failed" { return brainSwitchErrorText(state?.error_code, name: name) }
            await refresh()
            return nil
        } catch CompanionRPCError.remote(let code) {
            return brainSwitchErrorText(code, name: name)
        } catch {
            failed(error, host: host)
            return brainSwitchErrorText(nil, name: name)
        }
    }

    /// The current conversation's title for the history list.
    var conversationTitle: String {
        let title = threadSummary?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Conversation" : title
    }

    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// "New conversation": the current chat goes to the history; the next message starts a fresh
    /// chat with the companion's brain.
    @discardableResult
    func newConversation() async -> Bool {
        guard let id = active?.id else { return false }
        let title = conversationTitle, now = nowMs
        crewLinks = []
        return await update { $0.startNewConversation(id, title: title, at: now) }
    }

    /// Goes back to an earlier conversation from the history.
    @discardableResult
    func resumeConversation(_ threadID: String) async -> Bool {
        guard let id = active?.id else { return false }
        let title = conversationTitle, now = nowMs
        crewLinks = []
        return await update { $0.resumeConversation(id, threadID: threadID, currentTitle: title, at: now) }
    }

    /// Drops a past conversation from the list (the chat itself stays).
    func removeConversation(_ threadID: String) async {
        guard let id = active?.id else { return }
        await update { $0.removeHistory(id, threadID: threadID) }
    }

    /// `host/workspace/thread` of the companion chat while it is on screen (notification suppression).
    func visibleKey() -> String? {
        guard let host = browse.hostID, let conversation else { return nil }
        return [host, conversation.workspace, conversation.thread].joined(separator: "/")
    }
}
