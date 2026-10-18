import XCTest
@testable import VerdeApp

/// D-09 / I-05 approvals over a fake core serving real core `thread:` projections recorded from the
/// core's approval harness (shared Android fixtures, d09/README.md). Receipts are synthesized.
@MainActor
final class ApprovalTests: XCTestCase {
    private var harness = ChatHarness()
    private var models: [TranscriptModel] = []
    private var haptics: [ApprovalFeedback] = []
    private var announcements: [ApprovalAnnouncement] = []
    private var savedHaptics: ((ApprovalFeedback) -> Void)?
    private var savedAnnouncer: ((ApprovalAnnouncement) -> Void)?

    override func setUp() async throws {
        savedHaptics = ApprovalHaptics.perform
        savedAnnouncer = ApprovalAnnouncer.post
        ApprovalHaptics.perform = { [unowned self] in self.haptics.append($0) }
        ApprovalAnnouncer.post = { [unowned self] in self.announcements.append($0) }
    }

    override func tearDown() async throws {
        models.forEach { $0.stop() }
        await harness.close()
        if let savedHaptics { ApprovalHaptics.perform = savedHaptics }
        if let savedAnnouncer { ApprovalAnnouncer.post = savedAnnouncer }
    }

    private var core: ChatCore { harness.core }

    private func open(_ thread: String = "approval-command", onDecide: ((ChatCore, String) -> Void)? = nil) async throws -> TranscriptModel {
        try await harness.launch(setup: { $0.thread = thread; $0.onDecide = onDecide },
                                 make: { ChatCore($0, directory: "d09", thread: thread) })
        let model = TranscriptModel(browse: harness.browse, workspaceID: chatWS, threadID: chatThread, unfocusDelay: 0.05,
                                    outcomeDelay: 0.3)
        models.append(model)
        model.start()
        model.setVisible(true)
        try await waitUntil("approval") { model.thread?.approval != nil }
        return model
    }

    private var decisions: [EventApprovalDecide] {
        core.events.all.compactMap { if case .approval_decide(let e) = $0 { return e }; return nil }
    }
    private func phase(_ model: TranscriptModel) -> ApprovalPhase? {
        model.thread?.approval.map { approvalPhase($0, model.approvals.local) }
    }

    /// What the card does on a tap: decide, then the tap haptic.
    private func tap(_ model: TranscriptModel, _ decision: ApprovalDecision) -> Bool {
        guard let approval = model.thread?.approval, model.approvals.decide(approval, decision) else { return false }
        ApprovalHaptics.perform(tapFeedback(decision))
        return true
    }

    /// What the card does on a phase change (haptic + VoiceOver), recorded by the test hooks.
    private func follow(_ from: ApprovalPhase, _ to: ApprovalPhase) {
        if let feedback = phaseFeedback(from: from, to: to) { ApprovalHaptics.perform(feedback) }
        if let announcement = phaseAnnouncement(from: from, to: to) { ApprovalAnnouncer.post(announcement) }
    }

    func testApproveTargetsTheCurrentCallThenConfirmsAndReportsTheOutcome() async throws {
        let model = try await open()
        let approval = try XCTUnwrap(model.thread?.approval)
        XCTAssertEqual(approvalPreview(approval).command, "zig build test --summary all")
        XCTAssertTrue(model.items.contains { if case .approval = $0 { return true }; return false })
        XCTAssertEqual(phase(model), .idle)

        XCTAssertTrue(tap(model, .approve))
        // In flight: both choices locked, the chosen one says so.
        XCTAssertEqual(phase(model), .sending(.approve))
        XCTAssertFalse(tap(model, .deny))
        try await waitUntil("decision") { decisions.count == 1 }
        let sent = decisions[0]
        XCTAssertEqual(sent.turn_id, "fixture-turn")
        XCTAssertEqual(sent.call_id, "call-cmd")
        XCTAssertEqual(sent.decision, .approve)
        XCTAssertEqual(sent.workspace_id, chatWS)
        XCTAssertEqual(sent.thread_id, chatThread)
        XCTAssertEqual(haptics, [.confirm])

        // The host accepted it: confirmed, nothing left to tap twice.
        harness.deliver { core in core.operation(sent.intent_id, "succeeded"); core.thread = "approval-sent" }
        try await waitUntil("sent") { phase(model) == .sent(.approve) }
        XCTAssertFalse(phase(model)?.canDecide ?? true)
        follow(.sending(.approve), .sent(.approve))
        XCTAssertEqual(haptics, [.confirm, .confirm])

        // The tail clears it: the card leaves and the outcome is reported.
        harness.deliver { $0.thread = "approval-resolved" }
        try await waitUntil("resolved") { model.thread != nil && model.thread?.approval == nil }
        XCTAssertEqual(model.approvals.outcome?.outcome, .approved)
        XCTAssertEqual(decisions.count, 1)
    }

    func testSharedHelpersForNotificationActions() async throws {
        // I-08 path: read the open thread's approval straight from the core, then decide it.
        let fake = ChatCore(SavedHost(id: "alpha", label: "Studio"), directory: "d09", thread: "approval-command")
        fake.ensured = true
        let host = CoreHost(core: fake, store: CoreViewStore(), transport: NullTransport(), storage: MemoryStorage())
        let target = await currentApprovalTarget(host: host, workspaceID: chatWS, threadID: chatThread)
        XCTAssertEqual(target, ApprovalTarget(workspaceID: chatWS, threadID: chatThread, turnID: "fixture-turn", callID: "call-cmd"))
        let result = await decideApproval(host: host, target: try XCTUnwrap(target), decision: .deny, intentID: "intent-1")
        XCTAssertEqual(result, .sent("intent-1"))
        let event = try XCTUnwrap(fake.events.all.compactMap { if case .approval_decide(let e) = $0 { return e }; return nil }.first)
        XCTAssertEqual(event.decision, .deny)
        XCTAssertEqual(event.intent_id, "intent-1")
        // A pending decision is not re-offered as a target.
        let pending = await currentApprovalTarget(host: host, workspaceID: chatWS, threadID: chatThread)
        XCTAssertNil(pending)
        fake.thread = "approval-resolved"
        let resolved = await currentApprovalTarget(host: host, workspaceID: chatWS, threadID: chatThread)
        XCTAssertNil(resolved)
        try await host.shutdown()
    }

    func testPhaseRules() throws {
        func approval(_ name: String) throws -> ChatApproval { try XCTUnwrap(SharedFixtures.thread("d09", name).data?.approval) }
        let idle = try approval("approval-command"), pending = try approval("approval-pending")
        let stale = try approval("approval-stale"), failed = try approval("approval-failed")
        XCTAssertEqual(idle.resolution, "idle")
        XCTAssertEqual(pending.resolution, "pending")
        XCTAssertEqual(stale.resolution, "failed")
        XCTAssertTrue(staleApprovalError(stale.error))
        XCTAssertEqual(failed.resolution, "failed")
        XCTAssertFalse(staleApprovalError(failed.error))
        XCTAssertEqual(failed.error?.delivery, "uncertain")
        XCTAssertNil(SharedFixtures.thread("d09", "approval-resolved").data?.approval)

        let sending = LocalDecision(key: idle.key, decision: .approve, state: .sending)
        var sent = sending; sent.state = .sent
        var staleLocal = sending; staleLocal.state = .stale
        var other = sending; other.key = "other"
        XCTAssertEqual(approvalPhase(idle, nil), .idle)
        XCTAssertEqual(approvalPhase(idle, sending), .sending(.approve))
        XCTAssertEqual(approvalPhase(pending, sending), .sending(.approve))
        XCTAssertEqual(approvalPhase(pending, nil), .sending(nil))
        XCTAssertEqual(approvalPhase(pending, sent), .sent(.approve))
        XCTAssertEqual(approvalPhase(stale, sending), .stale)
        XCTAssertEqual(approvalPhase(idle, staleLocal), .stale)
        XCTAssertEqual(approvalPhase(failed, sending), .failed(.approve, uncertain: true))
        // A decision for another call never leaks onto this card.
        XCTAssertEqual(approvalPhase(idle, other), .idle)
        XCTAssertTrue(ApprovalPhase.idle.canDecide)
        XCTAssertTrue(ApprovalPhase.failed(nil, uncertain: false).canDecide)
        XCTAssertFalse(ApprovalPhase.sending(nil).canDecide)
        XCTAssertFalse(ApprovalPhase.stale.canDecide)
        // Haptics and announcements follow phase edges only.
        XCTAssertEqual(tapFeedback(.approve), .confirm)
        XCTAssertEqual(tapFeedback(.deny), .reject)
        XCTAssertNil(phaseFeedback(from: .idle, to: .sending(.approve)))
        XCTAssertEqual(phaseFeedback(from: .sending(.approve), to: .sent(.approve)), .confirm)
        XCTAssertNil(phaseFeedback(from: .sent(.approve), to: .sent(.approve)))
        XCTAssertNil(phaseAnnouncement(from: .sending(.deny), to: .idle))
    }
}
