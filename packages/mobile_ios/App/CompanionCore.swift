import Foundation

/*
 * `CompanionRPC` over the host core. The core owns the daemon calls: `companion_refresh`
 * (companion.roster.get), `companion_save` (companion.roster.put; local validation, one write in
 * flight, re-reads on `conflict`) and `companion_crew_refresh` (chat.links.list). Each call sends
 * the intent, follows its receipt in `operations`, then answers from the `companion` view in the
 * shape `CompanionClient` expects. Roster content is never logged.
 */

private struct SaveParams: Decodable {
    var roster: CompanionRoster
    var expected_revision: Int
}
private struct CrewParams: Decodable {
    var workspace_id: String
    var parent_thread_id: String
}
private struct RosterReply: Encodable {
    var revision: Int
    var roster: CompanionRoster
}
private struct RevisionReply: Encodable { var revision: Int }
private struct LinksReply: Encodable { var links: [CompanionLink] }

/// Daemon/core codes meaning "this host has no companion roster".
private let unsupportedCodes: Set<String> = ["method_not_found", "unknown_method", "scope_denied", "unsupported"]

/// Maps one settled companion intent and the `companion` view onto a `CompanionRPC` reply.
/// `crew` is the requested (workspace, thread); another companion's crew is never returned.
func companionReply(_ method: CompanionMethod, operation: CoreOperation, view: CompanionView?,
                    crew: (workspace: String, thread: String)? = nil) throws -> Data {
    if operation.state != "succeeded" {
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
        guard view.loaded else { throw CompanionRPCError.remote(code: view.error?.code ?? "not_loaded") }
        return try JSONEncoder().encode(RosterReply(revision: revision, roster: view.roster))
    case .rosterPut:
        return try JSONEncoder().encode(RevisionReply(revision: revision))
    case .linksList:
        let matches = crew.map { view.crew.workspace_id == $0.workspace && view.crew.thread_id == $0.thread } ?? true
        return try JSONEncoder().encode(LinksReply(links: matches ? view.crew.links : []))
    }
}

/// Whether the view is still finishing work that a just-settled receipt may have coalesced into.
func companionBusy(_ method: CompanionMethod, _ view: CompanionView) -> Bool {
    switch method {
    case .rosterGet: return view.loading
    case .rosterPut: return view.saving
    case .linksList: return view.crew.loading
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
        let event: Event
        switch method {
        case .rosterGet:
            event = .companion_refresh(EventCompanionRefresh(now_ms: 0, wall_time_ms: 0, intent_id: intent))
        case .rosterPut:
            guard let request = try? JSONDecoder().decode(SaveParams.self, from: params) else { throw CompanionRPCError.invalidResponse }
            event = .companion_save(EventCompanionSave(now_ms: 0, wall_time_ms: 0, intent_id: intent,
                                                       roster: request.roster, expected_revision: String(request.expected_revision)))
        case .linksList:
            guard let request = try? JSONDecoder().decode(CrewParams.self, from: params) else { throw CompanionRPCError.invalidResponse }
            crew = (request.workspace_id, request.parent_thread_id)
            event = .companion_crew_refresh(EventCompanionCrewRefresh(now_ms: 0, wall_time_ms: 0, intent_id: intent,
                                                                      workspace_id: request.workspace_id, thread_id: request.parent_thread_id))
        }
        do { try await host.send(event) }
        catch CoreBridgeError.rejected { throw CompanionRPCError.remote(code: "rejected") }
        catch { throw CompanionRPCError.remote(code: "unavailable") }

        let deadline = ContinuousClock.now.advanced(by: Self.timeout)
        var operation: CoreOperation?
        var view: CompanionView?
        repeat {
            if operation == nil || operation?.state == "pending" {
                let data = try? await host.query("operations")
                operation = data.flatMap { try? JSONDecoder().decode(OperationsQuery.self, from: $0) }?
                    .data?.items.first { $0.intent_id == intent }
            }
            if let operation, operation.state != "pending" {
                let data = try? await host.query("companion")
                view = data.flatMap { try? JSONDecoder().decode(CompanionQuery.self, from: $0) }?.data
                if operation.state != "succeeded" || view.map({ !companionBusy(method, $0) }) ?? true {
                    return try companionReply(method, operation: operation, view: view, crew: crew)
                }
            }
            try await Task.sleep(for: Self.step)
        } while ContinuousClock.now < deadline
        throw CompanionRPCError.remote(code: "timeout")
    }
}
