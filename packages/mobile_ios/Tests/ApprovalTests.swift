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
        XCTAssertEqual(approvalTitle(approval), "Command approval")
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
        XCTAssertEqual(phaseText(.sent(.approve)), "Approved — waiting for the agent to continue.")
        XCTAssertFalse(phase(model)?.canDecide ?? true)
        follow(.sending(.approve), .sent(.approve))
        XCTAssertEqual(haptics, [.confirm, .confirm])

        // The tail clears it: the card leaves and the outcome is reported.
        harness.deliver { $0.thread = "approval-resolved" }
        try await waitUntil("resolved") { model.thread != nil && model.thread?.approval == nil }
        XCTAssertEqual(model.approvals.outcome?.outcome, .approved)
        XCTAssertEqual(model.approvals.outcome?.outcome.text, "Approved")
        XCTAssertEqual(decisions.count, 1)
    }

    func testAStaleDecisionSaysSoWithoutAThreadErrorBanner() async throws {
        let stale = try XCTUnwrap(SharedFixtures.thread("d09", "approval-stale").data?.approval?.error)
        let model = try await open(onDecide: { core, id in
            core.setThreadLocked("approval-stale")
            core.setOperation(id, "failed", stale)
        })
        XCTAssertTrue(tap(model, .deny))
        try await waitUntil("decision") { decisions.count == 1 }
        XCTAssertEqual(decisions[0].decision, .deny)
        XCTAssertEqual(haptics, [.reject])
        try await waitUntil("stale") { phase(model) == .stale }
        XCTAssertEqual(phaseText(.stale), "This request is no longer waiting. It was answered elsewhere or expired.")
        XCTAssertFalse(ApprovalPhase.stale.canDecide)
        // The core also mirrors the RPC failure into thread.error; the card owns that message.
        XCTAssertNotNil(model.thread?.error)
        XCTAssertTrue(sameError(model.thread?.error, model.thread?.approval?.error))
        XCTAssertNil(transcriptBanner(model.state, 0))
    }

    func testAnUncertainFailureCanBeRetried() async throws {
        let failed = try XCTUnwrap(SharedFixtures.thread("d09", "approval-failed").data?.approval?.error)
        let model = try await open(onDecide: { core, id in
            core.setThreadLocked("approval-failed")
            core.setOperation(id, "uncertain", failed)
        })
        XCTAssertTrue(tap(model, .deny))
        try await waitUntil("failed") { phase(model)?.isFailed == true }
        let current = try XCTUnwrap(phase(model))
        XCTAssertEqual(current, .failed(.deny, uncertain: true))
        XCTAssertEqual(phaseText(current), "Couldn't confirm your decision reached the host. Try again.")
        // Tap haptic, then one more for the failure; the failure interrupts VoiceOver.
        follow(.sending(.deny), current)
        XCTAssertEqual(haptics, [.reject, .reject])
        XCTAssertEqual(announcements.last, ApprovalAnnouncement(text: "Couldn't confirm your decision reached the host. Try again.", urgent: true))
        core.onDecide = { core, id in core.setThreadLocked("approval-pending"); core.setOperation(id, "pending") }
        XCTAssertTrue(current.canDecide)
        XCTAssertTrue(tap(model, .approve))
        try await waitUntil("retry") { decisions.count == 2 }
        XCTAssertEqual(decisions.last?.decision, .approve)
        try await waitUntil("sending") { phase(model) == .sending(.approve) }
    }

    func testAnApprovalAnsweredOnAnotherDeviceIsReflected() async throws {
        let model = try await open()
        harness.deliver { $0.thread = "approval-resolved" }
        try await waitUntil("resolved") { model.thread != nil && model.thread?.approval == nil }
        XCTAssertEqual(model.approvals.outcome?.outcome.text, "Approval answered on another device")
        XCTAssertTrue(decisions.isEmpty)
        // The notice is transient.
        try await waitUntil("cleared") { model.approvals.outcome == nil }
    }

    func testAnEditShowsTheFileNameAndChangeBeforeTheFullRequest() throws {
        let approval = try XCTUnwrap(SharedFixtures.thread("d09", "approval-edit").data?.approval)
        XCTAssertEqual(approvalTitle(approval), "Claude wants to use Edit")
        let preview = approvalPreview(approval)
        XCTAssertEqual(preview.tool, "Edit")
        XCTAssertEqual(preview.path.map(basename), "main.zig")
        XCTAssertEqual(preview.changes.map { changePrefix($0.kind) + $0.text }, ["− const answer = 41;", "+ const answer = 42;"])
        // The host path only appears in the raw request (behind "Show full request").
        XCTAssertTrue(approval.body.contains("/tmp/fixture-project/src/main.zig"))
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
        XCTAssertEqual(phaseAnnouncement(from: .idle, to: .sending(.deny)), ApprovalAnnouncement(text: "Sending your denial…", urgent: false))
        XCTAssertNil(phaseAnnouncement(from: .sending(.deny), to: .idle))
    }

    func testPreviewRules() throws {
        func preview(_ title: String, _ body: String) -> ApprovalPreview {
            approvalPreview(ChatApproval(turn_id: "t", call_id: "c", title: title, body: body))
        }
        let bash = preview("Claude wants to use Bash",
                           "Tool: Bash\n\nReason: Runs the tests\n\n{\n  \"command\": \"zig build test\",\n  \"description\": \"Run tests\"\n}")
        XCTAssertEqual(bash.tool, "Bash")
        XCTAssertEqual(bash.command, "zig build test")
        XCTAssertEqual(bash.reason, "Runs the tests")
        XCTAssertTrue(bash.changes.isEmpty)
        let edit = approvalPreview(try XCTUnwrap(SharedFixtures.thread("d09", "approval-edit").data?.approval))
        XCTAssertEqual(edit.tool, "Edit")
        XCTAssertEqual(edit.path, "/tmp/fixture-project/src/main.zig")
        XCTAssertEqual(edit.changes, [PreviewLine(kind: .remove, text: "const answer = 41;"), PreviewLine(kind: .add, text: "const answer = 42;")])
        let lines = (1...40).map { "l\($0)" }.joined(separator: "\\n")
        let write = preview("Claude wants to use Write", "Tool: Write\n\n{\"file_path\":\"/x/a.md\",\"content\":\"\(lines)\"}")
        XCTAssertEqual(write.changes.count, previewLines)
        XCTAssertTrue(write.changesTruncated)
        XCTAssertTrue(write.changes.allSatisfy { $0.kind == .add })
        let codex = preview("Command approval", "cargo test -p core")
        XCTAssertEqual(codex.command, "cargo test -p core")
        XCTAssertNil(codex.tool)
        let diff = preview("File change approval", "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n same")
        XCTAssertEqual(diff.changes.map(\.kind), [.hunk, .hunk, .hunk, .hunk, .remove, .add, .context])
        XCTAssertEqual(preview("OpenCode wants bash permission", "Action: bash\nls -la\nResources:\n- /tmp").tool, "bash")
        // Free text stays free text; malformed JSON is ignored, never thrown.
        XCTAssertEqual(preview("Permissions request", "Needs network access to fetch deps."), ApprovalPreview())
        XCTAssertEqual(preview("x", "Tool: Edit\n\n{not json").tool, "Edit")
        XCTAssertEqual(preview("x", ""), ApprovalPreview())
    }
}
