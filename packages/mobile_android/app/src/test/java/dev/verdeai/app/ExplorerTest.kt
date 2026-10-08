package dev.verdeai.app

import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Text
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModelStore
import dev.verdeai.core.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.After
import kotlinx.coroutines.launch
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.time.Duration
import java.util.concurrent.CopyOnWriteArrayList

/** Pure helpers of the explorer: tree flattening, the Changes filter, and selection-to-lines. */
class ExplorerLogicTest {
    private fun entry(path: String, dir: Boolean = false, ignored: Boolean = false) =
        ExplorerEntry(path.substringAfterLast('/'), path, if (dir) "directory" else "file", 10uL, ignored)

    @Test fun treeFlattensExpandedFoldersDepthFirstWithNotes() {
        val view = ExplorerFilesView("ws", loaded = true, roots = listOf(ExplorerRoot("home", "app", "/w/app", true), ExplorerRoot("lib", "lib", "/w/lib")), dirs = listOf(
            ExplorerDir("home", "", listOf(entry("src", dir = true), entry("build", dir = true, ignored = true), entry("README.md")), truncated = true, loaded = true),
            ExplorerDir("home", "src", loading = true),
            ExplorerDir("lib", "", error = LocalError(code = "not_found", message = "")),
        ))
        val rows = treeRows(view, setOf(dirKey("home", ""), dirKey("home", "src"), dirKey("lib", "")))
        assertEquals(listOf("root:home", "entry:home\u0000src", "note:home\u0000src", "entry:home\u0000build", "entry:home\u0000README.md",
            "note:home\u0000\u0000more", "root:lib", "note:lib\u0000"), rows.map { it.key })
        assertEquals(2, (rows[2] as TreeRow.Note).depth)
        assertTrue((rows[2] as TreeRow.Note).loading)
        assertEquals("Showing the first 3 entries", (rows[5] as TreeRow.Note).text)
        assertTrue((rows[7] as TreeRow.Note).retry)
        // Collapsed folders hide their children; an unlisted expanded folder shows as loading.
        assertEquals(listOf("root:home", "root:lib"), treeRows(view, emptySet()).map { it.key })
        assertTrue((treeRows(view, setOf(dirKey("home", ""), dirKey("home", "build")))[3] as TreeRow.Note).loading)
        // The same relative path in another root is another folder.
        assertTrue(treeRows(view, setOf(dirKey("lib", "src"))).none { it is TreeRow.Item })
        assertEquals("/w/lib/src/a.kt", ExplorerRoot("lib", "lib", "/w/lib/").absolute("src/a.kt"))
        assertNull(ExplorerRoot("x", "x").absolute("a"))
    }

    @Test fun readOutcomesMapKindsAndErrorsForTheViewer() {
        fun view(kind: String, encoding: String = "none", content: String = "") =
            ExplorerFileView("ws", "home", "a", result = ExplorerReadResult("home", "a", kind = kind, encoding = encoding, content = content))
        assertArrayEquals("héllo".encodeToByteArray(), readOutcome(view("text", "utf8", "héllo")) as ByteArray)
        assertArrayEquals(byteArrayOf(1, 2, 3), readOutcome(view("image", "base64", "AQID")) as ByteArray)
        assertEquals(FileProblem.Unreadable, (readOutcome(view("image", "base64", "!!")) as FileViewState).problem)
        assertEquals(FileProblem.Binary, (readOutcome(view("binary")) as FileViewState).problem)
        assertEquals(FileProblem.TooLarge, (readOutcome(view("too_large")) as FileViewState).problem)
        // PDFs and documents, and hosts without the method, fall back to the /api/file fetch.
        assertNull(readOutcome(view("external")))
        assertNull(readOutcome(ExplorerFileView(supported = false)))
        assertNull(readFailure("unsupported", false))
        assertEquals(FileProblem.NotFound, (readFailure("root_not_found", false) as FileViewState).problem)
        assertEquals(FileProblem.Forbidden, (readFailure("path_outside_roots", false) as FileViewState).problem)
        assertTrue((readFailure("offline", false) as FileViewState).retryable)
    }

    @Test fun changesFilterByChatAndUnassignedWithTitleFallback() {
        val a = GitWorkspaceOwner("chat-aaaaaa111111", "Fix build")
        val b = GitWorkspaceOwner("chat-bbbbbb222222", "")
        val files = listOf(
            GitWorkspaceFile("one.kt", "modified", ownership = "mine", owners = listOf(a)),
            GitWorkspaceFile("two.kt", "added", untracked = true, ownership = "shared", owners = listOf(a, b)),
            GitWorkspaceFile("three.kt", "deleted", ownership = "unassigned"))
        val owners = changeOwners(listOf(GitWorkspaceRepo("/w/app", "app", files = files)))
        assertEquals(listOf("Fix build", "Chat 222222"), owners.map { it.title })
        assertEquals(listOf("one.kt", "two.kt"), files.filter { it.matches(owners[0]) }.map { it.path })
        assertEquals(listOf("two.kt"), files.filter { it.matches(owners[1]) }.map { it.path })
        assertEquals(listOf("three.kt"), files.filter { it.matches(ChangesFilter.Unassigned) }.map { it.path })
        assertEquals(listOf("M", "U", "D"), files.map(::changeLetter))
        assertEquals("Update Verde on the computer to use this.", explorerErrorText(LocalError(code = "unsupported", message = "")))
    }

    @Test fun selectionTapsDragsAndMapsToFileAndDiffLines() {
        val s = LineSelection()
        s.tap(5); assertEquals(5..5, s.range)
        s.tap(2); assertEquals(2..5, s.range)
        s.drag(7); assertEquals(5..7, s.range)
        s.clear(); s.tap(3); s.tap(3); assertNull(s.range)

        val text = "a\nbb\nccc\n"
        assertEquals(PickedLines(2, 3, null, "bb\nccc"), fileLines(text, intArrayOf(0, 2, 5), 2..3))
        assertEquals(PickedLines(3, 3, null, "ccc"), fileLines(text, intArrayOf(0, 2, 5), 3..9))

        fun row(kind: String, old: Int?, new: Int?, raw: String) = DiffRow(kind, raw, raw, old?.toULong(), new?.toULong(), emptyList(), emptyList())
        val rows = listOf(row("context", 1, 1, "keep"), row("delete", 2, null, "gone"), row("add", null, 2, "new"), row("context", 3, 3, "tail"))
        // Mixed rows pick the new side and drop deletions.
        assertEquals(PickedLines(1, 3, "new", "keep\nnew\ntail"), diffLines(rows, 1..4))
        // Deletions alone (with context) are old-side lines.
        assertEquals(PickedLines(1, 2, "old", "keep\ngone"), diffLines(rows, 1..2))
        assertEquals("Lines 1–2 (old)", linesLabel(diffLines(rows, 1..2)!!))
        assertEquals("Line 2 (new)", linesLabel(diffLines(rows, 3..3)!!))
    }
}

/** A fake host core: projections pushed as views, utility queries answered from fixtures. */
internal class ExplorerFake : ExplorerConnection {
    override val views = MutableStateFlow<Map<String, JsonElement>>(emptyMap())
    val events = CopyOnWriteArrayList<Event>()
    val queries = CopyOnWriteArrayList<String>()
    var prompt: String? = "In `src/a.kt` lines 2–3:\n```kotlin\nb\nc\n```\nExplain"
    var diff: DiffView? = null
    override suspend fun query(selector: String): JsonElement {
        queries += selector
        val obj = try { Json.parseToJsonElement(selector).jsonObject } catch (_: Exception) { null }
        return when (obj?.get("utility")?.jsonPrimitive?.content) {
            "selection_prompt" -> envelope(prompt?.let { buildJsonObject { put("text", it) } })
            "diff" -> envelope(diff?.let { CoreJson.encodeToJsonElement(it) })
            null -> views.value[selector] ?: envelope(null)
            else -> envelope(null)
        }
    }
    override suspend fun send(event: (Long, Long) -> Event) { events += event(1, 1) }
    fun push(selector: String, data: JsonElement) { views.value = views.value + (selector to envelope(data)) }
    inline fun <reified T> push(selector: String, data: T) = push(selector, CoreJson.encodeToJsonElement(data))
    private fun envelope(data: JsonElement?) = buildJsonObject {
        put("api_version", 1); put("revision", "1"); put("data", data ?: JsonNull); put("error", JsonNull)
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ExplorerTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val models = ViewModelStore()
    @After fun closeModels() { models.clear(); PromptHandoff.clear() }
    @Before fun phone() { PromptHandoff.clear() }

    private fun pump() = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(20))
    private fun await(condition: () -> Boolean) = compose.waitUntil(5000) { pump(); condition() }
    private fun model(fake: ExplorerFake, ws: String = "ws"): ExplorerModel =
        ExplorerModel(ws) { fake }.also { models.put("explorer:${System.identityHashCode(it)}", it) }
    private inline fun <reified T : Event> ExplorerFake.sent() = events.filterIsInstance<T>()

    private val owner = GitWorkspaceOwner("chat-1", "Fix build")
    private fun changes(loaded: Boolean = true) = ExplorerChangesView("ws", loaded = loaded, repos = listOf(
        GitWorkspaceRepo("/w/app", "app", branch = "main", files = listOf(
            GitWorkspaceFile("src/one.kt", "modified", ownership = "mine", owners = listOf(owner), additions = 3, deletions = 1),
            GitWorkspaceFile("notes.md", "added", untracked = true, ownership = "unassigned", additions = 4)))))

    @Test fun modelSendsExplorerIntentsAndClosesChangesWhenCleared() {
        val fake = ExplorerFake()
        val m = model(fake)
        compose.runOnIdle { m.loadRoots(); m.list("home", "src"); m.openChanges(); m.openPatch("/w/app", "src/one.kt", full = true) }
        await { fake.events.size == 4 }
        assertNull(fake.sent<EventWorkspaceFilesList>()[0].root)
        assertNull(fake.sent<EventWorkspaceFilesList>()[0].path)
        assertEquals("home", fake.sent<EventWorkspaceFilesList>()[1].root)
        assertEquals("src", fake.sent<EventWorkspaceFilesList>()[1].path)
        assertEquals(FULL_CONTEXT_LINES, fake.sent<EventWorkspaceFilePatch>().single().context_lines)
        fake.push("workspace_changes:ws", changes())
        await { m.state.value.changes?.repos?.size == 1 }
        // Another workspace's projection is ignored.
        fake.push("workspace_changes:other", changes().copy(workspace_id = "other", repos = emptyList()))
        pump()
        assertEquals(1, m.state.value.changes?.repos?.size)
        compose.runOnIdle { models.clear() }
        await { fake.sent<EventWorkspaceChangesClose>().size == 1 }
    }

    @Test fun promptUsesTheSharedFormatterWithRootsAndSide() {
        val fake = ExplorerFake()
        val m = model(fake)
        var text: String? = null
        compose.runOnIdle {
            kotlinx.coroutines.MainScope().launch {
                text = m.prompt(SelectionExcerpt("/w/app/src/a.kt", 2, 3, "old", "b\nc"), listOf(ExplorerRoot("home", "app", "/w/app", true)), "Explain")
            }
        }
        await { text != null }
        val selector = Json.parseToJsonElement(fake.queries.last { "selection_prompt" in it }).jsonObject
        assertEquals("/w/app/src/a.kt", selector["path"]!!.jsonPrimitive.content)
        assertEquals("old", selector["side"]!!.jsonPrimitive.content)
        assertEquals(2, selector["start_line"]!!.jsonPrimitive.int)
        assertEquals(true, selector["roots"]!!.jsonArray[0].jsonObject["home"]!!.jsonPrimitive.boolean)
        assertEquals(fake.prompt, text)
    }

    @Test fun changesListFiltersByChatOpensFilesAndCommitsAsTheChat() {
        val fake = ExplorerFake()
        val m = model(fake)
        val opened = mutableListOf<Pair<String, String>>()
        val committed = mutableListOf<String>()
        compose.setContent { VerdeTheme { ChangesScreen(m, "app", emptyList(), { r, p -> opened += r to p }, { committed += it }, {}) } }
        await { fake.sent<EventWorkspaceChangesOpen>().size == 1 }
        compose.onNodeWithTag("changes-loading").assertExists()
        fake.push("workspace_changes:ws", changes())
        await { compose.onAllNodesWithTag("change-src/one.kt").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithTag("change-notes.md").assertExists()
        compose.onNodeWithText("All · 2").assertExists()
        compose.onNodeWithTag("changes-filter-chat-1").performClick()
        compose.onNodeWithTag("change-notes.md").assertDoesNotExist()
        compose.onNodeWithTag(CHANGES_COMMIT_TAG).assertTextEquals("Commit").performClick()
        assertEquals(listOf("chat-1"), committed)
        compose.onNodeWithTag("changes-filter-unassigned").performClick()
        compose.onNodeWithTag(CHANGES_COMMIT_TAG).assertIsNotEnabled()
        compose.onNodeWithTag("change-notes.md").performClick()
        assertEquals(listOf("/w/app" to "notes.md"), opened)
    }

    @Test fun olderHostsSayUpdateVerde() {
        val fake = ExplorerFake()
        val m = model(fake)
        compose.setContent { VerdeTheme { ChangesScreen(m, "app", emptyList(), { _, _ -> }, null, {}) } }
        fake.push("workspace_changes:ws", ExplorerChangesView("ws", supported = false))
        await { compose.onAllNodesWithText("Update Verde on the computer to use this.").fetchSemanticsNodes().isNotEmpty() }
    }

    @Test fun filesTreeOpensHomeListsFoldersAndOpensFiles() {
        val fake = ExplorerFake()
        val m = model(fake)
        val opened = mutableListOf<Pair<String, String>>()
        val roots = listOf(ExplorerRoot("home", "app", "/w/app", true), ExplorerRoot("cloud", "cloud", "/w/cloud"))
        compose.setContent { VerdeTheme { FilesScreen(m, "app", { r, p -> opened += r.id to p }, {}) } }
        await { fake.sent<EventWorkspaceFilesList>().size == 1 }
        fake.push("workspace_files:ws", ExplorerFilesView("ws", loaded = true, roots = roots))
        // The home root opens itself and asks the core for its listing.
        await { fake.sent<EventWorkspaceFilesList>().any { it.root == "home" && it.path == "" } }
        fake.push("workspace_files:ws", ExplorerFilesView("ws", loaded = true, roots = roots, dirs = listOf(
            ExplorerDir("home", "", listOf(ExplorerEntry("src", "src", "directory"), ExplorerEntry("a.kt", "a.kt", "file", 2048uL)), loaded = true))))
        await { compose.onAllNodesWithTag("files-entry-src").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("2 KB").assertExists()
        compose.onNodeWithTag("files-entry-src").performClick()
        await { fake.sent<EventWorkspaceFilesList>().any { it.root == "home" && it.path == "src" } }
        compose.onNodeWithTag("files-entry-a.kt").performClick()
        assertEquals(listOf("home" to "a.kt"), opened)
        compose.onNodeWithTag("files-root-cloud").performClick()
        await { fake.sent<EventWorkspaceFilesList>().any { it.root == "cloud" && it.path == "" } }
    }

    @Test fun patchLinesSelectByGutterTapAndAskHandsOffToTheChat() {
        val fake = ExplorerFake()
        fake.diff = DiffView(listOf(DiffFile("src/a.kt", "src/a.kt", false, listOf(DiffHunk(1uL, 2uL, 1uL, 3uL, listOf(
            DiffLine("context", "a", 1uL, 1uL), DiffLine("add", "b", null, 2uL), DiffLine("add", "c", null, 3uL), DiffLine("context", "d", 2uL, 4uL)))))))
        val m = model(fake)
        val workspace = Workspace("ws", "app", "/w/app", true, emptyList(), listOf(
            ThreadSummary("ws", "chat-1", "Fix build", "codex", null, null, true, false, 5L, "idle", "today")))
        var asked: Pair<String, String>? = null
        compose.setContent { VerdeTheme {
            SelectionScope(m, "host", "/w/app/src/a.kt", workspace, { ws, t -> asked = ws to t }) { PatchScreen(m, "/w/app", "src/a.kt", {}, {}) }
        } }
        fake.push("workspace_patch", ExplorerPatchView("ws", "/w/app", "src/a.kt", result = GitFilePatchResult("/w/app", "src/a.kt", additions = 2, patch = "@@ -1,2 +1,4 @@\n a\n+b\n+c\n d\n")))
        await { compose.onAllNodesWithTag(PATCH_LINE_TAG).fetchSemanticsNodes().size == 4 }
        val lines = compose.onAllNodesWithTag(PATCH_LINE_TAG)
        lines[1].performTouchInput { click(Offset(4f, centerY)) }
        lines[2].performTouchInput { click(Offset(4f, centerY)) }
        compose.onNodeWithText("Lines 2–3 (new)").assertExists()
        compose.onNodeWithTag(SELECTION_ASK_TAG).performClick()
        compose.onNodeWithTag(ASK_INSTRUCTION_TAG).performTextInput("Explain")
        compose.onNodeWithTag(ASK_SEND_TAG).performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.OnClick)
        await { asked != null }
        assertEquals("ws" to "chat-1", asked)
        val selector = Json.parseToJsonElement(fake.queries.last { "selection_prompt" in it }).jsonObject
        assertEquals("b\nc", selector["text"]!!.jsonPrimitive.content)
        assertEquals("new", selector["side"]!!.jsonPrimitive.content)
        assertEquals(fake.prompt, PromptHandoff.take("host", "ws", "chat-1"))
        assertNull(PromptHandoff.take("host", "ws", "chat-1"))
        compose.onNodeWithTag(SELECTION_BAR_TAG).assertDoesNotExist()
    }

    @Test fun longPressDragSelectsARangeWithoutScrolling() {
        val selection = LineSelection()
        compose.setContent {
            val state = rememberLazyListState()
            CompositionLocalProvider(LocalLineSelection provides selection) {
                LazyColumn(Modifier.fillMaxSize().testTag("list").lineGestures(selection, state, 2, { (it.key as? Int)?.plus(1) }) { null }, state = state) {
                    items(40, key = { it }) { Text("line $it", Modifier.height(20.dp)) }
                }
            }
        }
        compose.onNodeWithTag("list").performTouchInput {
            down(Offset(200f, 30f))
            advanceEventTime(viewConfiguration.longPressTimeoutMillis + 100)
            moveTo(Offset(200f, 90f))
            up()
        }
        compose.runOnIdle { assertEquals(2..5, selection.range) }
        // A plain text tap with no selection does nothing; a gutter tap starts one.
        compose.runOnIdle { selection.clear() }
        compose.onNodeWithTag("list").performTouchInput { click(Offset(200f, 50f)) }
        compose.runOnIdle { assertNull(selection.range) }
        compose.onNodeWithTag("list").performTouchInput { click(Offset(5f, 50f)) }
        compose.runOnIdle { assertEquals(3..3, selection.range) }
    }
}
