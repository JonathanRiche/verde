package dev.verdeai.app

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import dev.verdeai.core.*
import kotlin.math.roundToInt

internal const val COMPANION_SHEET = "companion-sheet"
internal const val COMPANION_SETTINGS = "companion-settings"

/** Tells [companion] whether Verde is resumed in the foreground (roster and crew polling). */
@Composable
internal fun CompanionVisibility(companion: CompanionModel) {
    val lifecycle by LocalLifecycleOwner.current.lifecycle.currentStateFlow.collectAsState()
    val resumed = lifecycle.isAtLeast(Lifecycle.State.RESUMED)
    DisposableEffect(companion, resumed) {
        companion.setVisible(resumed)
        onDispose { companion.setVisible(false) }
    }
}

/** What the companion shows and counts, shared by the bubble and the sheet. */
internal data class CompanionSnapshot(
    val active: CompanionEntry?,
    val needs: List<Pane>,
    val crew: List<CompanionLink>,
    val pulse: CompanionPulse,
    /** Keys of everything that needs the user; its size is the badge count. */
    val needKeys: Set<String>,
    val crewRunning: Boolean,
    val companionThread: ThreadSummary?,
)

internal fun companionSnapshot(state: CompanionUiState, browse: BrowseState): CompanionSnapshot {
    val active = state.active
    val panes = browse.home?.items.orEmpty()
    val needs = panes.filter { it.attention || it.status == "waiting_approval" }
    val crew = visibleCrew(state.view?.crew?.takeIf { active != null && it.workspace_id == active.home_workspace_id && it.thread_id == active.thread_id })
    val thread = active?.takeIf { it.thread_id.isNotEmpty() }?.let { a ->
        browse.workspaces?.items?.find { it.workspace_id == a.home_workspace_id }?.threads?.find { it.thread_id == a.thread_id }
    }
    return CompanionSnapshot(active, needs, crew, companionPulse(panes, crew),
        bubbleNeedKeys(needs, crew, thread), crew.any { crewStatus(it).running } || (thread != null && activeTurn(thread.status)), thread)
}

/**
 * The companion, opened from its bubble: compact header with switcher, what needs the user across
 * every workspace, its crew, and its conversation with the shared transcript and composer.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CompanionSheet(
    hosts: HostsModel,
    browse: BrowseModel,
    manage: ManageModel,
    companion: CompanionModel,
    onOpenPane: (Pane) -> Unit,
    onOpenChat: (workspaceId: String, threadId: String) -> Unit,
    onActivity: () -> Unit,
    onCitation: (workspaceId: String, citation: FileCitation) -> Unit,
    settingsRequested: Boolean = false,
    /** The companion chat's model, shared with the bubble's voice session (null before setup). */
    transcript: TranscriptModel? = null,
    voice: CompanionVoice? = null,
    onHideBubble: () -> Unit = {},
    /** Real-time voice; [onLive] starts or ends it (the shell checks the mic permission). */
    live: LiveVoice? = null,
    onLive: () -> Unit = {},
    onDismiss: () -> Unit,
) {
    val state by companion.state.collectAsState()
    val browseState by browse.state.collectAsState()
    var settings by rememberSaveable { mutableStateOf(settingsRequested) }
    var brainOnly by rememberSaveable { mutableStateOf(false) }
    var confirmNew by rememberSaveable { mutableStateOf(false) }
    var conversations by rememberSaveable { mutableStateOf(false) }
    DisposableEffect(companion) {
        companion.setSheetOpen(true)
        onDispose { companion.setSheetOpen(false) }
    }
    val snapshot = companionSnapshot(state, browseState)
    val active = snapshot.active
    val workspaces = browseState.workspaces?.items.orEmpty()
    val online = browseState.host?.phase == "ready" && browseState.networkAvailable
    val thread = active?.thread_id?.takeIf { it.isNotEmpty() }
    val liveUi = live?.ui?.collectAsState()?.value
    val liveSupported = live?.voice?.collectAsState()?.value?.supported != false
    val transcriptState = transcript?.state?.collectAsState()?.value
    val working = transcriptState?.turn != null || snapshot.pulse.running > 0
    val pose = companionPose(online, snapshot.needKeys.isNotEmpty() || transcriptState?.thread?.approval != null, working)

    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = VerdeColors.Background,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), modifier = Modifier.testTag(COMPANION_SHEET)) {
        Column(Modifier.fillMaxWidth().fillMaxHeight(.92f)) {
            if (active == null) {
                CompanionPlaceholder(state, workspaces.any { it.open })
                return@Column
            }
            CompanionHeader(active, state.roster, pose, handoffStatus(state.view?.brain_switch) ?: companionHeaderSuffix(snapshot.needKeys.size, snapshot.pulse.running),
                enabled = state.view?.can_edit == true && !state.saving,
                onNewConversation = { confirmNew = true }, onConversations = { conversations = true },
                onSwitch = companion::switchTo, onSettings = { settings = true }, onActivity = onActivity, onHideBubble = onHideBubble,
                liveActive = liveUi?.active == true, onLive = if (live != null && liveSupported) onLive else null)
            SummaryStrip(snapshot, workspaces, onOpenPane, onOpenChat)
            HorizontalDivider(color = VerdeColors.Border)
            Box(Modifier.weight(1f).fillMaxWidth()) {
                when {
                    live != null && liveUi != null && (liveUi.active || liveUi.phase == LivePhase.Failed) ->
                        LivePanel(live, active.name.ifBlank { "your companion" })
                    transcript != null && transcriptState != null -> {
                        val knownThreads = workspaces.find { it.workspace_id == active.home_workspace_id }?.threads.orEmpty() +
                            workspaces.filter { it.workspace_id != active.home_workspace_id }.flatMap { it.threads }
                        CompanionConversation(transcript, transcriptState, active, knownThreads, voice, onBrain = { brainOnly = true },
                            onCitation = { onCitation(active.home_workspace_id, it) },
                            onOpenThread = { onOpenChat(active.home_workspace_id, it) },
                            onReset = { companion.resetConversation(active.id, thread.orEmpty()) })
                    }
                    state.settingUp -> Centered { CircularProgressIndicator(); Text("Setting up ${active.name}'s conversation…") }
                    state.setupError != null -> Centered {
                        Text(state.setupError.orEmpty(), color = MaterialTheme.colorScheme.error)
                        Button(onClick = companion::retrySetup, shape = MaterialTheme.shapes.small) { Text("Try again") }
                    }
                    state.view?.can_edit != true -> Centered { Text("${active.name} will be ready when the host is reachable.") }
                    else -> Centered { CircularProgressIndicator(); Text("Waking ${active.name}…") }
                }
            }
        }
    }
    if (settings && active != null) CompanionSettingsSheet(companion, manage, browseState, voice, live, transcript) { settings = false }
    // The current conversation's history title: its own title unless generic, else the first thing the user said.
    val currentTitle = active?.let { a ->
        val summary = workspaces.find { it.workspace_id == a.home_workspace_id }?.threads?.find { it.thread_id == a.thread_id }
        conversationTitle(transcriptState?.thread?.thread?.title ?: summary?.title, a.name,
            transcriptState?.thread?.rows?.firstOrNull { it.role == "user" }?.body)
    } ?: "Conversation"
    if (confirmNew && active != null) AlertDialog(onDismissRequest = { confirmNew = false },
        title = { Text("Start a new conversation?") },
        text = { Text("${active.name.ifBlank { "Your companion" }} starts fresh. This one stays in Conversations, so you can go back to it.") },
        confirmButton = { TextButton(onClick = { confirmNew = false; companion.newConversation(currentTitle) }) { Text("New conversation") } },
        dismissButton = { TextButton(onClick = { confirmNew = false }) { Text("Cancel") } })
    if (conversations && active != null) ConversationsSheet(active, currentTitle, companion) { conversations = false }
    if (brainOnly && active != null) CompanionSettingsSheet(companion, manage, browseState, voice, live, transcript, startOnBrain = true) { brainOnly = false }
}

@Composable
private fun Centered(content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically), content = content)
}

@Composable
private fun CompanionPlaceholder(state: CompanionUiState, hasWorkspace: Boolean) {
    Centered {
        CompanionAvatar(CompanionCharacter.Sprout, CompanionPose.Idle, size = 96.dp)
        when {
            !hasWorkspace -> Text("Add a workspace to meet your companion.")
            state.view?.can_edit != true -> Text("Your companion will appear when the host is reachable.")
            else -> { CircularProgressIndicator(); Text("Meeting your companion…") }
        }
    }
}

@Composable
private fun CompanionHeader(active: CompanionEntry, roster: CompanionRoster?, pose: CompanionPose, suffix: String?, enabled: Boolean,
    onSwitch: (String) -> Unit, onSettings: () -> Unit, onActivity: () -> Unit, onHideBubble: () -> Unit,
    liveActive: Boolean = false, onLive: (() -> Unit)? = null, onNewConversation: () -> Unit = {}, onConversations: () -> Unit = {}) {
    val character = CompanionCharacter.of(active.character)
    val name = active.name.ifBlank { character.label }
    val suffixColor = when (pose) {
        CompanionPose.Approval -> VerdeColors.Warning
        CompanionPose.Working -> VerdeColors.Accent
        else -> VerdeColors.Muted
    }
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(start = 12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        CompanionAvatar(character, pose, size = 28.dp, description = "$name, ${character.label}")
        Text(buildAnnotatedString {
            withStyle(MaterialTheme.typography.titleMedium.toSpanStyle()) { append(name) }
            if (suffix != null) withStyle(MaterialTheme.typography.bodySmall.toSpanStyle().copy(color = suffixColor)) { append("  · $suffix") }
        }, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
        onLive?.let { LiveButton(liveActive, it) }
        Box {
            var menu by remember { mutableStateOf(false) }
            IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreVert, contentDescription = "Companion menu") }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(text = { Text("New conversation") }, enabled = enabled && active.thread_id.isNotEmpty(),
                    onClick = { menu = false; onNewConversation() })
                DropdownMenuItem(text = { Text("Conversations\u2026") }, onClick = { menu = false; onConversations() })
                DropdownMenuItem(text = { Text("All activity") }, onClick = { menu = false; onActivity() })
                roster?.companions.orEmpty().filter { it.id != active.id }.forEach { entry ->
                    val look = CompanionCharacter.of(entry.character)
                    DropdownMenuItem(text = { Text("Switch to ${entry.name.ifBlank { look.label }}") }, enabled = enabled,
                        leadingIcon = { CompanionAvatar(look, CompanionPose.Idle, size = 20.dp) },
                        onClick = { menu = false; onSwitch(entry.id) })
                }
                DropdownMenuItem(text = { Text("Settings") }, onClick = { menu = false; onSettings() })
                DropdownMenuItem(text = { Text("Hide bubble") }, onClick = { menu = false; onHideBubble() })
            }
        }
    }
}

private enum class StripPanel { Needs, Crew }

/** One line of the summary strip's expanded list. */
private data class StripRow(val key: String, val title: String, val where: String?, val tone: StripTone, val open: () -> Unit)
private enum class StripTone { Attention, Failed, Running, Quiet }

/**
 * Two small pills under the header ("3 need you", "2 running · 1 done"); tapping one expands a
 * compact, scrollable list in the layout (never over the conversation). Collapsed by default.
 */
@Composable
private fun SummaryStrip(snapshot: CompanionSnapshot, workspaces: List<Workspace>, onOpenPane: (Pane) -> Unit,
    onOpenChat: (String, String) -> Unit) {
    var open by rememberSaveable { mutableStateOf<StripPanel?>(null) }
    val needsCount = snapshot.needKeys.size
    val crewLabel = crewSummary(snapshot.crew)
    if (needsCount == 0 && crewLabel == null) return
    fun label(ws: String) = workspaces.find { it.workspace_id == ws }?.label
    Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically) {
        if (needsCount > 0) StripPill(needsLabel(needsCount), VerdeColors.Warning, open == StripPanel.Needs) {
            open = if (open == StripPanel.Needs) null else StripPanel.Needs
        }
        if (crewLabel != null) StripPill(crewLabel, if (snapshot.crewRunning) VerdeColors.Accent else VerdeColors.Subtle, open == StripPanel.Crew) {
            open = if (open == StripPanel.Crew) null else StripPanel.Crew
        }
    }
    val rows: List<StripRow> = when (open) {
        StripPanel.Needs -> snapshot.needs.map { pane ->
            StripRow("p:" + pane.id, pane.title.ifBlank { "Chat" }, label(pane.workspace_id),
                if (pane.status == "failed" || pane.attention_kind == "failed") StripTone.Failed else StripTone.Attention) { onOpenPane(pane) }
        } + snapshot.crew.filter { crewStatus(it).needsYou && snapshot.needs.none { p -> p.thread_id == it.local_thread_id && p.workspace_id == it.workspace_id } }
            .map { link -> StripRow("l:" + link.link_id, childTitle(link.local_thread_id, link.title), label(link.workspace_id),
                if (crewStatus(link) == ChildStatus.Failed) StripTone.Failed else StripTone.Attention) { onOpenChat(link.workspace_id, link.local_thread_id) } }
        StripPanel.Crew -> snapshot.crew.map { link ->
            val status = crewStatus(link)
            StripRow("l:" + link.link_id, childTitle(link.local_thread_id, link.title), label(link.workspace_id), when {
                status == ChildStatus.Failed -> StripTone.Failed
                status.needsYou -> StripTone.Attention
                status.running -> StripTone.Running
                else -> StripTone.Quiet
            }) { onOpenChat(link.workspace_id, link.local_thread_id) }
        }
        null -> emptyList()
    }
    if (rows.isNotEmpty()) Column(Modifier.fillMaxWidth().heightIn(max = 196.dp).verticalScroll(rememberScrollState())) {
        rows.forEach { row -> key(row.key) { StripItem(row) } }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun StripPill(text: String, dot: androidx.compose.ui.graphics.Color, selected: Boolean, onClick: () -> Unit) {
    Surface(onClick = onClick, shape = RoundedCornerShape(12.dp), color = if (selected) VerdeColors.PanelAlt else VerdeColors.Panel,
        border = androidx.compose.foundation.BorderStroke(1.dp, if (selected) dot else VerdeColors.Border),
        modifier = Modifier.semantics { contentDescription = "$text. ${if (selected) "Collapse" else "Show"} list"; this.selected = selected }) {
        Row(Modifier.padding(horizontal = 10.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Box(Modifier.size(7.dp).background(dot, CircleShape))
            Text(text, style = MaterialTheme.typography.labelMedium, maxLines = 1)
        }
    }
}

@Composable
private fun StripItem(row: StripRow) {
    val color = when (row.tone) {
        StripTone.Attention -> VerdeColors.Warning
        StripTone.Failed -> MaterialTheme.colorScheme.error
        StripTone.Running -> VerdeColors.Accent
        StripTone.Quiet -> VerdeColors.Subtle
    }
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(onClickLabel = "Open chat", onClick = row.open).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        StatusPip(color, null, active = row.tone == StripTone.Running, size = 7.dp)
        Text(row.title, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
        row.where?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = VerdeColors.Subtle, maxLines = 1,
            overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 120.dp)) }
    }
}

@Composable
private fun CompanionConversation(model: TranscriptModel, state: TranscriptState, active: CompanionEntry, threads: List<ThreadSummary>,
    voice: CompanionVoice?, onBrain: () -> Unit, onCitation: (FileCitation) -> Unit, onOpenThread: (String) -> Unit, onReset: () -> Unit) {
    DisposableEffect(model) {
        model.setVisible(true)
        onDispose { model.setVisible(false) }
    }
    val items = remember(state.thread) { state.thread?.let(::transcriptItems).orEmpty() }
    val now = rememberNow(state.turn?.started_at_ms != null)
    val context = TranscriptContext(model, now, onCitation, state.turn?.started_at_ms, threads, onOpenThread)
    val name = active.name.ifBlank { "your companion" }
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.weight(1f).fillMaxWidth()) {
            when (transcriptPlaceholder(state)) {
                null -> TranscriptList(items, state, context, CompactTranscriptRenderers, spacing = 4.dp,
                    contentPadding = PaddingValues(horizontal = 10.dp, vertical = 6.dp))
                TranscriptPlaceholder.Empty -> Suggestions(active.name) { model.composer.ask(it) }
                TranscriptPlaceholder.Loading -> Centered { CircularProgressIndicator() }
                TranscriptPlaceholder.Missing -> Centered {
                    Text("${active.name}'s conversation is no longer on the host.")
                    Button(onClick = onReset, shape = MaterialTheme.shapes.small) { Text("Start a new conversation") }
                }
                TranscriptPlaceholder.Offline -> Centered { Text("This conversation will load when the host is reachable.") }
                TranscriptPlaceholder.Error -> Centered {
                    Text("Couldn't load this conversation.")
                    Button(onClick = model::retry, shape = MaterialTheme.shapes.small) { Text("Retry loading") }
                }
            }
        }
        val mic: (@Composable () -> Unit)? = if (voice != null && voice.available) ({ MicButton(voice, model, name) }) else null
        ChatComposer(model, state, compact = true, inlineAction = mic, onBrain = onBrain, placeholderText = "Message $name\u2026")
    }
}

/**
 * The composer's mic: tap to start and again to send, or hold and release; live words go in the
 * draft. While listening a cancel button sits beside it; while a reply is read aloud a tap stops it.
 */
@Composable
private fun MicButton(voice: CompanionVoice, model: TranscriptModel, name: String) {
    val talk by voice.talk.collectAsState()
    val level by voice.level.collectAsState()
    val speaking by voice.speaking.collectAsState()
    val error by voice.error.collectAsState()
    val mic = rememberMicPermission()
    val haptics = LocalHapticFeedback.current
    val currentTalk by rememberUpdatedState(talk)
    val currentSpeaking by rememberUpdatedState(speaking)
    val listening = talk !is TalkState.Idle
    // Recognition problems surface where the user is looking: the composer's notice line.
    LaunchedEffect(error) { error?.let { model.composer.showNotice(it); voice.clearError() } }
    if (talk is TalkState.Listening) IconButton(onClick = voice::cancel) {
        Icon(Icons.Filled.Close, contentDescription = "Cancel recording", tint = VerdeColors.Muted)
    }
    val ring = (2f + 4f * level.coerceIn(0f, 1f)).dp
    Box(Modifier.size(48.dp)
        .pointerInput(model) {
            awaitEachGesture {
                val down = awaitFirstDown()
                val wasIdle = currentTalk is TalkState.Idle
                if (wasIdle && currentSpeaking) { waitForUpOrCancellation(); voice.stopSpeaking(); return@awaitEachGesture }
                if (wasIdle) {
                    if (!mic.granted()) { mic.request(); waitForUpOrCancellation(); return@awaitEachGesture }
                    haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                    voice.press(model, liveDraft = true)
                }
                val up = waitForUpOrCancellation()
                when {
                    !wasIdle -> if (up != null) voice.release()
                    up == null -> voice.cancel()
                    up.uptimeMillis - down.uptimeMillis >= HOLD_TO_TALK_MS -> voice.release()
                    // A quick tap keeps listening until the next tap.
                    else -> Unit
                }
            }
        }
        .semantics {
            role = Role.Button
            contentDescription = if (speaking && !listening) "Stop reading the reply aloud" else micLabel(talk, name)
            onClick(label = when { listening -> "Stop and send"; speaking -> "Stop speaking"; else -> "Talk" }) {
                when {
                    listening -> voice.release()
                    speaking -> voice.stopSpeaking()
                    mic.granted() -> voice.press(model, liveDraft = true)
                    else -> mic.request()
                }
                true
            }
        }, contentAlignment = Alignment.Center) {
        Box(Modifier.size(36.dp)
            .background(if (listening) VerdeColors.Accent else VerdeColors.PanelAlt, CircleShape)
            .then(if (listening) Modifier.border(ring, VerdeColors.AccentWash, CircleShape) else Modifier),
            contentAlignment = Alignment.Center) {
            Icon(painterResource(if (speaking && !listening) R.drawable.ic_waveform else R.drawable.ic_mic), contentDescription = null,
                tint = if (listening) VerdeColors.Background else if (speaking) VerdeColors.Accent else VerdeColors.Text, modifier = Modifier.size(18.dp))
        }
    }
}

/** A press longer than this on the mic is hold-to-talk (release sends); shorter is tap-to-toggle. */
internal const val HOLD_TO_TALK_MS = 400L

/** Device-local voice settings: when to read replies aloud, speed, voice and recognizer. */
@Composable
private fun VoiceSettings(voice: CompanionVoice) {
    val prefs = voice.prefs
    val context = LocalContext.current
    val policy = effectiveReadAloud(prefs.readAloud, talkBackOn(context))
    VerdeSection("Voice on this phone")
    Column(Modifier.padding(horizontal = 16.dp).selectableGroup()) {
        Text("Read replies aloud", style = MaterialTheme.typography.titleSmall)
        ReadAloud.entries.forEach { option ->
            Row(Modifier.fillMaxWidth().selectable(selected = policy == option, role = Role.RadioButton) { prefs.chooseReadAloud(option) }
                .padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                RadioButton(selected = policy == option, onClick = null)
                Text(option.label, Modifier.padding(start = 12.dp))
            }
        }
    }
    Column(Modifier.padding(horizontal = 16.dp)) {
        Text("Speaking rate: ${"%.1f".format(prefs.rate)}\u00d7", style = MaterialTheme.typography.titleSmall)
        Slider(value = prefs.rate, onValueChange = { prefs.chooseRate((it * 10).roundToInt() / 10f) },
            valueRange = VoicePrefs.MIN_RATE..VoicePrefs.MAX_RATE, modifier = Modifier.semantics { contentDescription = "Speaking rate" })
    }
    // Text-to-speech starts asynchronously; poll briefly for its voice list.
    val voices by produceState(emptyList<android.speech.tts.Voice>(), voice) {
        repeat(6) {
            value = voice.voices()
            if (value.isNotEmpty()) return@produceState
            kotlinx.coroutines.delay(500)
        }
    }
    if (voices.isNotEmpty()) {
        val choices = listOf(ChatChoice("", "System default")) + voices.map { ChatChoice(it.name, voiceLabel(it.name, it.locale)) }
        Picker("Voice", choices.find { it.id == prefs.voiceName.orEmpty() }?.label ?: "System default", choices, enabled = true) {
            prefs.chooseVoice(it.ifEmpty { null })
        }
    }
    Row(Modifier.fillMaxWidth().toggleable(prefs.preferOnDevice, role = Role.Switch) { prefs.choosePreferOnDevice(it) }
        .padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f).padding(end = 16.dp)) {
            Text("Prefer on-device recognition", style = MaterialTheme.typography.bodyLarge)
            Text("Keep speech on this phone when it supports your language.", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Switch(checked = prefs.preferOnDevice, onCheckedChange = null)
    }
}

/** "English (United States) · en-us-x-sfg-local" style label for a TTS voice. */
internal fun voiceLabel(name: String, locale: java.util.Locale): String = "${locale.displayName} \u00b7 $name"

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Suggestions(name: String, onPick: (String) -> Unit) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.Bottom)) {
        Text("Ask ${name.ifBlank { "your companion" }} to dispatch and watch work across every workspace.",
            style = MaterialTheme.typography.bodyMedium, color = VerdeColors.Muted)
        COMPANION_SUGGESTIONS.forEach { text ->
            OutlinedCard(onClick = { onPick(text) }, modifier = Modifier.fillMaxWidth()) {
                Text(text, Modifier.padding(12.dp), style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
}

// ---- Settings ----

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CompanionSettingsSheet(companion: CompanionModel, manage: ManageModel, browse: BrowseState, voice: CompanionVoice? = null,
    live: LiveVoice? = null, transcript: TranscriptModel? = null, startOnBrain: Boolean = false, onDismiss: () -> Unit) {
    var brain by remember { mutableStateOf(startOnBrain) }
    if (brain) {
        CompanionBrainSheet(companion, manage, browse, transcript) { brain = false; if (startOnBrain) onDismiss() }
        return
    }
    val state by companion.state.collectAsState()
    val roster = state.roster ?: return
    val active = activeCompanion(roster) ?: return
    var adding by rememberSaveable { mutableStateOf(false) }
    var confirmRemove by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { companion.clearSaveError() }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = VerdeColors.Panel,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), modifier = Modifier.testTag(COMPANION_SETTINGS)) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
            VerdeSection("Companions")
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                roster.companions.forEach { entry ->
                    val selected = entry.id == active.id && !adding
                    FilterChip(selected = selected, onClick = { adding = false; if (entry.id != active.id) companion.switchTo(entry.id) },
                        enabled = !state.saving && state.view?.can_edit == true,
                        label = { Text(entry.name.ifBlank { CompanionCharacter.of(entry.character).label }, maxLines = 1) },
                        leadingIcon = { CompanionAvatar(CompanionCharacter.of(entry.character), CompanionPose.Idle, size = 24.dp) })
                }
                if (roster.companions.size < MAX_COMPANIONS) FilterChip(selected = adding, onClick = { adding = true },
                    enabled = !state.saving && state.view?.can_edit == true, label = { Text("Add") },
                    leadingIcon = { Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp)) })
            }
            if (adding) AddCompanion(companion, state, roster) { adding = false }
            else key(active.id) { EditCompanion(companion, manage, state, browse, roster, active, onRemove = { confirmRemove = true }, onDone = onDismiss,
                onBrain = { brain = true }) }
            if (voice != null) {
                HorizontalDivider(Modifier.padding(vertical = 8.dp), color = VerdeColors.Border)
                VoiceSettings(voice)
            }
            if (live != null) {
                HorizontalDivider(Modifier.padding(vertical = 8.dp), color = VerdeColors.Border)
                LiveVoiceSettings(live)
            }
        }
    }
    if (confirmRemove) AlertDialog(onDismissRequest = { confirmRemove = false },
        title = { Text("Remove ${active.name}?") },
        text = { Text("${active.name}'s conversation stays on the host. You can't undo this here.") },
        confirmButton = { TextButton(onClick = { confirmRemove = false; companion.remove(active.id) }) { Text("Remove", color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = { confirmRemove = false }) { Text("Cancel") } })
}

@Composable
private fun CharacterPicker(selected: CompanionCharacter, enabled: Boolean, onPick: (CompanionCharacter) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        CompanionCharacter.entries.forEach { character ->
            val on = character == selected
            Column(Modifier.weight(1f).background(if (on) VerdeColors.AccentWash else VerdeColors.PanelAlt, RoundedCornerShape(10.dp))
                .border(1.dp, if (on) VerdeColors.Accent else VerdeColors.Border, RoundedCornerShape(10.dp))
                .clickable(enabled = enabled, role = Role.RadioButton) { onPick(character) }
                .semantics { this.selected = on }
                .padding(8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                CompanionAvatar(character, CompanionPose.Idle, size = 56.dp)
                Text(character.label, style = MaterialTheme.typography.labelLarge)
            }
        }
    }
}

@Composable
private fun AddCompanion(companion: CompanionModel, state: CompanionUiState, roster: CompanionRoster, onDone: () -> Unit) {
    var character by rememberSaveable { mutableStateOf(CompanionCharacter.Moss) }
    var name by rememberSaveable { mutableStateOf(suggestedName(roster, CompanionCharacter.Moss)) }
    var edited by rememberSaveable { mutableStateOf(false) }
    val enabled = !state.saving && state.view?.can_edit == true
    VerdeSection("New companion")
    CharacterPicker(character, enabled) {
        character = it
        if (!edited) name = suggestedName(roster, it)
    }
    OutlinedTextField(name, onValueChange = { name = clipUtf8(it.replace('\n', ' '), MAX_COMPANION_NAME_BYTES); edited = true },
        label = { Text("Name") }, singleLine = true, enabled = enabled,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp))
    state.saveError?.let { Text(it, Modifier.padding(horizontal = 16.dp), color = MaterialTheme.colorScheme.error) }
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.End) {
        TextButton(onClick = onDone) { Text("Cancel") }
        Button(onClick = { companion.add(character, name, onSaved = onDone) }, enabled = enabled && cleanCompanionName(name).isNotEmpty(),
            shape = MaterialTheme.shapes.small) { Text(if (state.saving) "Adding…" else "Add companion") }
    }
}

@Composable
private fun EditCompanion(companion: CompanionModel, manage: ManageModel, state: CompanionUiState, browse: BrowseState,
    roster: CompanionRoster, active: CompanionEntry, onRemove: () -> Unit, onDone: () -> Unit, onBrain: () -> Unit) {
    var name by rememberSaveable { mutableStateOf(active.name) }
    var character by rememberSaveable { mutableStateOf(CompanionCharacter.of(active.character)) }
    var orders by rememberSaveable { mutableStateOf(active.orders) }
    val enabled = !state.saving && state.view?.can_edit == true
    val workspace = browse.workspaces?.items?.find { it.workspace_id == active.home_workspace_id }

    VerdeSection("Name")
    OutlinedTextField(name, onValueChange = { name = clipUtf8(it.replace('\n', ' '), MAX_COMPANION_NAME_BYTES) },
        singleLine = true, enabled = enabled, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp).testTag("companion-name"))
    VerdeSection("Character")
    CharacterPicker(character, enabled) { character = it }
    VerdeSection("Standing orders")
    OutlinedTextField(orders, onValueChange = { orders = clipUtf8(it, MAX_COMPANION_ORDERS_BYTES) }, enabled = enabled,
        minLines = 3, maxLines = 8, placeholder = { Text("Always run the tests before calling work done.") },
        supportingText = { Text("Sent with every message to ${cleanCompanionName(name).ifEmpty { "your companion" }}.") },
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp))
    VerdeSection("Brain")
    // Hermes-style: the brain has its own page; here, its summary.
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(onClickLabel = "Change brain", onClick = onBrain)
        .padding(horizontal = 16.dp, vertical = 8.dp).testTag("companion-brain-row"), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        ProviderGlyph(active.provider.ifEmpty { null })
        Text(brainLabel(PROVIDERS.find { it.first == active.provider }?.second ?: active.provider.ifEmpty { "Workspace default" },
            active.model.ifEmpty { null }, null), Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, maxLines = 1,
            overflow = TextOverflow.Ellipsis)
        Text("\u203a", style = MaterialTheme.typography.titleMedium, color = VerdeColors.Subtle)
    }
    workspace?.let {
        Text("Lives in ${it.label}", Modifier.padding(horizontal = 16.dp, vertical = 8.dp), style = MaterialTheme.typography.bodySmall, color = VerdeColors.Subtle)
    }
    state.saveError?.let { Text(it, Modifier.padding(horizontal = 16.dp), color = MaterialTheme.colorScheme.error) }
    if (state.view?.can_edit != true) Text("Connect to the host to change companions.", Modifier.padding(horizontal = 16.dp), color = VerdeColors.Muted)
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        if (roster.companions.size > 1) TextButton(onClick = onRemove, enabled = enabled) {
            Text("Remove", color = MaterialTheme.colorScheme.error)
        }
        Spacer(Modifier.weight(1f))
        Button(onClick = {
            companion.update(active.copy(name = cleanCompanionName(name), character = character.id, orders = cleanOrders(orders)), onSaved = onDone)
        }, enabled = enabled && cleanCompanionName(name).isNotEmpty(), shape = MaterialTheme.shapes.small) {
            Text(if (state.saving) "Saving…" else "Save")
        }
    }
}


/** The companion's conversations: the current one, then earlier ones (tap to resume, long-press to remove from the list). */
@OptIn(ExperimentalMaterial3Api::class, androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun ConversationsSheet(active: CompanionEntry, currentTitle: String, companion: CompanionModel, onDismiss: () -> Unit) {
    val state by companion.state.collectAsState()
    val now = rememberNow(false)
    val enabled = state.view?.can_edit == true && !state.saving
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = VerdeColors.Panel,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), modifier = Modifier.testTag(COMPANION_CONVERSATIONS)) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
            Text("Conversations", Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.titleLarge)
            if (active.thread_id.isNotEmpty()) ConversationRow(currentTitle, brainLabel(providerName(active.provider), active.model.ifEmpty { null }, null),
                "Current", current = true, enabled = false, onOpen = {}, onRemove = null)
            if (active.history.isEmpty()) Text("Earlier conversations appear here when you start a new one.",
                Modifier.padding(16.dp), style = MaterialTheme.typography.bodySmall, color = VerdeColors.Muted)
            active.history.forEach { past ->
                key(past.thread_id) {
                    ConversationRow(past.title.ifBlank { "Conversation" }, brainLabel(providerName(past.provider), past.model.ifEmpty { null }, null),
                        past.ended_at_ms.takeIf { it > 0 }?.let { agoLabel(it, now) }, current = false, enabled = enabled,
                        onOpen = { companion.resumeConversation(past.thread_id, currentTitle, onSaved = onDismiss) },
                        onRemove = { companion.forgetConversation(past.thread_id) })
                }
            }
            state.saveError?.let { Text(it, Modifier.padding(horizontal = 16.dp), color = MaterialTheme.colorScheme.error) }
        }
    }
}

internal const val COMPANION_CONVERSATIONS = "companion-conversations"

private fun providerName(id: String): String? = id.takeIf { it.isNotEmpty() }?.let { p -> PROVIDERS.find { it.first == p }?.second ?: p }

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun ConversationRow(title: String, brain: String, detail: String?, current: Boolean, enabled: Boolean, onOpen: () -> Unit, onRemove: (() -> Unit)?) {
    var menu by remember { mutableStateOf(false) }
    Box {
        Row(Modifier.fillMaxWidth().heightIn(min = 56.dp)
            .combinedClickable(enabled = enabled || onRemove != null, onClickLabel = "Resume", onLongClickLabel = "More",
                onClick = { if (enabled) onOpen() }, onLongClick = { if (onRemove != null) menu = true })
            .padding(horizontal = 16.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    color = if (current) VerdeColors.Accent else VerdeColors.Text)
                Text(listOfNotNull(brain, detail).joinToString(" \u00b7 "), style = MaterialTheme.typography.labelSmall,
                    color = VerdeColors.Subtle, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        if (onRemove != null) DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text("Remove from list") }, onClick = { menu = false; onRemove() })
        }
    }
}
