import Foundation

/*
 * The machine-wide Companion: wire models, roster rules and crew mapping. Pure and unit tested;
 * `CompanionModel` owns the effects. The daemon stores one roster per machine
 * (`companion.roster.get/put`) and appends the companion's persona and standing orders to every
 * turn in its thread, so the app sends ordinary chat turns. Names, orders and summaries are
 * user content and are never logged.
 */

enum CompanionCharacter: String, CaseIterable, Identifiable, Codable {
    case sprout, moss, vireo
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .sprout: return "Sprout"
        case .moss: return "Moss"
        case .vireo: return "Vireo"
        }
    }
    /// Matches the desktop roster: characters double as an autonomy preset in the persona.
    var tagline: String {
        switch self {
        case .sprout: return "Careful · checks in before big moves"
        case .moss: return "Steady · does the work, then summarizes"
        case .vireo: return "Quick · runs ahead, pings only when it matters"
        }
    }
}

/// Coding keys for fields this build doesn't know; they are kept and written back on `put`.
private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func decodeExtras(_ decoder: Decoder, known: Set<String>) throws -> [String: JSONValue] {
    let container = try decoder.container(keyedBy: AnyKey.self)
    var extras: [String: JSONValue] = [:]
    for key in container.allKeys where !known.contains(key.stringValue) {
        extras[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
    }
    return extras
}

private func encodeExtras(_ extras: [String: JSONValue], _ encoder: Encoder, known: Set<String>) throws {
    var container = encoder.container(keyedBy: AnyKey.self)
    for (key, value) in extras where !known.contains(key) { try container.encode(value, forKey: AnyKey(key)) }
}

/// A past companion conversation ("Conversations…"), newest first in `RosterEntry.history`.
struct CompanionHistoryItem: Codable, Equatable, Identifiable {
    var thread_id: String
    var title: String
    var provider: String
    var model: String
    var ended_at_ms: Int64
    var id: String { thread_id }

    init(thread_id: String, title: String, provider: String = "", model: String = "", ended_at_ms: Int64) {
        self.thread_id = thread_id; self.title = title; self.provider = provider; self.model = model; self.ended_at_ms = ended_at_ms
    }
    private enum Keys: String, CodingKey { case thread_id, title, provider, model, ended_at_ms }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        thread_id = try c.decodeIfPresent(String.self, forKey: .thread_id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        ended_at_ms = try c.decodeIfPresent(Int64.self, forKey: .ended_at_ms) ?? 0
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(thread_id, forKey: .thread_id)
        try c.encode(title, forKey: .title)
        try c.encode(provider, forKey: .provider)
        try c.encode(model, forKey: .model)
        try c.encode(ended_at_ms, forKey: .ended_at_ms)
    }
}

struct RosterEntry: Codable, Identifiable, Equatable {
    static let nameLimit = 32
    static let ordersLimit = 1024
    static let historyLimit = 12

    var id: String
    var name: String
    /// The wire string; unknown characters from a newer host draw as Sprout but round-trip unchanged.
    var characterRaw: String
    var home_workspace_id: String
    /// Empty until the companion's chat thread exists.
    var thread_id: String
    var provider: String
    var model: String
    var orders: String
    /// Earlier conversations, newest first (at most `historyLimit`); kept on every save.
    var history: [CompanionHistoryItem] = []
    var extras: [String: JSONValue] = [:]

    var character: CompanionCharacter {
        get { CompanionCharacter(rawValue: characterRaw) ?? .sprout }
        set { characterRaw = newValue.rawValue }
    }

    init(id: String, name: String, character: CompanionCharacter, home_workspace_id: String,
         thread_id: String = "", provider: String = "", model: String = "", orders: String = "") {
        self.id = id
        self.name = name
        characterRaw = character.rawValue
        self.home_workspace_id = home_workspace_id
        self.thread_id = thread_id
        self.provider = provider
        self.model = model
        self.orders = orders
    }

    private enum Keys: String, CodingKey, CaseIterable {
        case id, name, character, home_workspace_id, thread_id, provider, model, orders, history
    }
    private static let known = Set(Keys.allCases.map(\.rawValue))

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        characterRaw = try c.decodeIfPresent(String.self, forKey: .character) ?? CompanionCharacter.sprout.rawValue
        home_workspace_id = try c.decodeIfPresent(String.self, forKey: .home_workspace_id) ?? ""
        thread_id = try c.decodeIfPresent(String.self, forKey: .thread_id) ?? ""
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        orders = try c.decodeIfPresent(String.self, forKey: .orders) ?? ""
        history = (try? c.decodeIfPresent([CompanionHistoryItem].self, forKey: .history)) ?? []
        extras = try decodeExtras(decoder, known: Self.known)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(characterRaw, forKey: .character)
        try c.encode(home_workspace_id, forKey: .home_workspace_id)
        try c.encode(thread_id, forKey: .thread_id)
        try c.encode(provider, forKey: .provider)
        try c.encode(model, forKey: .model)
        try c.encode(orders, forKey: .orders)
        try c.encode(history, forKey: .history)
        try encodeExtras(extras, encoder, known: Self.known)
    }

    /// Unknown fields are compared by key only (`JSONValue` is not Equatable).
    static func == (a: RosterEntry, b: RosterEntry) -> Bool {
        a.id == b.id && a.name == b.name && a.characterRaw == b.characterRaw && a.home_workspace_id == b.home_workspace_id &&
            a.thread_id == b.thread_id && a.provider == b.provider && a.model == b.model && a.orders == b.orders &&
            a.history == b.history && Set(a.extras.keys) == Set(b.extras.keys)
    }
}

struct Roster: Codable, Equatable {
    static let maxCompanions = 8

    var version: Int = 1
    var active_id: String = ""
    var companions: [RosterEntry] = []
    var extras: [String: JSONValue] = [:]

    init(version: Int = 1, active_id: String = "", companions: [RosterEntry] = []) {
        self.version = version
        self.active_id = active_id
        self.companions = companions
    }

    private enum Keys: String, CodingKey, CaseIterable { case version, active_id, companions }
    private static let known = Set(Keys.allCases.map(\.rawValue))

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        active_id = try c.decodeIfPresent(String.self, forKey: .active_id) ?? ""
        companions = try c.decodeIfPresent([RosterEntry].self, forKey: .companions) ?? []
        extras = try decodeExtras(decoder, known: Self.known)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(version, forKey: .version)
        try c.encode(active_id, forKey: .active_id)
        try c.encode(companions, forKey: .companions)
        try encodeExtras(extras, encoder, known: Self.known)
    }

    static func == (a: Roster, b: Roster) -> Bool {
        a.version == b.version && a.active_id == b.active_id && a.companions == b.companions && Set(a.extras.keys) == Set(b.extras.keys)
    }

    /// The active companion; a missing or stale `active_id` falls back to the first.
    var active: RosterEntry? { companions.first { $0.id == active_id } ?? companions.first }
    var activeIndex: Int? { active.flatMap { entry in companions.firstIndex { $0.id == entry.id } } }
    var isFull: Bool { companions.count >= Self.maxCompanions }

    /// A never-saved (or emptied) roster still shows one companion: Sprout, homed in `workspace`.
    static func starter(home workspace: String, id: String = Roster.newID()) -> Roster {
        let sprout = RosterEntry(id: id, name: CompanionCharacter.sprout.displayName, character: .sprout, home_workspace_id: workspace)
        return Roster(active_id: sprout.id, companions: [sprout])
    }

    static func newID(now: Date = Date()) -> String {
        "cmp-\(Int64(now.timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// Fills an empty roster with the starter (a stable `starterID` keeps it the same companion
    /// across refreshes) and repairs `active_id` and missing homes.
    mutating func normalize(home workspace: String?, starterID: String) {
        if companions.isEmpty, let workspace {
            let kept = extras
            self = Self.starter(home: workspace, id: starterID)
            extras = kept
        }
        if let workspace { for index in companions.indices where companions[index].home_workspace_id.isEmpty { companions[index].home_workspace_id = workspace } }
        if let active { active_id = active.id }
    }

    @discardableResult
    mutating func add(_ character: CompanionCharacter, name: String? = nil, home: String, id: String = Roster.newID()) -> RosterEntry? {
        guard !isFull else { return nil }
        let base = cleanCompanionName(name ?? "")
        var entry = RosterEntry(id: id, name: "", character: character, home_workspace_id: home)
        entry.name = uniqueName(base.isEmpty ? character.displayName : base, skipping: nil)
        companions.append(entry)
        active_id = entry.id
        return entry
    }

    /// Never removes the last companion.
    @discardableResult
    mutating func remove(_ id: String) -> Bool {
        guard companions.count > 1, let index = companions.firstIndex(where: { $0.id == id }) else { return false }
        companions.remove(at: index)
        if active_id == id { active_id = companions[min(index, companions.count - 1)].id }
        return true
    }

    @discardableResult
    mutating func select(_ id: String) -> Bool {
        guard companions.contains(where: { $0.id == id }) else { return false }
        active_id = id
        return true
    }

    @discardableResult
    mutating func rename(_ id: String, to raw: String) -> Bool {
        let clean = cleanCompanionName(raw)
        guard !clean.isEmpty, let index = companions.firstIndex(where: { $0.id == id }) else { return false }
        companions[index].name = uniqueName(clean, skipping: id)
        return true
    }

    mutating func edit(_ id: String, _ change: (inout RosterEntry) -> Void) {
        guard let index = companions.firstIndex(where: { $0.id == id }) else { return }
        change(&companions[index])
        companions[index].orders = utf8Prefix(companions[index].orders, RosterEntry.ordersLimit)
    }

    /// Saves the companion's brain; with `thread`, also moves it to a fresh conversation (a provider
    /// switch). Returns false when the companion is gone or nothing changed.
    @discardableResult
    mutating func setBrain(_ id: String, provider: String, model: String, thread: (workspace: String, thread: String)? = nil) -> Bool {
        guard let index = companions.firstIndex(where: { $0.id == id }) else { return false }
        var entry = companions[index]
        entry.provider = provider
        entry.model = model
        if let thread {
            entry.home_workspace_id = thread.workspace
            entry.thread_id = thread.thread
        }
        guard entry != companions[index] else { return false }
        companions[index] = entry
        return true
    }

    /// "New conversation": the current chat moves to the front of the history (deduplicated,
    /// capped) and the companion starts fresh; its next message creates a new chat with its brain.
    @discardableResult
    mutating func startNewConversation(_ id: String, title: String, at now: Int64) -> Bool {
        guard let index = companions.firstIndex(where: { $0.id == id }), !companions[index].thread_id.isEmpty else { return false }
        Self.pushHistory(&companions[index], title: title, at: now)
        companions[index].thread_id = ""
        return true
    }

    /// Goes back to an earlier conversation: it leaves the history, the current one joins it, and
    /// the companion takes the earlier chat's brain when the entry recorded one.
    @discardableResult
    mutating func resumeConversation(_ id: String, threadID: String, currentTitle: String, at now: Int64) -> Bool {
        guard let index = companions.firstIndex(where: { $0.id == id }),
              let item = companions[index].history.first(where: { $0.thread_id == threadID }),
              companions[index].thread_id != threadID else { return false }
        companions[index].history.removeAll { $0.thread_id == threadID }
        if !companions[index].thread_id.isEmpty { Self.pushHistory(&companions[index], title: currentTitle, at: now) }
        companions[index].thread_id = item.thread_id
        if !item.provider.isEmpty { companions[index].provider = item.provider }
        if !item.model.isEmpty { companions[index].model = item.model }
        return true
    }

    /// "Remove from list": drops a past conversation from the history only (the chat stays).
    @discardableResult
    mutating func removeHistory(_ id: String, threadID: String) -> Bool {
        guard let index = companions.firstIndex(where: { $0.id == id }),
              companions[index].history.contains(where: { $0.thread_id == threadID }) else { return false }
        companions[index].history.removeAll { $0.thread_id == threadID }
        return true
    }

    private static func pushHistory(_ entry: inout RosterEntry, title: String, at now: Int64) {
        let item = CompanionHistoryItem(thread_id: entry.thread_id, title: title.isEmpty ? "Conversation" : title,
                                        provider: entry.provider, model: entry.model, ended_at_ms: now)
        entry.history.removeAll { $0.thread_id == item.thread_id }
        entry.history.insert(item, at: 0)
        if entry.history.count > RosterEntry.historyLimit { entry.history.removeLast(entry.history.count - RosterEntry.historyLimit) }
    }

    /// Records a newly created thread only if no other client bound one meanwhile.
    @discardableResult
    mutating func bindThread(_ id: String, workspace: String, thread: String) -> Bool {
        guard let index = companions.firstIndex(where: { $0.id == id }), companions[index].thread_id.isEmpty else { return false }
        companions[index].home_workspace_id = workspace
        companions[index].thread_id = thread
        return true
    }

    private func uniqueName(_ base: String, skipping id: String?) -> String {
        func taken(_ name: String) -> Bool { companions.contains { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame } }
        guard taken(base) else { return base }
        for suffix in 2..<100 {
            let tail = " \(suffix)"
            let candidate = utf8Prefix(base, RosterEntry.nameLimit - tail.utf8.count).trimmingCharacters(in: .whitespaces) + tail
            if !taken(candidate) { return candidate }
        }
        return base
    }
}

/// Trims, drops control characters (stopping at the first, like the desktop) and clips to 32 UTF-8 bytes.
func cleanCompanionName(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    var scalars = String.UnicodeScalarView()
    for scalar in trimmed.unicodeScalars {
        if scalar.value < 0x20 || scalar.value == 0x7f { break }
        scalars.append(scalar)
    }
    return utf8Prefix(String(scalars), RosterEntry.nameLimit).trimmingCharacters(in: .whitespaces)
}

/// The longest prefix of whole characters within `limit` UTF-8 bytes.
func utf8Prefix(_ value: String, _ limit: Int) -> String {
    guard value.utf8.count > limit else { return value }
    var out = ""
    var used = 0
    for character in value {
        let size = String(character).utf8.count
        if used + size > limit { break }
        out.append(character)
        used += size
    }
    return out
}

// MARK: - Wire envelopes

struct RosterSnapshot: Equatable {
    /// 0 = never saved.
    var revision: Int
    var roster: Roster
    /// The latest brain switch the host reported.
    var brainSwitch: BrainSwitchState? = nil
}

/// `companion.brain_switch`: a provider switch that keeps the conversation (brief, then switch).
struct BrainSwitchState: Codable, Equatable {
    var intent_id: String
    /// `pending`, `briefing`, `switched` or `failed`.
    var status: String
    var error_code: String?
    var from: String
    var to: String

    init(intent_id: String, status: String, error_code: String? = nil, from: String, to: String) {
        self.intent_id = intent_id; self.status = status; self.error_code = error_code; self.from = from; self.to = to
    }
    private enum Keys: String, CodingKey { case intent_id, status, error_code, from, to }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        intent_id = try c.decodeIfPresent(String.self, forKey: .intent_id) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        error_code = try c.decodeIfPresent(String.self, forKey: .error_code)
        from = try c.decodeIfPresent(String.self, forKey: .from) ?? ""
        to = try c.decodeIfPresent(String.self, forKey: .to) ?? ""
    }
    var inProgress: Bool { status == "pending" || status == "briefing" }
}

private struct RosterGetResponse: Decodable {
    var revision: Int?
    var roster: Roster?
    var brain_switch: BrainSwitchState?
}
private struct BrainSwitchRequest: Encodable {
    var companion_id: String
    var provider: String
    var model: String?
    var brief: Bool
}
private struct BrainSwitchResponse: Decodable { var brain_switch: BrainSwitchState? }
private struct RosterPutRequest: Encodable {
    var roster: Roster
    var expected_revision: Int
}
private struct RosterPutResponse: Decodable { var revision: Int }
private struct LinksListRequest: Encodable {
    var workspace_id: String
    var parent_thread_id: String
}
private struct LinksListResponse: Decodable { var links: [CrewLink]? }

// MARK: - Crew

/// How a crew row leans; mirrors the desktop `companionAttentionForLink` and its sort rank.
enum CrewAttention: Equatable {
    case approval, blocked, failed, running, done, idle

    init(status: String) {
        switch status {
        case "waiting_approval": self = .approval
        case "blocked": self = .blocked
        case "running": self = .running
        case "failed", "aborted", "interrupted": self = .failed
        case "completed": self = .done
        default: self = .idle
        }
    }
    var rank: Int {
        switch self {
        case .approval, .blocked: return 0
        case .failed: return 1
        case .running: return 2
        case .done: return 3
        case .idle: return 4
        }
    }
    var label: String {
        switch self {
        case .approval: return "Needs approval"
        case .blocked: return "Needs input"
        case .failed: return "Failed"
        case .running: return "Running"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }
    var needsYou: Bool { self == .approval || self == .blocked }
}

/// One chat the companion delegated to (`chat.links.list` row).
struct CrewLink: Decodable, Equatable, Identifiable {
    var link_id: String
    /// The child's workspace; may differ from the companion's home.
    var workspace_id: String
    var parent_workspace_id: String
    var local_thread_id: String
    var title: String
    var provider: String
    var status: String
    var summary: String
    var updated_at_ms: Int64
    var hidden: Bool

    var id: String { link_id.isEmpty ? workspace_id + "/" + local_thread_id : link_id }
    var attention: CrewAttention { CrewAttention(status: status) }
    var displayTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled chat" : title }
    /// First line of the child's summary, if any.
    var detail: String? {
        let line = summary.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return line.isEmpty ? nil : line
    }

    init(link_id: String = "", workspace_id: String, parent_workspace_id: String = "", local_thread_id: String, title: String = "",
         provider: String = "", status: String = "idle", summary: String = "", updated_at_ms: Int64 = 0, hidden: Bool = false) {
        self.link_id = link_id
        self.workspace_id = workspace_id
        self.parent_workspace_id = parent_workspace_id
        self.local_thread_id = local_thread_id
        self.title = title
        self.provider = provider
        self.status = status
        self.summary = summary
        self.updated_at_ms = updated_at_ms
        self.hidden = hidden
    }

    private enum Keys: String, CodingKey {
        case link_id, workspace_id, parent_workspace_id, local_thread_id, title, provider, status, summary, updated_at_ms, hidden
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        link_id = try c.decodeIfPresent(String.self, forKey: .link_id) ?? ""
        workspace_id = try c.decodeIfPresent(String.self, forKey: .workspace_id) ?? ""
        parent_workspace_id = try c.decodeIfPresent(String.self, forKey: .parent_workspace_id) ?? ""
        local_thread_id = try c.decodeIfPresent(String.self, forKey: .local_thread_id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "idle"
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        updated_at_ms = try c.decodeIfPresent(Int64.self, forKey: .updated_at_ms) ?? 0
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }
}

/// Visible crew, needs-you first, then newest. A link without a child workspace lives in `home`.
func crewRows(_ links: [CrewLink], home: String) -> [CrewLink] {
    links.filter { !$0.hidden && !$0.local_thread_id.isEmpty }
        .map { link in
            var link = link
            if link.workspace_id.isEmpty { link.workspace_id = link.parent_workspace_id.isEmpty ? home : link.parent_workspace_id }
            return link
        }
        .sorted {
            if $0.attention.rank != $1.attention.rank { return $0.attention.rank < $1.attention.rank }
            if $0.updated_at_ms != $1.updated_at_ms { return $0.updated_at_ms > $1.updated_at_ms }
            return $0.id < $1.id
        }
}

// MARK: - Needs you and status

/// A chat anywhere on the machine that is waiting on the user.
struct NeedsYouItem: Equatable, Identifiable {
    var workspaceID: String
    var threadID: String
    var title: String
    var workspaceLabel: String?
    var reason: String
    var id: String { workspaceID + "/" + threadID }
}

/// Approvals and blocked chats across every workspace, from the existing Home projection
/// (panes with K-17 attention) and thread statuses, plus crew rows that need the user.
/// The companion's own thread is excluded; its approval shows inline in the conversation.
func needsYouItems(home: HomeView?, workspaces: WorkspacesView?, crew: [CrewLink], companion: (workspace: String, thread: String)?) -> [NeedsYouItem] {
    let labels = Dictionary((workspaces?.items ?? []).map { ($0.workspace_id, $0.label) }, uniquingKeysWith: { a, _ in a })
    var seen = Set<String>()
    var items: [NeedsYouItem] = []
    func add(_ workspace: String, _ thread: String, _ title: String, _ reason: String) {
        let key = workspace + "/" + thread
        if let companion, companion.workspace == workspace, companion.thread == thread { return }
        guard !thread.isEmpty, seen.insert(key).inserted else { return }
        items.append(NeedsYouItem(workspaceID: workspace, threadID: thread, title: title.isEmpty ? "Untitled chat" : title,
                                  workspaceLabel: labels[workspace], reason: reason))
    }
    for pane in home?.items ?? [] where pane.kind == "chat" {
        guard let thread = pane.thread_id else { continue }
        if pane.attention_kind == "needs_approval" || pane.status == "waiting_approval" { add(pane.workspace_id, thread, pane.title, "Needs approval") }
        else if pane.attention_kind == "blocked" { add(pane.workspace_id, thread, pane.title, "Needs input") }
    }
    for workspace in workspaces?.items ?? [] {
        for thread in workspace.threads where thread.status == "waiting_approval" && !thread.archived && !isSubagent(thread) {
            add(thread.workspace_id, thread.thread_id, thread.title, "Needs approval")
        }
    }
    for link in crew where link.attention.needsYou { add(link.workspace_id, link.local_thread_id, link.displayTitle, link.attention.label) }
    return items
}

enum CompanionPose: Equatable { case idle, working, approval, paused }

struct CompanionPresence: Equatable {
    var pose: CompanionPose
    var failure: Bool
    var status: String
}

/// Pose and one-line status from real state only: needing the user outranks work, nothing looks
/// busy unless the companion's turn or a crew chat is actually running, and an offline host pauses.
func companionPresence(needsYou: Int, crewRunning: Int, working: Bool, failed: Bool, connected: Bool) -> CompanionPresence {
    let pose: CompanionPose = !connected ? .paused : needsYou > 0 ? .approval : (working || crewRunning > 0) ? .working : .idle
    let status: String
    if !connected { status = "Waiting for the host" }
    else if needsYou > 0 { status = needsYou == 1 ? "1 thing needs you" : "\(needsYou) things need you" }
    else if failed { status = "Needs a look" }
    else if working && crewRunning > 0 { status = "Working · \(crewRunning) in crew" }
    else if working { status = "Working…" }
    else if crewRunning > 0 { status = crewRunning == 1 ? "1 chat running" : "\(crewRunning) chats running" }
    else { status = "Ready when you are" }
    return CompanionPresence(pose: pose, failure: failed, status: status)
}

let companionSuggestions = [
    "What's running across my workspaces right now?",
    "Check every workspace for chats that need me.",
    "Start the dev servers for this workspace and watch them.",
]

// MARK: - RPC

enum CompanionMethod: String {
    case rosterGet = "companion.roster.get"
    case rosterPut = "companion.roster.put"
    case linksList = "chat.links.list"
    case brainSwitch = "companion.brain.switch"
}

enum CompanionRPCError: Error, Equatable {
    /// This build's host core can't issue the method, or the host doesn't know it.
    case unsupported
    /// `companion.roster.put` lost a revision race; re-get and re-apply.
    case conflict
    case remote(code: String)
    case invalidResponse
}

/// Sends one daemon RPC for the active host and returns its JSON `result`. Errors map the daemon
/// code (`conflict`, `method_not_found`, ...) onto `CompanionRPCError`.
protocol CompanionRPC: AnyObject {
    func call(_ method: CompanionMethod, params: Data) async throws -> Data
}

/// Typed roster/crew calls with conflict-retrying updates.
struct CompanionClient {
    static let maxAttempts = 3
    let rpc: CompanionRPC

    func roster() async throws -> RosterSnapshot {
        let data = try await rpc.call(.rosterGet, params: Data("{}".utf8))
        guard let response = try? JSONDecoder().decode(RosterGetResponse.self, from: data) else { throw CompanionRPCError.invalidResponse }
        return RosterSnapshot(revision: response.revision ?? 0, roster: response.roster ?? Roster(), brainSwitch: response.brain_switch)
    }

    func put(_ roster: Roster, expected: Int) async throws -> Int {
        let params = try JSONEncoder().encode(RosterPutRequest(roster: roster, expected_revision: expected))
        let data = try await rpc.call(.rosterPut, params: params)
        guard let response = try? JSONDecoder().decode(RosterPutResponse.self, from: data) else { throw CompanionRPCError.invalidResponse }
        return response.revision
    }

    /// Switches the companion's provider on the same conversation (`brief`: the outgoing brain
    /// writes a handoff brief first). Returns the switch as the host reports it.
    func switchBrain(companionID: String, provider: String, model: String?, brief: Bool) async throws -> BrainSwitchState? {
        let params = try JSONEncoder().encode(BrainSwitchRequest(companion_id: companionID, provider: provider,
                                                                 model: model?.isEmpty == false ? model : nil, brief: brief))
        let data = try await rpc.call(.brainSwitch, params: params)
        return (try? JSONDecoder().decode(BrainSwitchResponse.self, from: data))?.brain_switch
    }

    func crew(workspace: String, thread: String) async throws -> [CrewLink] {
        let params = try JSONEncoder().encode(LinksListRequest(workspace_id: workspace, parent_thread_id: thread))
        let data = try await rpc.call(.linksList, params: params)
        guard let response = try? JSONDecoder().decode(LinksListResponse.self, from: data) else { throw CompanionRPCError.invalidResponse }
        return response.links ?? []
    }

    /// Applies `change` to `base` and saves it. On `conflict` the newest roster is fetched and the
    /// same change re-applied, up to `maxAttempts` puts. `change` returns false when there is
    /// nothing to save (e.g. the companion it edits was removed elsewhere); the fresh roster is
    /// then returned unchanged.
    func update(_ base: RosterSnapshot, home: String?, starterID: String,
                _ change: (inout Roster) -> Bool) async throws -> RosterSnapshot {
        var current = base
        for attempt in 1...Self.maxAttempts {
            var next = current.roster
            next.normalize(home: home, starterID: starterID)
            guard change(&next) else { return current }
            next.normalize(home: home, starterID: starterID)
            do {
                let revision = try await put(next, expected: current.revision)
                return RosterSnapshot(revision: revision, roster: next)
            } catch CompanionRPCError.conflict where attempt < Self.maxAttempts {
                current = try await roster()
            }
        }
        throw CompanionRPCError.conflict
    }
}

// MARK: - Sheet summary

enum SummaryTone: Equatable { case attention, busy, failure, quiet }

/// The header's short status suffix ("· 3 need you").
func companionStatusSuffix(needsYou: Int, crewRunning: Int, working: Bool, failed: Bool, connected: Bool) -> (text: String, tone: SummaryTone) {
    if !connected { return ("offline", .quiet) }
    if needsYou > 0 { return ("\(needsYou) need you", .attention) }
    if failed { return ("needs a look", .failure) }
    if working { return ("working", .busy) }
    if crewRunning > 0 { return ("\(crewRunning) running", .busy) }
    return ("ready", .quiet)
}

/// The "needs you" capsule; nil hides it.
func needsSummary(_ count: Int) -> String? { count > 0 ? "\(count) need you" : nil }

/// The crew capsule ("2 running · 1 done"); nil when there is no crew.
func crewSummary(_ crew: [CrewLink]) -> String? {
    guard !crew.isEmpty else { return nil }
    func count(_ match: (CrewAttention) -> Bool) -> Int { crew.filter { match($0.attention) }.count }
    let parts = [
        (count { $0 == .running }, "running"),
        (count { $0.needsYou }, "waiting"),
        (count { $0 == .failed }, "failed"),
        (count { $0 == .done }, "done"),
    ].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
    return parts.isEmpty ? "\(crew.count) idle" : parts.joined(separator: " · ")
}

// MARK: - Brain

/// The companion's chat as far as a brain change is concerned.
enum BrainThreadState: Equatable {
    /// No chat yet: only the roster changes (the first chat uses it).
    case noChat
    /// A chat that never sent anything: even the provider can change in place.
    case empty
    case committed
}

enum BrainChange: Equatable {
    /// Save to the roster only (the first chat uses it).
    case rosterOnly
    /// Same provider: change the current chat's settings through the composer.
    case inPlace
    /// A new provider on a chat with nothing to hand off: the host switches at once.
    case switchNow
    /// A new provider mid-conversation: confirm, then the outgoing brain briefs its successor on
    /// the same chat.
    case handoff
}

func classifyBrainChange(currentProvider: String, newProvider: String, thread: BrainThreadState) -> BrainChange {
    if thread == .noChat { return .rosterOnly }
    if newProvider.isEmpty || newProvider == currentProvider { return .inPlace }
    return thread == .empty ? .switchNow : .handoff
}

/// "Claude · Opus 5.5 · High"; defaults are left out.
func brainLabel(provider: String, model: String?, effort: String?) -> String {
    let parts = [provider, model ?? "", effort ?? ""].filter { !$0.isEmpty && $0 != "Default" }
    return parts.isEmpty ? "Default brain" : parts.joined(separator: " · ")
}

/// A provider id as people know it, preferring the host's own label.
func providerDisplayName(_ id: String, choices: [ChatChoice] = []) -> String {
    if let label = choices.first(where: { $0.id == id })?.label, !label.isEmpty { return label }
    switch id {
    case "": return ""
    case "codex": return "Codex"
    case "opencode": return "OpenCode"
    case "fx": return "FX"
    default: return id.prefix(1).uppercased() + id.dropFirst()
    }
}

func brainSwitchTitle(name: String, provider: String) -> String { "Switch \(name) to \(provider)?" }

func brainSwitchMessage(name: String, from: String, to: String) -> String {
    "\(name) keeps this conversation. \(from) will write a quick handoff brief first, then \(to) takes over with the brief and recent history."
}

/// The sheet's progress line for a brain switch; nil once it's done.
func brainSwitchStatusText(_ state: BrainSwitchState?, name: String, providerName: (String) -> String = { providerDisplayName($0) }) -> String? {
    guard let state else { return nil }
    switch state.status {
    case "pending", "briefing": return "Handing off to \(providerName(state.to))…"
    case "failed": return brainSwitchErrorText(state.error_code, name: name)
    default: return nil
    }
}

func brainSwitchErrorText(_ code: String?, name: String) -> String {
    switch code {
    case "companion_busy"?: return "\(name) is working right now. Switch when the current turn finishes."
    case "provider_unavailable"?: return "That provider isn't available on the computer right now."
    default: return "Couldn't switch \(name)'s brain."
    }
}

func newConversationMessage(name: String) -> String {
    "\(name) starts fresh with its current brain. This conversation moves to Conversations… so you can go back to it."
}
