package dev.verdeai.app

import android.content.ClipboardManager
import android.content.Context
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.core.app.ApplicationProvider
import dev.verdeai.core.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

/**
 * D-07 diff card over real K-11 core results (fixtures/d07, provenance in README): golden row
 * projections of the core's diff/highlight output, then the card's list, hunks, copies, truncation,
 * wrap and full-screen view.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk=[35], qualifiers="w411dp-h1500dp")
class DiffCardTest {
    @get:Rule val compose = createComposeRule()

    private fun read(name: String)=DiffCardTest::class.java.getResource("/fixtures/d07/$name")!!.readText()
    private val multi by lazy { read("multi.diff") }
    private fun assertGolden(name: String, actual: String)=assertEquals(read(name).trimEnd('\n'), actual.trimEnd('\n'))

    /** Serves only recorded core replies; any query outside the recording is a test failure. */
    private class RecordedSource(entries: List<JsonObject>) : DiffRenderSource {
        private val results=entries.associate { e ->
            val q=e["query"]!!.jsonObject
            Triple(q["kind"]!!.jsonPrimitive.content, q["sha256"]!!.jsonPrimitive.content, q["language"]?.jsonPrimitive?.content) to e["result"]!!
        }
        val queries=AtomicInteger()
        val misses=CopyOnWriteArrayList<String>()
        private fun result(kind: String, text: String, language: String?=null): JsonElement? {
            queries.incrementAndGet()
            return results[Triple(kind, sha(text), language)] ?: run { misses.add("$kind/$language"); null }
        }
        override fun cachedIndex(body: String): RenderResult<DiffIndexView>? = null
        override suspend fun index(body: String)=RenderResult(result("diff_index", body)?.let { CoreJson.decodeFromJsonElement<DiffIndexQuery>(it).data })
        override fun cachedDiff(text: String): RenderResult<DiffView>? = null
        override suspend fun diff(text: String)=RenderResult(result("diff", text)?.let { CoreJson.decodeFromJsonElement<DiffQuery>(it).data })
        override fun cachedHighlight(code: String, language: String): RenderResult<List<RenderSpan>>? = null
        override suspend fun highlight(code: String, language: String)=
            RenderResult(result("highlight", code, language)?.let { CoreJson.decodeFromJsonElement<HighlightQuery>(it).data?.spans })
        companion object {
            fun sha(text: String)=MessageDigest.getInstance("SHA-256").digest(text.encodeToByteArray()).joinToString("") { "%02x".format(it) }
        }
    }

    private val source by lazy { RecordedSource(Json.parseToJsonElement(read("render.json")).jsonArray.map { it.jsonObject }) }

    private fun entries(body: String)=runBlocking { source.index(body).value!!.files }
    private fun render(body: String, path: String): DiffFileRender = runBlocking {
        val entry=entries(body).single { it.path == path }
        renderDiffFile(source, DiffBody(body).record(entry)!!, entry.path)
    }
    private fun parsed(path: String)=(render(multi, path) as DiffFileRender.Parsed).model

    @Test fun coreGoldenFixtureProjectsToUnifiedRows() {
        // The K-11 core golden (client_core/src/fixtures/render-diff.json), word spans intact.
        val core=CoreJson.decodeFromString<DiffView>(read("core-render-diff.json"))
        assertGolden("core-golden.txt", diffGolden(diffFileModel(false, core.files.single().hunks, emptyList(), emptyList())))
        // The same patch as a one-file V2 body goes through index → record → diff → highlight.
        val body=read("golden.diff")
        val model=(render(body, "x.ts") as DiffFileRender.Parsed).model
        assertGolden("x-ts.golden.txt", diffGolden(model))
        assertTrue(source.misses.isEmpty())
    }

    @Test fun multiFileGoldensUseCoreParseAndHighlightSpans() {
        val index=entries(multi)
        assertEquals(listOf("web/src/greet.ts","config/settings.json","assets/logo.png","scripts/run.sh","notes/big.txt","data/huge.txt"), index.map { it.path })
        assertEquals(4657uL to 2uL, diffTotals(index))
        // Tabs expand to the column grid; emoji and word spans map from UTF-8 bytes to UTF-16.
        assertGolden("greet-ts.golden.txt", diffGolden(parsed("web/src/greet.ts")))
        assertGolden("settings-json.golden.txt", diffGolden(parsed("config/settings.json")))
        assertTrue(parsed("assets/logo.png").binary)
        assertTrue(parsed("scripts/run.sh").hunks.isEmpty())
        assertEquals(450, parsed("notes/big.txt").lineCount)
        // Past the core's per-patch budget: the source text, never a Kotlin parse.
        val huge=render(multi, "data/huge.txt")
        assertTrue(huge is DiffFileRender.Source)
        assertTrue((huge as DiffFileRender.Source).patch.startsWith("--- /dev/null\n+++ b/data/huge.txt\n@@ -0,0 +1,4200 @@\n+generated row 00001\n"))
        assertTrue(source.misses.isEmpty())
    }

    @Test fun copiedHunksAreTheOriginalUnifiedFragments() {
        val greet=parsed("web/src/greet.ts")
        assertEquals(listOf("@@ -1,5 +1,6 @@", "@@ -20,3 +21,3 @@"), greet.hunks.map { it.header })
        val patch=entries(multi).first().let { DiffBody(multi).record(it)!!.patch }
        val second=hunkPatch(greet.hunks[1])
        assertTrue(patch.endsWith(second))
        assertEquals("@@ -1,5 +1,6 @@\n import { name } from './name';\n-export function greet(who: string) {\n+export function greet(who: string, loud = false) {\n \tconst text = `hello \${who} 😀`;\n+\tif (loud) return text.toUpperCase();\n \treturn text;\n }\n",
            hunkPatch(greet.hunks[0]))
    }

    private fun clip()=ApplicationProvider.getApplicationContext<Context>().getSystemService(ClipboardManager::class.java)
        .primaryClip?.getItemAt(0)?.text?.toString()
    private fun launch(body: String) {
        compose.setContent { MaterialTheme { DiffCard("row-1", body, source) } }
        compose.waitUntil(5000) { compose.onAllNodesWithText("Changed files ·", substring=true).fetchSemanticsNodes().isNotEmpty() }
    }
    private fun exists(text: String, substring: Boolean=false)=
        compose.onAllNodesWithText(text, substring=substring, useUnmergedTree=true).fetchSemanticsNodes().isNotEmpty()
    private fun awaitText(text: String, substring: Boolean=false)=compose.waitUntil(5000) { exists(text, substring) }

    @Test fun cardListsFilesExpandsHunksAndCopies() {
        launch(multi)
        compose.onNodeWithText("Changed files · 6").assertExists()
        compose.onNodeWithText("+4657 −2", useUnmergedTree=true).assertExists()
        compose.onNodeWithText("+3 −2", useUnmergedTree=true).assertExists()
        // Multi-file cards start collapsed; nothing is parsed until a file opens.
        assertFalse(exists("@@ -1,5 +1,6 @@"))
        val before=source.queries.get()
        assertEquals(1, before)
        compose.onNodeWithText("web/src/greet.ts").performClick()
        awaitText("@@ -1,5 +1,6 @@")
        awaitText("export function greet(who: string, loud = false) {", substring=true)
        compose.onAllNodesWithTag(DIFF_LINES, useUnmergedTree=true).assertCountEquals(2)
        // Copy path / hunk put exactly that on the clipboard.
        compose.onNodeWithText("Copy path").performClick()
        assertEquals("web/src/greet.ts", clip())
        compose.onAllNodesWithText("Copy hunk")[1].performClick()
        assertEquals("@@ -20,3 +21,3 @@\n /* greeting table */\n-const table = { en: 'hello', fr: 'bonjour' };\n+const table = { en: 'hello', fr: 'salut' };\n export default table;\n\\ No newline at end of file\n", clip())
        compose.onNodeWithText("Copy patch").performClick()
        assertTrue(clip()!!.startsWith("--- a/web/src/greet.ts\n"))
        // Hunks collapse individually.
        compose.onNodeWithText("@@ -20,3 +21,3 @@").performClick()
        compose.waitUntil(5000) { !exists("fr: 'salut'", substring=true) }
        assertTrue(exists("loud = false", substring=true))
        // Binary and mode-only files say so instead of rendering lines.
        compose.onNodeWithText("assets/logo.png").performClick()
        awaitText("Binary file — not shown.")
        compose.onNodeWithText("scripts/run.sh").performClick()
        awaitText("No line changes.")
        assertTrue(source.misses.isEmpty())
    }

    @Test fun bigFilesTruncateWithShowMoreAndHugeOnesFallBackToSource() {
        launch(multi)
        compose.onNodeWithText("notes/big.txt").performClick()
        awaitText("Show more lines · 250 remaining")
        assertTrue(exists("note line 200", substring=true))
        assertFalse(exists("note line 201", substring=true))
        // Below the fold of the test window: invoke the button's click action directly.
        compose.onNodeWithText("Show more lines · 250 remaining").performSemanticsAction(SemanticsActions.OnClick)
        compose.waitUntil(5000) { exists("note line 450", substring=true) }
        assertFalse(exists("remaining", substring=true))
        // Rows are laid out in bounded 80-row chunks, not one text per 450-line hunk.
        assertEquals(6, compose.onAllNodesWithText("note line", substring=true, useUnmergedTree=true).fetchSemanticsNodes().size)
        compose.onNodeWithText("notes/big.txt").performClick()
        compose.onNodeWithText("data/huge.txt").performClick()
        awaitText("showing the patch text", substring=true)
        // The first 200 source lines: three header lines, then rows 1-197.
        assertTrue(exists("+generated row 00197", substring=true))
        assertFalse(exists("+generated row 00198", substring=true))
        compose.onNodeWithText("Show more lines").performSemanticsAction(SemanticsActions.OnClick)
        compose.waitUntil(5000) { exists("+generated row 00597", substring=true) }
        assertTrue(source.misses.isEmpty())
    }

    @Test fun wrapToggleAndFullScreenView() {
        launch(read("golden.diff"))
        // A one-file diff opens straight away.
        awaitText("const a = 2;", substring=true)
        compose.onNodeWithText("Wrap lines").performClick()
        compose.onNodeWithText("Wrap lines").assertIsSelected()
        compose.onNodeWithText("Full screen").performClick()
        compose.waitUntil(5000) { compose.onAllNodesWithTag(DIFF_FULL_SCREEN).fetchSemanticsNodes().isNotEmpty() }
        compose.onAllNodesWithText("@@ -1,1 +1,1 @@").assertCountEquals(2)
        compose.onNodeWithContentDescription("Close diff").performClick()
        compose.waitUntil(5000) { compose.onAllNodesWithTag(DIFF_FULL_SCREEN).fetchSemanticsNodes().isEmpty() }
    }

    @Test fun undecodableBodyShowsAnError() {
        compose.setContent { MaterialTheme { DiffCard("row-2", "VERDE_DIFF_V2\nFILE\tbroken", source) } }
        compose.waitUntil(5000) { exists("This diff couldn't be decoded on the phone.") }
        compose.onNodeWithText("Changed files").assertExists()
    }
}
