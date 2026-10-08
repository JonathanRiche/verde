import XCTest
@testable import VerdeApp

/// Workspace explorer (Android ExplorerTest.kt parity): tree flattening, read outcomes, the Changes
/// filter, line selection, ask targets, and the model's intents and prompt query.
@MainActor
final class ExplorerTests: XCTestCase {
    override func setUp() { super.setUp(); PromptHandoff.clear() }
    override func tearDown() { PromptHandoff.clear(); super.tearDown() }

    private func entry(_ path: String, dir: Bool = false, ignored: Bool = false) -> ExplorerEntry {
        ExplorerEntry(name: String(path.split(separator: "/").last ?? ""), path: path, kind: dir ? "directory" : "file", size: 10, ignored: ignored)
    }

    func testTreeFlattensExpandedFoldersDepthFirstWithNotes() {
        let view = ExplorerFilesView(workspace_id: "ws", loaded: true,
            roots: [ExplorerRoot(id: "home", name: "app", path: "/w/app", home: true), ExplorerRoot(id: "lib", name: "lib", path: "/w/lib")],
            dirs: [
                ExplorerDir(root: "home", path: "", entries: [entry("src", dir: true), entry("build", dir: true, ignored: true), entry("README.md")], truncated: true, loaded: true),
                ExplorerDir(root: "home", path: "src", loading: true),
                ExplorerDir(root: "lib", path: "", error: LocalError(code: "not_found", message: "")),
            ])
        let rows = treeRows(view, expanded: [dirKey("home", ""), dirKey("home", "src"), dirKey("lib", "")])
        XCTAssertEqual(rows.map(\.id), ["root:home", "entry:home\u{0}src", "note:home\u{0}src", "entry:home\u{0}build", "entry:home\u{0}README.md",
                                        "note:home\u{0}\u{0}more", "root:lib", "note:lib\u{0}"])
        guard case .note(_, _, let depth, _, _, let loading) = rows[2] else { return XCTFail("loading note") }
        XCTAssertEqual(depth, 2)
        XCTAssertTrue(loading)
        guard case .note(_, _, _, let more, _, _) = rows[5] else { return XCTFail("truncation note") }
        XCTAssertEqual(more, "Showing the first 3 entries")
        guard case .note(_, _, _, _, let retry, _) = rows[7] else { return XCTFail("error note") }
        XCTAssertTrue(retry)
        // Collapsed folders hide their children; an unlisted expanded folder shows as loading.
        XCTAssertEqual(treeRows(view, expanded: []).map(\.id), ["root:home", "root:lib"])
        guard case .note(_, _, _, _, _, let unlisted) = treeRows(view, expanded: [dirKey("home", ""), dirKey("home", "build")])[3] else {
            return XCTFail("unlisted note")
        }
        XCTAssertTrue(unlisted)
        // The same relative path in another root is another folder.
        XCTAssertFalse(treeRows(view, expanded: [dirKey("lib", "src")]).contains { if case .item = $0 { return true }; return false })
        XCTAssertEqual(ExplorerRoot(id: "lib", name: "lib", path: "/w/lib/").absolute("src/a.swift"), "/w/lib/src/a.swift")
        XCTAssertNil(ExplorerRoot(id: "x", name: "x").absolute("a"))
        XCTAssertEqual(entrySize(512), "512 B")
        XCTAssertEqual(entrySize(2048), "2 KB")
    }

    func testReadOutcomesMapKindsAndErrorsForTheViewer() {
        func view(_ kind: String, _ encoding: String = "none", _ content: String = "") -> ExplorerFileView {
            ExplorerFileView(workspace_id: "ws", root: "home", path: "a",
                             result: ExplorerReadResult(root: "home", path: "a", kind: kind, encoding: encoding, content: content))
        }
        XCTAssertEqual(readOutcome(view("text", "utf8", "héllo")), .bytes(Data("héllo".utf8)))
        XCTAssertEqual(readOutcome(view("image", "base64", "AQID")), .bytes(Data([1, 2, 3])))
        XCTAssertEqual(readOutcome(view("image", "base64", "!!")), .problem(.unreadable))
        XCTAssertEqual(readOutcome(view("binary")), .problem(.binary))
        XCTAssertEqual(readOutcome(view("too_large")), .problem(.of("too_large", limit: ViewerKind.text.limit)))
        let cut = ExplorerFileView(workspace_id: "ws", root: "home", path: "a",
                                   result: ExplorerReadResult(root: "home", path: "a", size: 3 * 1024 * 1024, kind: "text", encoding: "utf8", content: "head", truncated: true))
        XCTAssertEqual(readOutcome(cut), .partial(Data("head".utf8), FilePartial(shown: FilePartial.readTextBytes, total: 3 * 1024 * 1024)))
        XCTAssertEqual(FilePartial(shown: FilePartial.readTextBytes, total: 3 * 1024 * 1024).text, "Showing the first 512 KB of 3 MB")
        XCTAssertEqual(FilePartial(shown: FilePartial.readTextBytes, total: 0).text, "Showing the first 512 KB")
        // PDFs and documents, and hosts without the method, fall back to the path fetch.
        XCTAssertNil(readOutcome(view("external")))
        XCTAssertNil(readOutcome(ExplorerFileView(supported: false)))
        XCTAssertNil(readFailure("unsupported"))
        XCTAssertEqual(readFailure("root_not_found"), .problem(.of("not_found", limit: 0)))
        XCTAssertEqual(readFailure("path_outside_roots"), .problem(.of("forbidden", limit: 0)))
        XCTAssertEqual(readFailure("offline"), .problem(.of("offline", limit: 0)))
        XCTAssertEqual(readFailure("invalid_path"), .problem(.unresolved))
    }

    func testChangesFilterByChatAndUnassignedWithTitleFallback() {
        let a = GitWorkspaceOwner(local_thread_id: "chat-aaaaaa111111", title: "Fix build")
        let b = GitWorkspaceOwner(local_thread_id: "chat-bbbbbb222222", title: "")
        let files = [
            GitWorkspaceFile(path: "one.swift", status: "modified", ownership: "mine", owners: [a]),
            GitWorkspaceFile(path: "two.swift", status: "added", untracked: true, ownership: "shared", owners: [a, b]),
            GitWorkspaceFile(path: "three.swift", status: "deleted", ownership: "unassigned"),
        ]
        let owners = changeOwners([GitWorkspaceRepo(root: "/w/app", name: "app", files: files)])
        XCTAssertEqual(owners.map { owner -> String in if case .chat(_, let title) = owner { return title }; return "" }, ["Fix build", "Chat 222222"])
        XCTAssertEqual(owners.map(\.threadID), ["chat-aaaaaa111111", "chat-bbbbbb222222"])
        XCTAssertEqual(files.filter { $0.matches(owners[0]) }.map(\.path), ["one.swift", "two.swift"])
        XCTAssertEqual(files.filter { $0.matches(owners[1]) }.map(\.path), ["two.swift"])
        XCTAssertEqual(files.filter { $0.matches(.unassigned) }.map(\.path), ["three.swift"])
        XCTAssertEqual(files.map(changeLetter), ["M", "U", "D"])
        XCTAssertEqual(explorerErrorText(LocalError(code: "unsupported", message: "")), "Update Verde on the computer to use this.")
        XCTAssertNil(explorerErrorText(nil))
    }

    func testSelectionTapsDragsAndMapsToFileAndDiffLines() {
        let s = LineSelection()
        s.tap(5); XCTAssertEqual(s.range, 5...5)
        s.tap(2); XCTAssertEqual(s.range, 2...5)
        s.drag(7); XCTAssertEqual(s.range, 5...7)
        s.clear(); s.tap(3); s.tap(3); XCTAssertNil(s.range)
        s.drag(4); XCTAssertNil(s.range)

        let text = "a\nbb\nccc\n"
        XCTAssertEqual(fileLineStarts(text), [0, 2, 5])
        XCTAssertEqual(fileLines(text, starts: [0, 2, 5], range: 2...3), PickedLines(start: 2, end: 3, side: nil, text: "bb\nccc"))
        XCTAssertEqual(fileLines(text, starts: [0, 2, 5], range: 3...9), PickedLines(start: 3, end: 3, side: nil, text: "ccc"))
        XCTAssertEqual(FileSplit("x\r\n\ny").lines, ["x", "", "y"])
        s.start(1); s.source = { fileLines(text, starts: [0, 2, 5], range: $0) }
        XCTAssertEqual(s.picked()?.text, "a")

        func row(_ kind: String, _ old: UInt64?, _ new: UInt64?, _ raw: String) -> DiffRow {
            DiffRow(kind: kind, raw: raw, text: raw, oldLine: old, newLine: new, words: [], syntax: [])
        }
        let rows = [row("context", 1, 1, "keep"), row("delete", 2, nil, "gone"), row("add", nil, 2, "new"), row("context", 3, 3, "tail")]
        // Mixed rows pick the new side and drop deletions.
        XCTAssertEqual(diffLines(rows, range: 1...4), PickedLines(start: 1, end: 3, side: "new", text: "keep\nnew\ntail"))
        // Deletions alone (with context) are old-side lines.
        XCTAssertEqual(diffLines(rows, range: 1...2), PickedLines(start: 1, end: 2, side: "old", text: "keep\ngone"))
        XCTAssertEqual(diffLines(rows, range: 1...2).map(linesLabel), "Lines 1–2 (old)")
        XCTAssertEqual(diffLines(rows, range: 3...3).map(linesLabel), "Line 2 (new)")
        XCTAssertNil(diffLines([], range: 1...1))
    }

    func testAskTargetsAreListedUnarchivedChatsOpenAndRecentFirst() {
        func thread(_ id: String, open: Bool, archived: Bool = false, at: Int64?, committed: Bool = true) -> ThreadSummary {
            ThreadSummary(workspace_id: "ws", thread_id: id, title: id, provider: "codex", model: nil, cwd: nil, open: open, archived: archived,
                          last_activity_at_ms: at, status: "idle", history_bucket: "today", committed: committed)
        }
        let threads = [thread("closed-new", open: false, at: 900), thread("open-old", open: true, at: 10), thread("open-new", open: true, at: 50),
                       thread("archived", open: true, archived: true, at: 999), thread("draft", open: true, at: 999, committed: false),
                       thread("subagent:x", open: true, at: 999), thread("b-untimed", open: false, at: nil), thread("a-untimed", open: false, at: nil)]
        XCTAssertEqual(askTargets(threads).map(\.thread_id), ["open-new", "open-old", "closed-new", "a-untimed", "b-untimed"])
    }

    func testPromptHandoffIsTakenOnceAndKeyedByHostWorkspaceAndChat() {
        PromptHandoff.put(host: "host", workspace: "ws", thread: "chat-1", text: "prompt")
        XCTAssertNil(PromptHandoff.take(host: "other", workspace: "ws", thread: "chat-1"))
        XCTAssertNil(PromptHandoff.take(host: "host", workspace: "ws", thread: "chat-2"))
        XCTAssertEqual(PromptHandoff.take(host: "host", workspace: "ws", thread: "chat-1"), "prompt")
        XCTAssertNil(PromptHandoff.take(host: "host", workspace: "ws", thread: "chat-1"))
    }

    /// A fake core: projections answered from `views`, the prompt utility from `prompt`.
    func testACutReadKeepsTheBannerAndDownloadRefetchesTheWholeFile() async {
        let fake = ChatCore(SavedHost(id: "alpha", label: "Studio"), directory: "d09", thread: "approval-command")
        let host = CoreHost(core: fake, store: CoreViewStore(), transport: NullTransport(), storage: MemoryStorage())
        let model = FileViewerModel()
        let partial = FilePartial(shown: FilePartial.readTextBytes, total: 3 * 1024 * 1024)
        await model.load(host: host, path: "/w/big.txt") { _ in .partial(Data("one\ntwo\n".utf8), partial) }
        XCTAssertEqual(model.text, "one\ntwo\n")
        XCTAssertEqual(model.partial, partial)
        // The shown bytes aren't the original file, so Download fetches it instead of sharing them.
        XCTAssertFalse(model.original)
        await model.load(host: host, path: "/w/small.txt") { _ in .bytes(Data("one".utf8)) }
        XCTAssertNil(model.partial)
        XCTAssertTrue(model.original)
    }

    @MainActor private final class Fake {
        var events: [Event] = []
        var queries: [String] = []
        var views: [String: Data] = [:]
        var prompt: String? = "In `src/a.swift` lines 2–3:\n```swift\nb\nc\n```\nExplain"

        func query(_ selector: String) throws -> Data {
            queries.append(selector)
            if selector.contains("\"selection_prompt\"") {
                let data: Any = prompt.map { ["text": $0] as Any } ?? NSNull()
                return try JSONSerialization.data(withJSONObject: ["api_version": 1, "revision": "1", "data": data])
            }
            return views[selector] ?? Data(#"{"api_version":1,"revision":"1","data":null,"error":null}"#.utf8)
        }

        func model(_ workspace: String = "ws") -> ExplorerModel {
            ExplorerModel(workspaceID: workspace, send: { self.events.append($0) }, query: { try self.query($0) })
        }
    }

    private func changes(_ workspace: String = "ws", files: Int = 2) -> Data {
        let all = [GitWorkspaceFile(path: "src/one.swift", status: "modified", ownership: "mine",
                                    owners: [GitWorkspaceOwner(local_thread_id: "chat-1", title: "Fix build")], additions: 3, deletions: 1),
                   GitWorkspaceFile(path: "notes.md", status: "added", untracked: true, ownership: "unassigned", additions: 4)]
        let view = ExplorerChangesView(workspace_id: workspace, loaded: true,
                                       repos: [GitWorkspaceRepo(root: "/w/app", name: "app", branch: "main", files: Array(all.prefix(files)))])
        return (try? JSONEncoder().encode(ExplorerChangesQuery(api_version: 1, revision: "1", data: view, error: nil))) ?? Data()
    }

    func testModelSendsExplorerIntentsInOrderAndIgnoresOtherWorkspaces() async throws {
        let fake = Fake()
        let m = fake.model()
        m.closeChanges()
        m.loadRoots(); m.list(root: "home", path: "src"); m.openChanges(); m.openPatch(root: "/w/app", path: "src/one.swift", full: true)
        m.openPatch(root: "/w/app", path: "src/one.swift", full: false)
        try await waitUntil("intents") { fake.events.count == 5 }
        let lists = fake.events.compactMap { if case .workspace_files_list(let e) = $0 { return e }; return nil }
        XCTAssertEqual(lists.count, 2)
        XCTAssertNil(lists[0].root)
        XCTAssertNil(lists[0].path)
        XCTAssertEqual(lists[1].root, "home")
        XCTAssertEqual(lists[1].path, "src")
        XCTAssertTrue(lists.allSatisfy { $0.workspace_id == "ws" })
        let patches = fake.events.compactMap { if case .workspace_file_patch(let e) = $0 { return e }; return nil }
        XCTAssertEqual(patches.map(\.context_lines), [fullContextLines, nil])
        XCTAssertEqual(patches.first?.root, "/w/app")
        // A close before any open sends nothing; the open is the third intent.
        XCTAssertFalse(fake.events.contains { if case .workspace_changes_close = $0 { return true }; return false })
        guard case .workspace_changes_open = fake.events[2] else { return XCTFail("changes open order") }
        // Connecting read the cached projections once.
        XCTAssertTrue(fake.queries.contains("workspace_files:ws"))
        XCTAssertTrue(fake.queries.contains("workspace_changes:ws"))

        m.receive("workspace_changes:ws", changes())
        XCTAssertEqual(m.changes?.repos.first?.files.count, 2)
        m.receive("workspace_changes:ws", changes("other", files: 0))
        XCTAssertEqual(m.changes?.repos.first?.files.count, 2)
        m.receive("workspace_changes:ws", nil)
        XCTAssertEqual(m.changes?.repos.first?.files.count, 2)

        m.closeChanges(); m.closeChanges()
        try await waitUntil("close") { fake.events.count == 6 }
        guard case .workspace_changes_close(let close) = fake.events[5] else { return XCTFail("changes close") }
        XCTAssertEqual(close.workspace_id, "ws")
        XCTAssertFalse(m.watching)
    }

    func testCachedProjectionsShowOnConnect() async throws {
        let fake = Fake()
        fake.views["workspace_changes:ws"] = changes()
        let m = fake.model()
        m.start()
        try await waitUntil("cached") { m.changes != nil }
        XCTAssertEqual(m.changes?.repos.first?.name, "app")
        XCTAssertTrue(fake.events.isEmpty)
    }

    func testUnavailableHostSendsNothing() async throws {
        let fake = Fake()
        let m = ExplorerModel(workspaceID: "ws", connect: { false }, send: { fake.events.append($0) }, query: { try fake.query($0) })
        m.loadRoots()
        try await waitUntil("unavailable") { m.unavailable }
        XCTAssertTrue(fake.events.isEmpty)
        XCTAssertTrue(fake.queries.isEmpty)
    }

    func testPromptUsesTheSharedFormatterWithRootsAndSide() async throws {
        let fake = Fake()
        let m = fake.model()
        let text = await m.prompt(SelectionExcerpt(path: "/w/app/src/a.swift", start: 2, end: 3, side: "old", text: "b\nc"),
                                  roots: [ExplorerRoot(id: "home", name: "app", path: "/w/app", home: true)], instruction: "Explain")
        XCTAssertEqual(text, fake.prompt)
        let raw = try XCTUnwrap(fake.queries.last { $0.contains("selection_prompt") })
        let selector = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual(selector["utility"] as? String, "selection_prompt")
        XCTAssertEqual(selector["path"] as? String, "/w/app/src/a.swift")
        XCTAssertEqual(selector["side"] as? String, "old")
        XCTAssertEqual(selector["start_line"] as? Int, 2)
        XCTAssertEqual(selector["end_line"] as? Int, 3)
        XCTAssertEqual(selector["text"] as? String, "b\nc")
        XCTAssertEqual(selector["instruction"] as? String, "Explain")
        let roots = try XCTUnwrap(selector["roots"] as? [[String: Any]])
        XCTAssertEqual(roots.first?["home"] as? Bool, true)
        XCTAssertEqual(roots.first?["name"] as? String, "app")
        XCTAssertTrue(raw.contains("/w/app/src/a.swift"), "slashes stay unescaped")

        // File selections carry no side; a refused prompt is nil.
        fake.prompt = nil
        let none = await m.prompt(SelectionExcerpt(path: "/w/app/a", start: 1, end: 1, side: nil, text: "a"), roots: [], instruction: "x")
        XCTAssertNil(none)
        let second = try XCTUnwrap(fake.queries.last { $0.contains("selection_prompt") })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(second.utf8)) as? [String: Any])
        XCTAssertNil(object["side"])
    }
}
