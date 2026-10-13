import Foundation

/*
 * `CompanionRPC` over the host core. The core owns the daemon calls: `companion_refresh`
 * (companion.roster.get), `companion_save` (companion.roster.put; local validation, one write in
 * flight, re-reads on `conflict`), `companion_crew_refresh` (chat.links.list) and
 * `companion_brain_switch` (companion.brain.switch). Each call sends the intent, follows its receipt
 * in `operations`, then answers from the `companion` view in the shape `CompanionClient` expects.
 *
 * Intents go out as raw tagged events and the view is decoded here with the app's own `Roster`, so
 * fields newer than the generated models (a companion's `history`, `brain_switch`) survive every
 * read and save. Roster content is never logged.
 */

/// The `companion` view as this build reads it.
struct CompanionViewState: Decodable {
    struct Crew: Decodable {
        var workspace_id = ""
        var thread_id = ""
        var links: [CrewLink] = []
        var loading = false
        private enum Keys: String, CodingKey { case workspace_id, thread_id, links, loading }
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            workspace_id = try c.decodeIfPresent(String.self, forKey: .workspace_id) ?? ""
            thread_id = try c.decodeIfPresent(String.self, forKey: .thread_id) ?? ""
            links = try c.decodeIfPresent([CrewLink].self, forKey: .links) ?? []
            loading = try c.decodeIfPresent(Bool.self, forKey: .loading) ?? false
        }
    }

    var loaded = false
    var loading = false
    var saving = false
    var supported = true
    var revision = "0"
    var roster = Roster()
    var crew = Crew()
    var brain_switch: BrainSwitchState?
    var errorCode: String?

    private enum Keys: String, CodingKey { case loaded, loading, saving, supported, revision, roster, crew, brain_switch, error }
    private struct ErrorCode: Decodable { var code: String? }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        loaded = try c.decodeIfPresent(Bool.self, forKey: .loaded) ?? false
        loading = try c.decodeIfPresent(Bool.self, forKey: .loading) ?? false
        saving = try c.decodeIfPresent(Bool.self, forKey: .saving) ?? false
        supported = try c.decodeIfPresent(Bool.self, forKey: .supported) ?? true
        revision = try c.decodeIfPresent(String.self, forKey: .revision) ?? "0"
        roster = try c.decodeIfPresent(Roster.self, forKey: .roster) ?? Roster()
        crew = try c.decodeIfPresent(Crew.self, forKey: .crew) ?? Crew()
        brain_switch = try? c.decodeIfPresent(BrainSwitchState.self, forKey: .brain_switch)
        errorCode = (try? c.decodeIfPresent(ErrorCode.self, forKey: .error))?.code
    }
}

private struct CompanionViewQuery: Decodable { var data: CompanionViewState? }

func decodeCompanionView(_ data: Data?) -> CompanionViewState? {
    guard let data else { return nil }
    return (try? JSONDecoder().decode(CompanionViewQuery.self, from: data))?.data
}

private struct SaveParams: Decodable {
    var roster: Roster
    var expected_revision: Int
}
private struct CrewParams: Decodable {
    var workspace_id: String
    var parent_thread_id: String
}
private struct BrainParams: Decodable {
    var companion_id: String?
    var provider: String
    var model: String?
    var brief: Bool?
}
private struct RosterReply: Encodable {
    var revision: Int
    var roster: Roster
    var brain_switch: BrainSwitchState?
}
private struct RevisionReply: Encodable { var revision: Int }
private struct LinksReply: Encodable { var links: [CrewLink] }
private struct BrainReply: Encodable { var brain_switch: BrainSwitchState? }

extension CrewLink: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(link_id, forKey: AnyCodingKey("link_id"))
        try c.encode(workspace_id, forKey: AnyCodingKey("workspace_id"))
        try c.encode(parent_workspace_id, forKey: AnyCodingKey("parent_workspace_id"))
        try c.encode(local_thread_id, forKey: AnyCodingKey("local_thread_id"))
        try c.encode(title, forKey: AnyCodingKey("title"))
        try c.encode(provider, forKey: AnyCodingKey("provider"))
        try c.encode(status, forKey: AnyCodingKey("status"))
        try c.encode(summary, forKey: AnyCodingKey("summary"))
        try c.encode(updated_at_ms, forKey: AnyCodingKey("updated_at_ms"))
        try c.encode(hidden, forKey: AnyCodingKey("hidden"))
    }
}

struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Raw intents (type + fields); `intent_id` is added by the caller.
enum CompanionIntent {
    static func refresh(intentID: String) -> (String, [String: JSONValue]) {
        ("companion_refresh", ["intent_id": .string(intentID)])
    }

    static func save(intentID: String, roster: Roster, expectedRevision: Int) throws -> (String, [String: JSONValue]) {
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(roster))
        return ("companion_save", ["intent_id": .string(intentID), "roster": value, "expected_revision": .string(String(expectedRevision))])
    }

    static func crew(intentID: String, workspaceID: String, threadID: String) -> (String, [String: JSONValue]) {
        ("companion_crew_refresh", ["intent_id": .string(intentID), "workspace_id": .string(workspaceID), "thread_id": .string(threadID)])
    }

    static func brainSwitch(intentID: String, companionID: String?, provider: String, model: String?, brief: Bool) -> (String, [String: JSONValue]) {
        var fields: [String: JSONValue] = ["intent_id": .string(intentID), "provider": .string(provider), "brief": .bool(brief)]
        if let companionID, !companionID.isEmpty { fields["companion_id"] = .string(companionID) }
        if let model, !model.isEmpty { fields["model"] = .string(model) }
        return ("companion_brain_switch", fields)
    }
}

/// Daemon/core codes meaning "this host has no companion roster".
private let unsupportedCodes: Set<String> = ["method_not_found", "unknown_method", "scope_denied", "unsupported"]

/// Maps one settled companion intent and the `companion` view onto a `CompanionRPC` reply.
/// `crew` is the requested (workspace, thread); another companion's crew is never returned.
/// `intent` identifies a brain switch in the view.
func companionReply(_ method: CompanionMethod, operation: CoreOperation, view: CompanionViewState?,
                    crew: (workspace: String, thread: String)? = nil, intent: String? = nil) throws -> Data {
    if operation.state == "failed" || operation.state == "uncertain" {
        let code = operation.error?.rpc_code ?? operation.error?.code ?? "failed"
        if unsupportedCodes.contains(code) || view?.supported == false { throw CompanionRPCError.unsupported }
        if code == "conflict" { throw CompanionRPCError.conflict }
        throw CompanionRPCError.remote(code: code)
    }
    guard let view else { throw CompanionRPCError.invalidResponse }
    if !view.supported { throw CompanionRPCError.unsupported }
    let revision = Int(view.revision) ?? 0
    switch method {
    case .rosterGet:
        guard view.loaded else { throw CompanionRPCError.remote(code: view.errorCode ?? "not_loaded") }
        return try JSONEncoder().encode(RosterReply(revision: revision, roster: view.roster, brain_switch: view.brain_switch))
    case .rosterPut:
        return try JSONEncoder().encode(RevisionReply(revision: revision))
    case .linksList:
        let matches = crew.map { view.crew.workspace_id == $0.workspace && view.crew.thread_id == $0.thread } ?? true
        return try JSONEncoder().encode(LinksReply(links: matches ? view.crew.links : []))
    case .brainSwitch:
        let state = view.brain_switch.flatMap { intent == nil || $0.intent_id == intent ? $0 : nil }
        if let state, state.status == "failed" { throw CompanionRPCError.remote(code: state.error_code ?? "failed") }
        return try JSONEncoder().encode(BrainReply(brain_switch: state))
    }
}

/// Whether the view is still finishing work that a just-settled receipt may have coalesced into.
func companionBusy(_ method: CompanionMethod, _ view: CompanionViewState) -> Bool {
    switch method {
    case .rosterGet: return view.loading
    case .rosterPut: return view.saving
    case .linksList: return view.crew.loading
    case .brainSwitch: return false
    }
}

final class CoreCompanionRPC: CompanionRPC {
    static let timeout: Duration = .seconds(20)
    static let step: Duration = .milliseconds(100)
    private let session: PairingModel

    init(session: PairingModel) { self.session = session }

    func call(_ method: CompanionMethod, params: Data) async throws -> Data {
        await session.start()
        guard let host = await session.host else { throw CompanionRPCError.remote(code: "offline") }
        let intent = UUID().uuidString
        var crew: (workspace: String, thread: String)?
        let event: (String, [String: JSONValue])
        switch method {
        case .rosterGet:
            event = CompanionIntent.refresh(intentID: intent)
        case .rosterPut:
            guard let request = try? JSONDecoder().decode(SaveParams.self, from: params) else { throw CompanionRPCError.invalidResponse }
            event = try CompanionIntent.save(intentID: intent, roster: request.roster, expectedRevision: request.expected_revision)
        case .linksList:
            guard let request = try? JSONDecoder().decode(CrewParams.self, from: params) else { throw CompanionRPCError.invalidResponse }
            crew = (request.workspace_id, request.parent_thread_id)
            event = CompanionIntent.crew(intentID: intent, workspaceID: request.workspace_id, threadID: request.parent_thread_id)
        case .brainSwitch:
            guard let request = try? JSONDecoder().decode(BrainParams.self, from: params) else { throw CompanionRPCError.invalidResponse }
            event = CompanionIntent.brainSwitch(intentID: intent, companionID: request.companion_id, provider: request.provider,
                                                model: request.model, brief: request.brief ?? true)
        }
        do { try await host.sendIntent(event.0, event.1) }
        catch CoreBridgeError.rejected { throw CompanionRPCError.remote(code: "rejected") }
        catch { throw CompanionRPCError.remote(code: "unavailable") }

        let deadline = ContinuousClock.now.advanced(by: Self.timeout)
        var operation: CoreOperation?
        repeat {
            if operation == nil || operation?.state == "pending" {
                let data = try? await host.query("operations")
                operation = data.flatMap { try? JSONDecoder().decode(OperationsQuery.self, from: $0) }?
                    .data?.items.first { $0.intent_id == intent }
            }
            let view = decodeCompanionView(try? await host.query("companion"))
            // A brain switch answers as soon as the view shows it under way (the brief can take a while).
            if method == .brainSwitch, let state = view?.brain_switch, state.intent_id == intent, state.status != "pending" {
                return try companionReply(method, operation: operation ?? CoreOperation(intent_id: intent, state: "succeeded", error: nil),
                                          view: view, crew: crew, intent: intent)
            }
            if let operation, operation.state != "pending" {
                if operation.state != "succeeded" || view.map({ !companionBusy(method, $0) }) ?? true {
                    return try companionReply(method, operation: operation, view: view, crew: crew, intent: intent)
                }
            }
            try await Task.sleep(for: Self.step)
        } while ContinuousClock.now < deadline
        throw CompanionRPCError.remote(code: "timeout")
    }
}
