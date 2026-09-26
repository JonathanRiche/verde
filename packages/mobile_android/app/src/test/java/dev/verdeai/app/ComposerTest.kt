package dev.verdeai.app

import android.os.Looper
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import dev.verdeai.core.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
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

/** Pure composer parsing, mirroring the web client's composer_commands.ts / followups.ts. */
class ComposerParsingTest {
    @Test fun tokensFollowTheCaretLikeTheWebComposer() {
        assertEquals(ComposerToken(4, 13, "src/m"), fileMentionAtCaret("see @src/main now", 10))
        assertNull(fileMentionAtCaret("mail a@b", 3))
        assertNull(fileMentionAtCaret("@x", 0))
        assertEquals(ComposerToken(1, 5, "co"), slashTokenAtCaret(" /com args", 4))
        assertNull(slashTokenAtCaret("//literal", 3))
        assertNull(slashTokenAtCaret("/com args", 7))
    }

    @Test fun acceptingSuggestionsValidatesAndSpaces() {
        val v = TextFieldValue("look at @src", TextRange(12))
        assertEquals(TextFieldValue("look at @src/main.zig ", TextRange(22)), acceptFileMention(v, "src/main.zig"))
        for (bad in listOf("", "/etc/passwd", "../x", "a//b", "C:/x", "a\\b", "a\nb")) assertNull(bad, acceptFileMention(v, bad))
        assertEquals(TextFieldValue("/compact ", TextRange(9)), acceptSlashCommand(TextFieldValue("/co", TextRange(3)), "/compact"))
        assertNull(acceptSlashCommand(TextFieldValue("/co", TextRange(3)), "//x"))
    }

    @Test fun actionsAndFollowupKindsMatchTheDesktop() {
        assertEquals(ComposerAction.Shell, composerAction("!ls -la"))
        assertEquals(ComposerAction.Prompt, composerAction("!!not a command"))
        assertEquals(ComposerAction.Slash("/review", "main  branch"), composerAction("  /review main  branch "))
        assertEquals(ComposerAction.Literal("/path is literal"), composerAction("//path is literal"))
        assertEquals(ComposerAction.Prompt, composerAction("hello /there"))
        assertEquals(EventFollowupSubmitKind.steer, followupKind("claude", images=false))
        assertEquals(EventFollowupSubmitKind.queue, followupKind("claude", images=true))
        assertEquals(EventFollowupSubmitKind.queue, followupKind("cursor", images=false))
        assertEquals("Queue", sendLabel("hi", running=true, EventFollowupSubmitKind.queue))
        assertEquals("Run", sendLabel("/compact", running=true, EventFollowupSubmitKind.steer))
    }
}

/**
 * D-08 composer in the transcript's bottom bar over a fake core. The fake applies the core's
 * composer rules (revision-checked send, `!` confirmation, follow-ups, reference-kept attachments)
 * to a composer projection derived from the D-06 recorded fixtures; the rules themselves are
 * covered by the Zig chat tests.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk=[29,35], qualifiers="w411dp-h1500dp")
class ComposerTest {
    @get:Rule val compose = createComposeRule()
    private val models = ViewModelStore()
    /** The screen's own store, so leaving it can be tested while the hosts model lives on. */
    private val screens = ViewModelStore()
    private lateinit var hosts: HostsModel
    private lateinit var browse: BrowseModel
    private lateinit var transcript: TranscriptModel
    private val store = Store()
    private val signals = FakeSignals()
    private val cores = CopyOnWriteArrayList<ComposerCore>()
    private var setup: (ComposerCore) -> Unit = {}
    private val core get() = cores.single()

    private fun pump() = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(20))
    private fun await(condition: () -> Boolean) = compose.waitUntil(5000) { pump(); condition() }
    private fun exists(text: String, substring: Boolean = false) =
        compose.onAllNodesWithText(text, substring=substring, useUnmergedTree=true).fetchSemanticsNodes().isNotEmpty()
    private fun awaitText(text: String, substring: Boolean = false) = await { exists(text, substring) }
    private inline fun <reified T : Event> sent() = core.events.filterIsInstance<T>()
    private fun field() = compose.onNodeWithTag(COMPOSER_FIELD)
    private fun send() = compose.onNodeWithTag(COMPOSER_SEND)
    /** Sheets animate in on a paused Robolectric clock, so taps inside them go through the click action. */
    private fun SemanticsNodeInteraction.tap() = performSemanticsAction(SemanticsActions.OnClick)

    private fun launch() {
        store.values[HostsModel.CATALOG_KEY]=CoreJson.encodeToString(HostCatalog(listOf(SavedHost("alpha","Studio")), "alpha"))
        compose.runOnUiThread {
            val factory=object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T = when (modelClass) {
                    HostsModel::class.java -> HostsModel(store, signals) { saved ->
                        val fake=ComposerCore(saved).also(setup).also(cores::add)
                        CoreHost.create(dev.verdeai.core.Config(1,saved.id,saved.label,null,null,1,"",0uL), EffectExecutor(store,saved.id), fake)
                    }
                    BrowseModel::class.java -> BrowseModel(hosts, null, signals, wallClock={ NOW })
                    else -> TranscriptModel(hosts, browse.state, WS, THREAD, unfocusDelayMs=50)
                } as T
            }
            val provider=ViewModelProvider(models, factory)
            hosts=provider[HostsModel::class.java]
            browse=provider[BrowseModel::class.java]
            transcript=ViewModelProvider(screens, factory)[TranscriptModel::class.java]
        }
        compose.setContent {
            MaterialTheme {
                CompositionLocalProvider(LocalUiClock provides UiClock(now={ NOW }, ticking=false)) {
                    TranscriptScreen(transcript, "Chat fixture", onBack={}, onHosts={}, onRetryConnection=browse::refresh,
                        bottomBar={ m, s -> ChatComposer(m, s) })
                }
            }
        }
        await { transcript.state.value.composer != null }
    }

    private fun type(text: String) {
        field().performTextInput(text)
        // The draft debounce is 600 ms of main-looper time.
        await { sent<EventDraftSet>().lastOrNull()?.text == transcript.composer.field.text }
    }

    @After fun cleanup() {
        compose.runOnUiThread { screens.clear(); models.clear() }
        await { cores.all { it.freed } }
        FocusClaim.owner=null
    }

    @Test fun typingIsBatchedIntoOneDraftAndSendUsesItsRevision() {
        launch()
        field().performTextInput("Fix the ")
        field().performTextInput("build")
        await { sent<EventDraftSet>().isNotEmpty() }
        repeat(40) { pump() }
        // Two edits inside the debounce spend one receipt.
        assertEquals(listOf("Fix the build"), sent<EventDraftSet>().map { it.text })
        send().assertTextEquals("Send").performClick()
        await { sent<EventSend>().isNotEmpty() }
        assertEquals(core.revisionAtSend, sent<EventSend>().single().draft_revision)
        // The core cleared the committed draft; the field follows it.
        await { transcript.composer.field.text.isEmpty() }
        assertEquals(1, sent<EventDraftSet>().size)
    }

    @Test fun aNewlyCreatedChatTakesItsFirstMessage() {
        // D-10's New chat opens an empty, uncommitted thread; the composer must work there.
        setup={ it.fresh() }
        launch()
        awaitText("No messages yet.")
        compose.onNodeWithContentDescription("Provider: Codex. Change").assertExists()
        type("hello")
        send().assertTextEquals("Send").assertIsEnabled().performClick()
        await { sent<EventSend>().isNotEmpty() }
        assertEquals(core.revisionAtSend, sent<EventSend>().single().draft_revision)
    }

    @Test fun leavingTheScreenSavesAnUnsentEdit() {
        launch()
        field().performTextInput("half a thought")
        compose.runOnUiThread { screens.clear() }
        await { sent<EventDraftSet>().any { it.text == "half a thought" } }
    }

    @Test fun whileRunningItSteersAndTheFollowupCanBePulledBackOrRemoved() {
        setup={ it.running() }
        launch()
        awaitText("Send to steer the current reply.")
        type("also add tests")
        send().assertTextEquals("Steer").performClick()
        await { sent<EventFollowupSubmit>().isNotEmpty() }
        assertEquals(EventFollowupSubmitKind.steer, sent<EventFollowupSubmit>().single().kind)
        awaitText("Steer follow-up")
        compose.onNodeWithTag(COMPOSER_FOLLOWUP).assertExists()
        assertTrue(exists("Not sent"))
        await { transcript.composer.field.text.isEmpty() }
        // One follow-up at a time, like the desktop.
        type("more")
        send().assertIsNotEnabled()
        compose.onNodeWithText("Pull back to edit").performClick()
        await { sent<EventFollowupPullBack>().isNotEmpty() }
        // Unsaved text is kept: the core appends the pulled-back follow-up to the draft.
        await { transcript.composer.field.text == "more\n\nalso add tests" }
        compose.onNodeWithTag(COMPOSER_FOLLOWUP).assertDoesNotExist()
        send().performClick()
        await { sent<EventFollowupSubmit>().size == 2 }
        awaitText("Remove")
        compose.onNodeWithText("Remove").performClick()
        await { sent<EventFollowupCancel>().isNotEmpty() }
        await { !exists("Steer follow-up") }
        // Stop is part of the composer while a turn runs.
        compose.onNodeWithTag(COMPOSER_STOP).assertTextEquals("Stop").performClick()
        await { sent<EventTurnCancel>().isNotEmpty() }
        assertEquals("fixture-turn", sent<EventTurnCancel>().single().turn_id)
    }

    @Test fun bangCommandsNeedConfirmationBeforeRunning() {
        launch()
        type("!ls -la")
        send().assertTextEquals("Run").performClick()
        await { sent<EventSend>().isNotEmpty() }
        await { exists("Run this command on the host?") }
        assertTrue(exists("ls -la"))
        compose.onAllNodes(hasText("Run") and hasClickAction()).filterToOne(hasAnyAncestor(hasTestTag(COMPOSER_SHELL))).tap()
        await { sent<EventShellConfirm>().isNotEmpty() }
        assertTrue(sent<EventShellConfirm>().single().accept)
        // A confirmed command clears the draft it came from.
        await { sent<EventDraftSet>().lastOrNull()?.text == "" }
        await { transcript.composer.field.text.isEmpty() }
        await { !exists("Run this command on the host?") }
    }

    @Test fun slashCommandsAndFileMentionsComeFromTheCore() {
        launch()
        field().performTextInput("/co")
        await { sent<EventSlashSearch>().isNotEmpty() }
        await { exists("/compact") }
        // Disabled commands are not offered.
        assertFalse(exists("/review"))
        compose.onNode(hasText("/compact") and hasAnyAncestor(hasTestTag(COMPOSER_SUGGESTIONS))).performClick()
        await { transcript.composer.field.text == "/compact " }
        send().assertTextEquals("Run").performClick()
        await { sent<EventSlashRun>().isNotEmpty() }
        assertEquals("compact", sent<EventSlashRun>().single().command)
        assertEquals("", sent<EventSlashRun>().single().args)
        await { transcript.composer.field.text.isEmpty() }
        assertTrue(sent<EventSend>().isEmpty())

        field().performTextInput("open @src")
        await { sent<EventMentionSearch>().any { it.query == "src" } }
        await { exists("src/main.zig") }
        compose.onNodeWithText("src/main.zig").performClick()
        await { transcript.composer.field.text == "open @src/main.zig " }
        // Unknown commands never reach the host.
        compose.runOnUiThread { transcript.composer.edit(TextFieldValue("/nope now", TextRange(9))) }
        send().performClick()
        awaitText("Unknown command /nope.")
        assertEquals(1, sent<EventSlashRun>().size)
    }

    @Test fun pickersSelectFromTheCoreCatalogsWithFavouritesFirst() {
        setup={ it.fresh() }
        launch()
        compose.onNodeWithContentDescription("Model: GPT-6 Astra. Change").performClick()
        awaitText("Model")
        // The desktop's favourite is starred and listed first.
        assertTrue(compose.onAllNodesWithContentDescription("Favourite", useUnmergedTree=true).fetchSemanticsNodes().isNotEmpty())
        val sol=compose.onNodeWithText("GPT-6 Sol").fetchSemanticsNode().boundsInRoot.top
        val astra=compose.onAllNodes(hasText("GPT-6 Astra") and hasAnyAncestor(hasTestTag(COMPOSER_PICKER))).onFirst().fetchSemanticsNode().boundsInRoot.top
        assertTrue(sol < astra)
        compose.onNodeWithText("GPT-6 Luna").tap()
        await { sent<EventComposerSelect>().isNotEmpty() }
        val select=sent<EventComposerSelect>().single()
        assertEquals("gpt-6-luna", select.model); assertEquals("codex", select.provider); assertEquals("full_access", select.access)
        await { exists("GPT-6 Luna") }
        // Provider is only switchable before the conversation starts.
        compose.onNodeWithContentDescription("Provider: Codex. Change").performClick()
        compose.onNodeWithText("Claude").tap()
        await { sent<EventComposerSelect>().size == 2 }
        val provider=sent<EventComposerSelect>()[1]
        assertEquals("claude", provider.provider); assertNull(provider.model); assertNull(provider.effort)
    }

    @Test fun imagesUploadOnceThenStayByReferenceAndLimitsAreRecoverable() {
        launch()
        val image=PickedImage("photo.jpg", "image/jpeg", ByteArray(2048) { it.toByte() })
        compose.runOnUiThread { transcript.composer.attach(listOf(image)) }
        await { exists("photo.jpg", substring=true) }
        val first=sent<EventDraftSet>().single().attachments.single()
        assertEquals("2048", first.byte_size); assertTrue(first.bytes_base64.isNotEmpty())
        type("look")
        // Later draft saves keep the image by reference; the bytes are never re-sent.
        assertEquals(first.local_id, sent<EventDraftSet>().last().attachments.single().local_id)
        assertEquals("", sent<EventDraftSet>().last().attachments.single().bytes_base64)
        // A core resource limit is a rejected intent, not a dead host.
        core.rejectNext=5
        compose.runOnUiThread { transcript.composer.attach(listOf(image)) }
        await { exists("too large to keep", substring=true) }
        assertFalse(transcript.state.value.fatal)
        compose.onNodeWithContentDescription("Remove photo.jpg").performClick()
        await { transcript.state.value.composer?.draft?.attachments?.isEmpty() == true }
        assertTrue(sent<EventDraftSet>().last().attachments.isEmpty())
        compose.onNodeWithTag(COMPOSER_ATTACH).assertIsEnabled()
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

    /** Host/sync as in TranscriptTest, plus the composer intents with the core's semantics. */
    private class ComposerCore(val saved: SavedHost) : CoreBridge {
        val events=CopyOnWriteArrayList<Event>()
        @Volatile var freed=false
        @Volatile var rejectNext: Int?=null
        @Volatile var revisionAtSend: String?=null
        private val operations=ConcurrentHashMap<String, Operation>()
        private var thread: ThreadQuery=decode("thread-open")
        private var view: ChatComposerView=decode<ComposerQuery>("composer-idle").data!!
        private var ensured=false
        private var sequence=0
        private var row=HostView(saved.id,saved.label,null,null,null,"idle",Lifecycle.background,"paired","empty",
            emptyList(),emptyList(),null,null,false,null)

        fun running() {
            thread=decode("thread-running")
            view=view.copy(can_send=false, can_stop=true)
        }
        fun fresh() {
            thread=thread.copy(data=thread.data!!.copy(rows=emptyList()))
            view=view.copy(catalogs=view.catalogs.copy(models=view.catalogs.models.map { if (it.id == "gpt-6-sol") it.copy(favorite=true) else it }))
        }

        private fun draft(text: String, attachments: List<ChatAttachment> = view.draft.attachments) {
            view=view.copy(draft=ChatDraft((view.draft.revision.toLong() + 1).toString(), text, attachments, false))
        }

        override fun create(config: ByteArray)=1L
        override fun handle(host: Long, event: ByteArray): ByteArray {
            val decoded=CoreJson.decodeFromString<Event>(event.decodeToString())
            rejectNext?.let { if (decoded is EventDraftSet) { rejectNext=null; throw CoreFailure(it) } }
            events.add(decoded)
            val effects=mutableListOf<Effect>()
            fun op(id: String, state: String, code: String?=null) { operations[id]=Operation(id, state, code?.let { LocalError(code=it, message="") }) }
            when (decoded) {
                is EventForeground -> if (row.lifecycle != Lifecycle.foreground) {
                    row=row.copy(lifecycle=Lifecycle.foreground, phase="connecting", sync_state="loading")
                    effects.add(EffectSetTimer("t${sequence++}","1","sync",10,"test"))
                }
                is EventTimerFired -> if (decoded.timer_id == "sync") row=row.copy(phase="ready", sync_state="ready")
                is EventFocus -> { if (decoded.thread_id != null) ensured=true; op(decoded.intent_id, "succeeded") }
                is EventDraftSet -> {
                    val old=view.draft.attachments
                    draft(decoded.text, decoded.attachments.map { a ->
                        if (a.bytes_base64.isEmpty()) old.single { it.local_id == a.local_id && it.byte_size == a.byte_size }
                        else ChatAttachment(a.local_id, a.name, a.mime, a.byte_size)
                    })
                    op(decoded.intent_id, "succeeded")
                }
                is EventSend -> when {
                    decoded.draft_revision != view.draft.revision -> op(decoded.intent_id, "failed", "draft_unavailable")
                    view.draft.text.startsWith("!") -> {
                        view=view.copy(shell_confirmation=ChatShellConfirmation("confirm-1", view.draft.text.drop(1).trim(), "/repo"))
                        op(decoded.intent_id, "succeeded")
                    }
                    else -> {
                        revisionAtSend=decoded.draft_revision
                        op(decoded.intent_id, "succeeded")
                        draft("", emptyList())
                        view=view.copy(send_operation=operations[decoded.intent_id])
                    }
                }
                is EventFollowupSubmit -> if (view.followup != null) op(decoded.intent_id, "failed", "followup_unavailable") else {
                    view=view.copy(followup=ChatFollowup("f-${sequence++}", decoded.kind.name, turn_id="fixture-turn", steer_id="s", next_turn_id="n",
                        text=view.draft.text, attachments=view.draft.attachments, can_retry=true))
                    draft("", emptyList())
                    op(decoded.intent_id, "pending")
                }
                is EventFollowupPullBack -> {
                    // Like the core: pulled-back text is appended to whatever the draft holds.
                    val f=view.followup!!
                    draft(if (view.draft.text.isEmpty()) f.text else view.draft.text + "\n\n" + f.text, view.draft.attachments + f.attachments)
                    view=view.copy(followup=null); op(decoded.intent_id, "succeeded")
                }
                is EventFollowupCancel -> { view=view.copy(followup=null); op(decoded.intent_id, "succeeded") }
                is EventShellConfirm -> { view=view.copy(shell_confirmation=null); op(decoded.intent_id, if (decoded.accept) "pending" else "succeeded") }
                is EventSlashSearch -> {
                    view=view.copy(catalogs=view.catalogs.copy(slash=listOf(ChatChoice("compact","/compact"), ChatChoice("review","/review", enabled=false, reason="unsupported"))))
                    op(decoded.intent_id, "succeeded")
                }
                is EventSlashRun -> { op(decoded.intent_id, "pending"); effects.add(EffectSetTimer("t${sequence++}","1","slash:${decoded.intent_id}",10,"test")) }
                is EventMentionSearch -> {
                    view=view.copy(mentions=if (decoded.query == "src") listOf(ChatMention("src/main.zig","main.zig")) else emptyList())
                    op(decoded.intent_id, "succeeded")
                }
                is EventComposerSelect -> {
                    val provider=decoded.provider ?: view.selection.provider
                    view=view.copy(selection=ChatSelection(provider, decoded.model, decoded.effort, decoded.access, decoded.speed))
                    draft(view.draft.text)
                    op(decoded.intent_id, "succeeded")
                }
                is EventTurnCancel -> op(decoded.intent_id, "pending")
                else -> Unit
            }
            if (decoded is EventTimerFired && decoded.timer_id.startsWith("slash:")) op(decoded.timer_id.removePrefix("slash:"), "succeeded")
            val scopes=mutableListOf("hosts","home","workspaces")
            if (ensured) scopes+=listOf(chatSelector("thread", WS, THREAD), chatSelector("composer", WS, THREAD))
            effects.add(EffectStateChanged("s${sequence++}","1","1",scopes))
            return CoreJson.encodeToString(EffectBatch(1,"1",effects)).encodeToByteArray()
        }
        override fun query(host: Long, selector: String): ByteArray = when {
            selector == "hosts" -> CoreJson.encodeToString(HostsQuery(1,"1",HostsView(listOf(row),operations.values.toList()),null))
            selector == "home" -> CoreJson.encodeToString(HomeQuery(1,"1",HomeView(emptyList(),false,false,emptyList(),null),null))
            selector == "workspaces" -> CoreJson.encodeToString(WorkspacesQuery(1,"1",WorkspacesView(emptyList(),false,false,null,
                HistoryView("",emptyList(),null,false,null)),null))
            selector.startsWith("thread:") -> CoreJson.encodeToString(thread)
            selector.startsWith("composer:") -> CoreJson.encodeToString(ComposerQuery(1,"1",view,null))
            else -> """{"api_version":1,"revision":"1","data":null,"error":{"domain":"input","code":"not_found","message":"Unknown."}}"""
        }.encodeToByteArray()
        override fun free(host: Long) { freed=true }

        companion object {
            inline fun <reified T> decode(name: String): T =
                CoreJson.decodeFromString(ComposerTest::class.java.getResource("/fixtures/d06/$name.json")!!.readText())
        }
    }

    companion object {
        const val WS="chat-fixture-ws"
        const val THREAD="chat-fixture-thread"
        const val NOW=1_790_363_190_811L + 65_000
    }
}
