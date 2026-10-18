package dev.verdeai.app

import android.os.Looper
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import dev.verdeai.core.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.time.Duration
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * D-12 viewer over a fake core: `file_open` settles a receipt and the body lands in the executor's
 * in-memory [FileSink], exactly where the real `file_fetch` puts it (covered in CoreHostTest).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk=[35], qualifiers="w411dp-h900dp")
class FileViewerTest {
    @get:Rule val compose = createComposeRule()
    private val models = ViewModelStore()
    private val store = Store()
    private val signals = FakeSignals()
    private val sink = FileSink()
    private val cores = CopyOnWriteArrayList<FileCore>()
    /** Host-side files and failure codes by path, shared with the fake core. */
    private val files = ConcurrentHashMap<String, ByteArray>()
    private val failures = ConcurrentHashMap<String, String>()
    private val core get() = cores.single()
    private lateinit var hosts: HostsModel
    private val citations = CopyOnWriteArrayList<FileCitation>()
    private var current by mutableStateOf<Pair<FileViewerModel, LineTarget?>?>(null)

    private fun pump() = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(20))
    private fun await(condition: () -> Boolean) = compose.waitUntil(5000) { pump(); condition() }
    private fun exists(text: String, substring: Boolean = false) =
        compose.onAllNodesWithText(text, substring=substring, useUnmergedTree=true).fetchSemanticsNodes().isNotEmpty()

    private fun start() {
        store.values[HostsModel.CATALOG_KEY]=CoreJson.encodeToString(HostCatalog(listOf(SavedHost("alpha","Studio")), "alpha"))
        compose.runOnUiThread {
            hosts=ViewModelProvider(models, object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T = HostsModel(store, signals) { saved ->
                    val fake=FileCore(saved, sink, files, failures).also(cores::add)
                    CoreHost.create(dev.verdeai.core.Config(1,saved.id,saved.label,null,null,1,"",0uL), EffectExecutor(store,saved.id,files=sink), fake)
                } as T
            })[HostsModel::class.java]
        }
        compose.setContent {
            MaterialTheme {
                current?.let { (model, target) -> FileViewerScreen(model, target, onCitation={ citations.add(it) }, onBack={}) }
            }
        }
    }

    private fun open(path: String?, target: LineTarget? = null, decoders: FileDecoders = FakeDecoders,
                     owner: ViewModelStore = models, waitMs: Long = FileViewerModel.WAIT_MS): FileViewerModel {
        lateinit var model: FileViewerModel
        compose.runOnUiThread {
            model=ViewModelProvider(owner, object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T = FileViewerModel(hosts, "alpha", path, decoders, waitMs) as T
            })["file-${opened++}", FileViewerModel::class.java]
            current=model to target
        }
        return model
    }
    private var opened=0

    @After fun cleanup() {
        compose.runOnUiThread { models.clear() }
        await { cores.all { it.freed } }
    }

    @Test fun signingOutDropsTheOpenDocument() {
        start()
        files["/home/u/notes.txt"]="secret notes\n".encodeToByteArray()
        val model=open("/home/u/notes.txt")
        await { exists("secret notes") }
        core.auth="signed_out"
        compose.runOnIdle { signals.network.value=NetworkState(true, "net-2") }
        await { model.state.value.content == null && model.state.value.problem == FileProblem.Unavailable }
        await { !exists("secret notes") }
        assertEquals(0, sink.size())
    }

    @Test fun pathsKindsAndLinesAreParsedConservatively() {
        assertEquals(ViewerKind.Markdown, viewerKind("/a/README.MD"))
        assertEquals(ViewerKind.Image, viewerKind("/a/b.JPeG"))
        assertEquals(ViewerKind.Pdf, viewerKind("/a/b.pdf"))
        assertEquals(ViewerKind.Office, viewerKind("/a/b.docx"))
        assertEquals(ViewerKind.Text, viewerKind("/a/Makefile"))
        assertEquals(ViewerKind.Text, viewerKind("/a/.env"))
        assertEquals(ViewerKind.Svg, viewerKind("/a/b.SVG"))
        assertEquals(FileKind.download, viewerFetchKind("/a/b.svg"))
        assertEquals(FileKind.download, viewerFetchKind("/a/index.htm"))
        assertEquals(FileKind.preview, viewerFetchKind("/a/b.docx"))
        assertEquals(FileKind.file, viewerFetchKind("/a/b.ts"))
        assertEquals(MAX_TEXT_BYTES, viewerLimit(ViewerKind.Markdown))
        assertEquals(MAX_DOCUMENT_BYTES, viewerLimit(ViewerKind.Office))

        assertEquals("/w/src/a.ts", resolveFilePath("src/a.ts", "/w/"))
        assertEquals("/w/src/a.ts", resolveFilePath("./src/a.ts", "/w"))
        assertEquals("/abs/a.ts", resolveFilePath("/abs/a.ts", null))
        assertNull(resolveFilePath("src/a.ts", null))
        assertNull(resolveFilePath("src/a.ts", "relative-root"))
        assertNull(resolveFilePath("  ", "/w"))

        assertEquals(LineTarget(10, 20), LineTarget.of(10, 20))
        assertEquals(LineTarget(10, null), LineTarget.of(10, 5))
        assertNull(LineTarget.of(0, null))
        assertNull(LineTarget.of(null, 4))
        assertTrue(12 in LineTarget(10, 20) && 21 !in LineTarget(10, 20) && 10 in LineTarget(10))

        val text="a\r\nbb\n\nlast"
        val starts=lineStarts(text)
        assertArrayEquals(intArrayOf(0, 3, 6, 7), starts)
        assertEquals(listOf("a", "bb", "", "last"), starts.indices.map { text.substring(starts[it], lineEnd(text, starts, it)) })
        assertArrayEquals(intArrayOf(0), lineStarts(""))
        assertEquals("x", decodeText(byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte(), 'x'.code.toByte())))
        assertNull(decodeText(byteArrayOf('a'.code.toByte(), 0)))

        // The route keeps the whole path in one segment; D-06 ranges survive the trip.
        assertEquals("file/ws%201/10/12/%2Fw%2Fa%20b.md", Routes.file("ws 1", FileCitation("/w/a b.md", 10uL, 12uL)))
        assertEquals("file/ws/0/0/src%2Fa.ts", Routes.file("ws", FileCitation("src/a.ts")))
    }

    // Robolectric can't create Compose's color-space bitmaps; a plain Bitmap is enough here.
    private companion object {
        fun bitmap(w: Int, h: Int) = android.graphics.Bitmap.createBitmap(w, h, android.graphics.Bitmap.Config.ARGB_8888).asImageBitmap()
    }

    private object FakeDecoders : FileDecoders {
        override fun image(bytes: ByteArray): ImageBitmap? = bitmap(4, 3)
        override fun pdf(bytes: ByteArray): PdfDocument? = FakePdf()
    }

    private class FakePdf : PdfDocument {
        @Volatile var closed=false
        override val pageCount=2
        override fun aspect(index: Int)=0.75f
        override suspend fun render(index: Int, widthPx: Int): ImageBitmap? = if (closed) null else bitmap(8, 8)
        override fun close() { closed=true }
    }

    private class FakeSignals : AppSignals {
        override val foreground=MutableStateFlow(true)
        override val network=MutableStateFlow(NetworkState(true, "net-1"))
    }

    private class Store : SecureStore {
        val values=ConcurrentHashMap<String,String>()
        override suspend fun get(key: String): String? = values[key]
        override suspend fun put(key: String, value: String) { values[key]=value }
        override suspend fun delete(key: String) { values.remove(key) }
    }

    /** Settles `file_open` at once: a failure code, or success with the body in the sink. */
    private class FileCore(val saved: SavedHost, val sink: FileSink, val files: Map<String, ByteArray>,
                           val failures: Map<String, String>) : CoreBridge {
        val events=CopyOnWriteArrayList<Event>()
        val highlightLanguages=CopyOnWriteArrayList<String>()
        private val operations=ConcurrentHashMap<String, Operation>()
        @Volatile var auth="paired"
        @Volatile var lifecycle=Lifecycle.foreground
        @Volatile var freed=false
        private var sequence=0
        override fun create(config: ByteArray)=1L
        override fun handle(host: Long, event: ByteArray): ByteArray {
            val decoded=CoreJson.decodeFromString<Event>(event.decodeToString())
            events.add(decoded)
            if (decoded is EventBackground) lifecycle=Lifecycle.background
            if (decoded is EventForeground) lifecycle=Lifecycle.foreground
            if (decoded is EventFileOpen) {
                val failure=if (lifecycle != Lifecycle.foreground) "cancelled" else failures[decoded.path]
                val body=files[decoded.path]
                operations[decoded.intent_id]=when {
                    failure != null -> Operation(decoded.intent_id, "failed",
                        LocalError(domain="file", code=failure, message="", retryable=failure in setOf("offline", "timeout", "cancelled", "busy", "server_unavailable", "unauthorized")))
                    body == null -> Operation(decoded.intent_id, "failed", LocalError(domain="file", code="not_found", message=""))
                    else -> { sink.put(decoded.intent_id, FileBody(body, null)); Operation(decoded.intent_id, "succeeded", null) }
                }
            }
            val effects=listOf<Effect>(EffectStateChanged("s${sequence++}","1","1",listOf("hosts","operations","home","workspaces")))
            return CoreJson.encodeToString(EffectBatch(1,"1",effects)).encodeToByteArray()
        }
        override fun query(host: Long, selector: String): ByteArray = when {
            selector == "hosts" -> CoreJson.encodeToString(HostsQuery(1,"1",HostsView(listOf(HostView(saved.id,saved.label,null,null,null,
                "ready",lifecycle,auth,"ready",emptyList(),emptyList(),null,null,false,null)),operations.values.toList()),null))
            selector == "operations" -> CoreJson.encodeToString(OperationsQuery(1,"1",OperationsView(operations.values.toList()),null))
            selector.startsWith("{") -> utility(Json.parseToJsonElement(selector).jsonObject)
            else -> """{"api_version":1,"revision":"1","data":null,"error":{"domain":"input","code":"not_found","message":""}}"""
        }.encodeToByteArray()
        private fun utility(q: JsonObject): String {
            val text=q["text"]!!.jsonPrimitive.content
            val bytes=text.encodeToByteArray().size
            val data=when (q["utility"]!!.jsonPrimitive.content) {
                "highlight" -> {
                    highlightLanguages.add(q["language"]!!.jsonPrimitive.content)
                    """{"spans":[{"start":0,"end":5,"kind":"keyword"}]}"""
                }
                // "# Guide\n\nSee main.\n": a heading and a paragraph, as the core's AST shapes them.
                else -> """{"nodes":[{"kind":"document","start":0,"end":$bytes,"children":[
                    {"kind":"heading","start":0,"end":7,"level":1,"children":[{"kind":"text","start":2,"end":7,"text":"Guide","children":[]}]},
                    {"kind":"paragraph","start":9,"end":18,"children":[{"kind":"text","start":9,"end":18,"text":"See main.","children":[]}]}]}]}"""
            }
            return """{"api_version":1,"revision":"1","data":$data,"error":null}"""
        }
        override fun free(host: Long) { freed=true }
    }
}
