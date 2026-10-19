import XCTest
import UIKit
@testable import VerdeApp

@MainActor
final class ComposerTests: XCTestCase {
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

    func testMentionsRespectCaretAndUTF16() {
        let text = "Hello 👋 @src/file trailing"
        let caret = ("Hello 👋 @src/fi" as NSString).length
        let token = composerToken(text, caret: caret)
        XCTAssertEqual(token?.query, "src/fi")
        XCTAssertEqual(token?.range.location, ("Hello 👋 " as NSString).length)
        XCTAssertNil(composerToken("hello /help", caret: 11))
        XCTAssertEqual(composerToken("/help", caret: 3)?.query, "he")
    }

    func testImageEncodingIsBoundedJPEG() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1800)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1800))
        }
        let bytes = try XCTUnwrap(composerImage(image))
        XCTAssertLessThanOrEqual(bytes.count, ComposerModel.maxImageBytes)
        let decoded = try XCTUnwrap(UIImage(data: bytes))
        XCTAssertLessThanOrEqual(max(decoded.size.width, decoded.size.height), 2048)
        XCTAssertEqual(Array(bytes.prefix(2)), [0xff, 0xd8])
    }

    func testLargePhotoKeepsProviderSizeWithinTheImageLimit() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 4032, height: 3024), format: format).image { context in
            for column in 0..<8 {
                UIColor(hue: CGFloat(column) / 8, saturation: 0.7, brightness: 0.9, alpha: 1).setFill()
                context.fill(CGRect(x: column * 504, y: 0, width: 504, height: 3024))
            }
        }
        let bytes = try XCTUnwrap(composerImage(photo))
        XCTAssertLessThanOrEqual(bytes.count, ComposerModel.maxImageBytes)
        let decoded = try XCTUnwrap(UIImage(data: bytes))
        XCTAssertEqual(max(decoded.size.width, decoded.size.height), 2048, accuracy: 1)
        let small = try XCTUnwrap(composerImage(photo, maxBytes: 32 * 1024))
        XCTAssertLessThanOrEqual(small.count, 32 * 1024)
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

    // MARK: Ask agent hand-off (file/diff viewer selections)

    func testAskAppendsToAnUnsentDraftWithoutSending() async throws {
        let harness = ChatHarness()
        try await harness.launch()
        let chat = TranscriptModel(browse: harness.browse, workspaceID: chatWS, threadID: chatThread)
        chat.start(); chat.setVisible(true)
        try await waitUntil { chat.input.view != nil && chat.thread != nil }
        let model = chat.input
        model.edit("Keep this note", selection: NSRange(location: 14, length: 0))
        model.ask("Explain these lines")
        let expected = "Keep this note\n\nExplain these lines"
        try await waitUntil("draft") {
            harness.core.events.all.compactMap { if case .draft_set(let value) = $0 { return value.text }; return nil }.last == expected
        }
        XCTAssertEqual(model.text, expected)
        XCTAssertEqual(harness.core.events.count { if case .send = $0 { return true }; return false }, 0)
        chat.stop(); await harness.close()
    }
}
