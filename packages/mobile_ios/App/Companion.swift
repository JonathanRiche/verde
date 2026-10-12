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

struct RosterEntry: Codable, Identifiable, Equatable {
    static let nameLimit = 32
    static let ordersLimit = 1024

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
        case id, name, character, home_workspace_id, thread_id, provider, model, orders
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
        try encodeExtras(extras, encoder, known: Self.known)
    }

    /// Unknown fields are compared by key only (`JSONValue` is not Equatable).
    static func == (a: RosterEntry, b: RosterEntry) -> Bool {
        a.id == b.id && a.name == b.name && a.characterRaw == b.characterRaw && a.home_workspace_id == b.home_workspace_id &&
            a.thread_id == b.thread_id && a.provider == b.provider && a.model == b.model && a.orders == b.orders &&
            Set(a.extras.keys) == Set(b.extras.keys)
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
}

private struct RosterGetResponse: Decodable {
    var revision: Int?
    var roster: Roster?
}
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
        return RosterSnapshot(revision: response.revision ?? 0, roster: response.roster ?? Roster())
    }

    func put(_ roster: Roster, expected: Int) async throws -> Int {
        let params = try JSONEncoder().encode(RosterPutRequest(roster: roster, expected_revision: expected))
        let data = try await rpc.call(.rosterPut, params: params)
        guard let response = try? JSONDecoder().decode(RosterPutResponse.self, from: data) else { throw CompanionRPCError.invalidResponse }
        return response.revision
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
