import XCTest
import UIKit
@testable import VerdeApp

@MainActor
final class ComposerTests: XCTestCase {
    func testCoreProjectionAdoptsWithoutAViewObserver() async throws {
        let harness = ChatHarness()
        try await harness.launch()
        let chat = TranscriptModel(browse: harness.browse, workspaceID: chatWS, threadID: chatThread)
        chat.start(); chat.setVisible(true)
        try await waitUntil { chat.input.view != nil }
        XCTAssertEqual(chat.input.view?.draft.revision, chat.composer?.draft.revision)
        XCTAssertEqual(chat.input.text, chat.composer?.draft.text)
        chat.stop(); await harness.close()
    }

    func testDelayedSettingShowsImmediatelyAndBlocksSend() async throws {
        let harness = ChatHarness()
        try await harness.launch { $0.holdSelection = true }
        let chat = TranscriptModel(browse: harness.browse, workspaceID: chatWS, threadID: chatThread)
        chat.start(); chat.setVisible(true)
        try await waitUntil { chat.input.view != nil }
        let model = chat.input
        model.edit("Keep draft", selection: NSRange(location: 10, length: 0))
        model.select(.speed, "on")
        XCTAssertEqual(model.displayedSelection?.speed, "on")
        XCTAssertFalse(model.canSubmit)
        model.submit()
        try await waitUntil { harness.core.events.count { if case .composer_select = $0 { return true }; return false } == 1 }
        XCTAssertNotNil(model.pendingSelection)
        XCTAssertEqual(harness.core.events.count { if case .send = $0 { return true }; return false }, 0)
        try harness.core.completeSelection()
        try await waitUntil { model.pendingSelection == nil }
        XCTAssertEqual(model.view?.selection.speed, "on")
        XCTAssertEqual(model.text, "Keep draft")
        chat.stop(); await harness.close()
    }

    func testRapidSettingsSaveInOrderWithoutDroppingEarlierChoices() async throws {
        let harness = ChatHarness()
        try await harness.launch { $0.holdSelection = true }
        let chat = TranscriptModel(browse: harness.browse, workspaceID: chatWS, threadID: chatThread)
        chat.start(); chat.setVisible(true)
        try await waitUntil { chat.input.view != nil }
        let model = chat.input
        model.select(.speed, "on"); model.select(.model, "gpt-6-luna")
        XCTAssertEqual(model.displayedSelection?.speed, "on")
        XCTAssertEqual(model.displayedSelection?.model, "gpt-6-luna")
        let count = { harness.core.events.count { if case .composer_select = $0 { return true }; return false } }
        try await waitUntil { count() == 1 }
        try harness.core.completeSelection()
        try await waitUntil { count() == 2 }
        XCTAssertNotNil(model.pendingSelection)
        try harness.core.completeSelection()
        try await waitUntil { model.pendingSelection == nil }
        XCTAssertEqual(model.view?.selection.speed, "on")
        XCTAssertEqual(model.view?.selection.model, "gpt-6-luna")
        let saves = harness.core.events.all.compactMap { if case .composer_select(let e) = $0 { return e }; return nil }
        XCTAssertEqual(saves.map(\.speed), ["on", "on"])
        XCTAssertEqual(saves.last?.model, "gpt-6-luna")
        chat.stop(); await harness.close()
    }

    func testRejectedSettingRestoresConfirmedValueAndShowsError() async throws {
        let harness = ChatHarness()
        try await harness.launch { $0.holdSelection = true; $0.rejectSelection = true }
        let chat = TranscriptModel(browse: harness.browse, workspaceID: chatWS, threadID: chatThread)
        chat.start(); chat.setVisible(true)
        try await waitUntil { chat.input.view != nil }
        let model = chat.input, original = model.displayedSelection?.speed
        model.select(.speed, "on")
        XCTAssertEqual(model.displayedSelection?.speed, "on")
        try await waitUntil { harness.core.events.count { if case .composer_select = $0 { return true }; return false } == 1 }
        try harness.core.completeSelection()
        try await waitUntil { model.pendingSelection == nil }
        XCTAssertEqual(model.displayedSelection?.speed, original)
        XCTAssertEqual(model.notice, "That option isn't available for this model.")
        chat.stop(); await harness.close()
    }

    func testPromptResizeKeepsConversationVisibleAboveKeyboard() {
        XCTAssertEqual(composerPromptHeight(10, available: 700), 56)
        XCTAssertEqual(composerPromptHeight(1000, available: 700), 420)
        XCTAssertEqual(composerPromptHeight(420, available: 400), 200)
        XCTAssertEqual(composerPromptHeight(420, available: 220), 56)
        XCTAssertEqual(composerPromptHeight(56, available: 700), 56)
    }

    func testMentionsRespectCaretAndUTF16() {
        let text = "Hello 👋 @src/file trailing"
        let caret = ("Hello 👋 @src/fi" as NSString).length
        let token = composerToken(text, caret: caret)
        XCTAssertEqual(token?.query, "src/fi")
        XCTAssertEqual(token?.range.location, ("Hello 👋 " as NSString).length)
        XCTAssertNil(composerToken("hello /help", caret: 11))
        XCTAssertEqual(composerToken("/help", caret: 3)?.query, "he")
    }

    func testImagesQueueAndUnsupportedProvidersDoNotSteer() {
        XCTAssertEqual(composerFollowupKind(provider: "codex", images: false), .steer)
        XCTAssertEqual(composerFollowupKind(provider: "claude", images: true), .queue)
        XCTAssertEqual(composerFollowupKind(provider: "cursor", images: false), .queue)
    }

    func testImageEncodingIsBoundedJPEG() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1800)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1800))
        }
        let bytes = try XCTUnwrap(composerImage(image))
        XCTAssertLessThanOrEqual(bytes.count, ComposerModel.maxImageBytes)
        let decoded = try XCTUnwrap(UIImage(data: bytes))
        XCTAssertLessThanOrEqual(max(decoded.size.width, decoded.size.height), 1600)
        XCTAssertEqual(Array(bytes.prefix(2)), [0xff, 0xd8])
    }

    func testSendFlushesLatestDraftOnceAndPreventsDoubleTap() async throws {
        let harness = ChatHarness()
        try await harness.launch()
        let chat = TranscriptModel(browse: harness.browse, workspaceID: chatWS, threadID: chatThread)
        chat.start(); chat.setVisible(true)
        try await waitUntil { chat.composer != nil }
        let model = chat.input
        model.adopt(chat.composer)
        model.edit("First", selection: NSRange(location: 5, length: 0))
        model.edit("Latest 👋", selection: NSRange(location: 9, length: 0))
        model.submit(); model.submit()
        try await waitUntil { !model.busy }
        let drafts = harness.core.events.all.compactMap { if case .draft_set(let value) = $0 { return value }; return nil }
        let sends = harness.core.events.all.compactMap { if case .send(let value) = $0 { return value }; return nil }
        XCTAssertEqual(drafts.map(\.text), ["Latest 👋"])
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(sends.first?.draft_revision, drafts.first?.intent_id)
        XCTAssertEqual(model.text, "")
        XCTAssertFalse(model.canSubmit)
        chat.stop(); await harness.close()
    }

    func testRejectedDraftPreservesTextAndDoesNotSendOrKillHost() async throws {
        let harness = ChatHarness()
        try await harness.launch { $0.rejectDraft = true }
        let chat = TranscriptModel(browse: harness.browse, workspaceID: chatWS, threadID: chatThread)
        chat.start(); chat.setVisible(true)
        try await waitUntil { chat.composer != nil }
        let model = chat.input; model.adopt(chat.composer)
        model.edit("Keep this", selection: NSRange(location: 9, length: 0))
        model.submit()
        try await waitUntil { !model.busy }
        XCTAssertEqual(model.text, "Keep this")
        XCTAssertNotNil(model.notice)
        XCTAssertEqual(harness.core.events.count { if case .send = $0 { return true }; return false }, 0)
        XCTAssertFalse(chat.fatal)
        chat.stop(); await harness.close()
    }
}
