import SwiftUI
import XCTest
@testable import VerdeApp

private typealias Fg = AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute
private typealias LinkKey = AttributeScopes.FoundationAttributes.LinkAttribute

/// D-06 / I-05 transcript over a fake core that serves real core projections recorded from the
/// K-10 chat fixtures and real K-11 render results (shared Android fixtures, d06/README.md).
@MainActor
final class TranscriptModelTests: XCTestCase {
    private var harness = ChatHarness()
    private var models: [TranscriptModel] = []

    override func tearDown() async throws {
        models.forEach { $0.stop() }
        await harness.close()
    }

    private var core: ChatCore { harness.core }

    private func open(visible: Bool = true) -> TranscriptModel {
        let model = TranscriptModel(browse: harness.browse, workspaceID: chatWS, threadID: chatThread, unfocusDelay: 0.05,
                                    outcomeDelay: 0.3)
        models.append(model)
        model.start()
        if visible { model.setVisible(true) }
        return model
    }

    private var focuses: [EventFocus] {
        core.events.all.compactMap { if case .focus(let e) = $0 { return e }; return nil }
    }
    private func count(_ match: (Event) -> Bool) -> Int { core.events.count(match) }
    private func bodies(_ model: TranscriptModel) -> [String] { model.thread?.rows.map(\.body) ?? [] }

    func testOpensFocusedRendersCoreMarkdownAndPagesOlderOncePerCursor() async throws {
        try await harness.launch()
        let model = open()
        try await waitUntil("first page") { bodies(model).last == "History 44" }
        // Entering the screen is the one focus that clears K-17 attention and starts the page load.
        let focus = try XCTUnwrap(focuses.first)
        XCTAssertEqual(focuses.count, 1)
        XCTAssertEqual(focus.workspace_id, chatWS)
        XCTAssertEqual(focus.thread_id, chatThread)
        XCTAssertNil(focus.terminal_id)
        XCTAssertEqual(FocusClaim.owner, ObjectIdentifier(model))
        XCTAssertNil(transcriptPlaceholder(model.state))
        // Bodies go through the core's markdown utility, not a Swift parser.
        let blocks = await model.markdown("History 44")
        XCTAssertEqual(blocks.value?.map(\.kindName), ["Paragraph"])
        XCTAssertNotNil(model.cachedMarkdown("History 44"))
        XCTAssertGreaterThan(core.utilityQueries, 0)
        XCTAssertEqual(core.fallbackRenders, 0)
        // Reaching the oldest loaded row requests exactly one older page per cursor.
        model.loadOlder()
        model.loadOlder()
        try await waitUntil("older page") { model.thread?.page.has_older == false }
        model.loadOlder()
        model.loadOlder(force: true)
        XCTAssertEqual(count { if case .thread_load_older = $0 { return true }; return false }, 1)
        XCTAssertEqual(bodies(model).count, 45)
        XCTAssertEqual(bodies(model).last, "History 44")
    }

    func testRichRowsUseCoreRenderResults() async throws {
        try await harness.launch { $0.thread = "thread-rich" }
        let model = open()
        try await waitUntil("rich page") { model.items.count == 8 }
        XCTAssertEqual(model.items.map(\.kindName), ["Message", "Think", "ToolGroup", "ToolGroup", "Diff", "Message", "Notice", "Usage"])
        let assistant = try XCTUnwrap(model.thread?.rows.first { $0.id == "rich-assistant" })
        let rendered = await model.markdown(assistant.body).value
        let blocks = try XCTUnwrap(rendered)
        XCTAssertEqual(blocks.map(\.kindName), ["Heading", "Paragraph", "Bullets", "Quote", "Code", "Table"])
        // The code block is coloured by core highlight spans.
        guard case .code(let code, let language) = blocks[4] else { return XCTFail("code block") }
        let highlight = await model.highlight(code, language: try XCTUnwrap(language)).value
        let spans = try XCTUnwrap(highlight)
        XCTAssertFalse(spans.isEmpty)
        XCTAssertTrue(highlighted(code, spans).runs.contains { $0[Fg.self] != nil })
        // The changed-files card indexes files through the core.
        guard case .diff(let row) = model.items[4] else { return XCTFail("diff row") }
        let indexed = await model.index(row.body).value
        let index = try XCTUnwrap(indexed)
        XCTAssertEqual(index.files.map(\.path), ["src/main.zig"])
        XCTAssertEqual(core.fallbackRenders, 0)
        // Bigger than the core's 64 KiB utility budget: plain text, no query at all.
        let before = core.utilityQueries
        let huge = await model.markdown(String(repeating: "x", count: TranscriptModel.maxRenderSelector))
        XCTAssertNil(huge.value)
        XCTAssertEqual(core.utilityQueries, before)
    }

    func testLiveTailStreamsAndStopUsesTheCoreTurnID() async throws {
        try await harness.launch { $0.thread = "thread-running"; $0.composer = "composer-running" }
        let model = open()
        try await waitUntil("running") { model.state.canStop }
        XCTAssertEqual(model.state.turn?.turn_id, "fixture-turn")
        XCTAssertEqual(bodies(model).last, "Fixture prompt")
        XCTAssertEqual(model.items.last?.kindName, "Working")
        harness.deliver { $0.thread = "thread-streaming" }
        try await waitUntil("streaming") { bodies(model).last == "stub-ok" }
        XCTAssertEqual(model.thread?.rows.filter { $0.delivery == "streaming" }.count, 2)
        model.stopTurn()
        model.stopTurn()
        try await waitUntil("cancel") { count { if case .turn_cancel = $0 { return true }; return false } == 1 }
        let cancel = core.events.all.compactMap { if case .turn_cancel(let e) = $0 { return e }; return nil }.first
        XCTAssertEqual(cancel?.turn_id, "fixture-turn")
        try await waitUntil("stopping") { model.state.turn?.stop_pending == true }
        XCTAssertTrue(model.state.stopping)
        XCTAssertFalse(model.state.canStop)
        guard case .working(let turn, let waiting) = model.items.last else { return XCTFail("working row") }
        XCTAssertEqual(workingLabel(turn, waitingApproval: waiting, elapsed: "1:05"), "Stopping · 1:05")
        // Commit replaces the overlay; the A-09 access-cap notice arrives with the committed page.
        harness.deliver { $0.thread = "thread-committed"; $0.composer = "composer-committed" }
        try await waitUntil("committed") { model.state.turn == nil }
        XCTAssertTrue(bodies(model).last?.contains("This device is limited to approval-required access.") == true)
        XCTAssertFalse(model.items.contains { $0.kindName == "Working" })
        XCTAssertEqual(count { if case .turn_cancel = $0 { return true }; return false }, 1)
    }

    func testOfflineFocusIsRetriedOnceWhenTheHostBecomesReady() async throws {
        try await harness.launch(network: false)
        let model = open()
        try await waitUntil("offline focus") { model.focusError == "unavailable" }
        XCTAssertEqual(focuses.count, 1)
        XCTAssertEqual(transcriptPlaceholder(model.state), .offline)
        XCTAssertEqual(transcriptBanner(model.state, 0)?.text, "You're offline.")
        harness.setNetwork(true)
        try await waitUntil("loaded") { bodies(model).last == "History 44" }
        XCTAssertEqual(focuses.count, 2)
        // Further state changes never re-spend receipts on focus.
        harness.deliver()
        harness.deliver()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(focuses.count, 2)
    }

    func testLoadingErrorRetryAndBanner() async throws {
        try await harness.launch { $0.thread = "thread-loading" }
        let model = open()
        try await waitUntil("loading") { model.thread != nil }
        XCTAssertEqual(transcriptPlaceholder(model.state), .loading)
        harness.deliver { $0.thread = "thread-error" }
        try await waitUntil("error") { model.thread?.error != nil }
        XCTAssertEqual(transcriptPlaceholder(model.state), .error)
        let banner = try XCTUnwrap(transcriptBanner(model.state, 0))
        XCTAssertEqual(banner.action, .retry)
        XCTAssertTrue(banner.text.hasPrefix("Couldn't load this chat."))
        XCTAssertTrue(banner.text.contains("The runtime rejected the request."))
        core.afterFocus = "thread-open"
        model.retry()
        try await waitUntil("retried") { bodies(model).last == "History 44" }
        XCTAssertEqual(focuses.count, 2)
    }

    func testAThreadTheHostNoLongerHasSaysSo() async throws {
        try await harness.launch { $0.missing = true }
        let model = open()
        try await waitUntil("missing") { model.focusError == "thread_unavailable" }
        XCTAssertEqual(transcriptPlaceholder(model.state), .missing)
        XCTAssertEqual(focuses.count, 1)
    }

    func testLeavingUnfocusesOnlyWhatThisScreenStillOwns() async throws {
        try await harness.launch()
        let model = open()
        try await waitUntil("open") { bodies(model).last == "History 44" }
        model.setVisible(false)
        try await waitUntil("unfocus") { focuses.contains { $0.thread_id == nil } }
        XCTAssertNil(FocusClaim.owner)
        model.setVisible(true)
        try await waitUntil("refocus") { focuses.filter { $0.thread_id == chatThread }.count == 2 }
        // Another surface claimed focus: this screen's later unfocus must not clobber it.
        let other = NSObject()
        FocusClaim.owner = ObjectIdentifier(other)
        model.setVisible(false)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(focuses.filter { $0.thread_id == nil }.count, 1)
        XCTAssertEqual(FocusClaim.owner, ObjectIdentifier(other))
    }

    func testAGoneScreenStillReleasesItsFocus() async throws {
        try await harness.launch()
        var model: TranscriptModel? = TranscriptModel(browse: harness.browse, workspaceID: chatWS, threadID: chatThread, unfocusDelay: 0.05)
        model?.start()
        model?.setVisible(true)
        try await waitUntil("open") { model?.thread != nil }
        model?.setVisible(false)
        model = nil
        try await waitUntil("released") { focuses.contains { $0.thread_id == nil } }
        XCTAssertNil(FocusClaim.owner)
    }

    func testPureRules() throws {
        XCTAssertEqual(chatSelector("thread", chatWS, chatThread), "thread:%5B%22chat-fixture-ws%22%2C%22chat-fixture-thread%22%5D")
        XCTAssertEqual(chatSelector("composer", "a b", "é"), "composer:%5B%22a%20b%22%2C%22%C3%A9%22%5D")
        // UTF-8 byte offsets → UTF-16 indices across 1-, 2-, 3- and 4-byte characters.
        XCTAssertEqual(utf8ToUtf16("aé世😀"), [0, 1, 1, 2, 2, 2, 3, 3, 3, 3, 5])
        let spans = [RenderSpan(start: 3, end: 6, kind: "keyword"), RenderSpan(start: 6, end: 99, kind: "string")]
        XCTAssertEqual(highlightRanges("aé世😀", spans).map { [$0.start, $0.end] }, [[2, 3], [3, 5]])
        let styled = highlighted("aé世😀", spans)
        XCTAssertEqual(String(styled.characters), "aé世😀")
        XCTAssertEqual(styled.runs.filter { $0[Fg.self] != nil }.count, 2)
        XCTAssertEqual(safeLinkUrl("https://x.dev")?.absoluteString, "https://x.dev")
        XCTAssertNil(safeLinkUrl("javascript:alert(1)"))
        XCTAssertNil(safeLinkUrl("/relative"))
        XCTAssertEqual(basename("/tmp/rich-project/.verde/screenshot.png"), "screenshot.png")
        XCTAssertEqual(citationLabel(FileCitation(path: "/tmp/x/main.zig", line: 42)), "main.zig:42")
        let (lead, truncated) = leadingLines("a\nb\nc", 2)
        XCTAssertEqual(lead, "a\nb")
        XCTAssertTrue(truncated)
        XCTAssertEqual(countLines("a\nb\nc\n"), 3)
        XCTAssertEqual(commandPreview("Input:\nzig   build\n"), "Input: zig build")

        let rich = try XCTUnwrap(SharedFixtures.thread("d06", "thread-rich").data)
        let items = transcriptItems(rich)
        XCTAssertEqual(items.map(\.kindName), ["Message", "Think", "ToolGroup", "ToolGroup", "Diff", "Message", "Notice", "Usage"])
        let groups = items.compactMap { item -> ([ChatRow], Bool)? in
            if case .toolGroup(let rows, let subagent) = item { return (rows, subagent) }
            return nil
        }
        XCTAssertEqual(groups.map(\.1), [false, true])
        XCTAssertEqual(toolGroupSummary(groups[0].0, subagent: false, elapsed: "0:05"), "3 tool calls · 2 completed · 1 failed")
        XCTAssertEqual(toolGroupSummary(groups[1].0, subagent: true, elapsed: nil), "1 subagent · 1 completed")
        let stopping = try XCTUnwrap(SharedFixtures.thread("d06", "thread-stopping").data)
        let stoppingItems = transcriptItems(stopping)
        guard case .working(let turn, let waiting) = stoppingItems.last else { return XCTFail("working row") }
        XCTAssertEqual(workingLabel(turn, waitingApproval: waiting, elapsed: "1:05"), "Stopping · 1:05")
        XCTAssertEqual(stoppingItems.filter { $0.kindName == "Working" }.map(\.id), ["working"])
        XCTAssertFalse(transcriptItems(try XCTUnwrap(SharedFixtures.thread("d06", "thread-committed").data)).contains { $0.kindName == "Working" })
        // Streaming bodies send only a bounded tail to the markdown utility.
        var big = ChatRow(id: "s", role: "assistant", body: String(repeating: "x", count: 20_000) + "\ntail", delivery: "streaming")
        XCTAssertEqual(streamTail(big, max: 10), "tail")
        big.delivery = "committed"
        XCTAssertEqual(streamTail(big, max: 10), big.body)
        XCTAssertEqual(deliveryLabel("optimistic"), "Sending…")
        XCTAssertEqual(deliveryLabel("failed"), "Not sent")
        XCTAssertNil(deliveryLabel("committed"))

        // Recorded core markdown → blocks: citations become private links, web links only for admitted schemes.
        let assistant = try XCTUnwrap(rich.rows.first { $0.id == "rich-assistant" })
        let reply = try XCTUnwrap(RecordedRenders.result("markdown", assistant.body))
        let nodes = try XCTUnwrap(try JSONDecoder().decode(MarkdownQuery.self, from: reply).data?.nodes)
        let blocks = markdownBlocks(nodes)
        XCTAssertEqual(blocks.map(\.kindName), ["Heading", "Paragraph", "Bullets", "Quote", "Code", "Table"])
        guard case .paragraph(let paragraph) = blocks[1] else { return XCTFail("paragraph") }
        let links = paragraph.runs.compactMap { $0[LinkKey.self] }
        let cited = try XCTUnwrap(links.compactMap(citation(from:)).first)
        XCTAssertEqual(cited.path, "/tmp/rich-project/src/main.zig")
        XCTAssertEqual(cited.line, 42)
        XCTAssertEqual(links.filter { $0.scheme == "https" }.map(\.absoluteString), ["https://ziglang.org/documentation/"])
        // Heading markers are consumed by the AST.
        guard case .heading(_, let heading) = blocks[0] else { return XCTFail("heading") }
        XCTAssertFalse(String(heading.characters).contains("#"))
    }

    func testTranscriptStateRules() throws {
        var state = TranscriptState()
        state.browse.row = HostRow(saved: SavedHost(id: "alpha", label: "Studio"), view: hostView("alpha", "Studio", sync: "ready"))
        XCTAssertEqual(transcriptPlaceholder(state), .loading)
        state.browse.networkAvailable = false
        XCTAssertEqual(transcriptPlaceholder(state), .offline)
        state.browse.networkAvailable = true
        state.fatal = true
        XCTAssertEqual(transcriptBanner(state, 0)?.text, "Connection unavailable — reopen Verde.")
        state.fatal = false
        state.browse.row?.view?.auth_state = "unpaired"
        XCTAssertEqual(transcriptBanner(state, 0), Banner(text: "This phone isn't paired with Studio.", action: .hosts, error: true))
        XCTAssertEqual(transcriptPlaceholder(state), .offline)
        state.browse.row?.view?.auth_state = "paired"
        XCTAssertNil(transcriptBanner(state, 0))
        state.thread = SharedFixtures.thread("d06", "thread-open").data
        XCTAssertNil(transcriptPlaceholder(state))
        state.thread = SharedFixtures.thread("d06", "thread-loading").data
        XCTAssertEqual(transcriptPlaceholder(state), .loading)
        state.thread?.page.loading = false
        XCTAssertEqual(transcriptPlaceholder(state), .empty)
        state.focusError = "unavailable"
        XCTAssertEqual(transcriptPlaceholder(state), .loading)
        state.focusError = "thread_unavailable"
        XCTAssertEqual(transcriptPlaceholder(state), .missing)
        state.thread = nil
        XCTAssertEqual(transcriptPlaceholder(state), .missing)
        state.focusError = nil
        XCTAssertEqual(transcriptPlaceholder(state), .loading)
    }
}
