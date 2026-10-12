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
import androidx.compose.ui.text.style.TextOverflow
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
    onDismiss: () -> Unit,
) {
    val state by companion.state.collectAsState()
    val browseState by browse.state.collectAsState()
    var settings by rememberSaveable { mutableStateOf(settingsRequested) }
    DisposableEffect(companion) {
        companion.setSheetOpen(true)
        onDispose { companion.setSheetOpen(false) }
    }
    val snapshot = companionSnapshot(state, browseState)
    val active = snapshot.active
    val workspaces = browseState.workspaces?.items.orEmpty()
    val online = browseState.host?.phase == "ready" && browseState.networkAvailable
    val thread = active?.thread_id?.takeIf { it.isNotEmpty() }
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
            CompanionHeader(active, state.roster, pose, companionStatusLine(snapshot.pulse.copy(needsYou = snapshot.needKeys.size)), enabled = state.view?.can_edit == true && !state.saving,
                onSwitch = companion::switchTo, onSettings = { settings = true }, onActivity = onActivity, onHideBubble = onHideBubble)
            if (snapshot.needs.isNotEmpty()) NeedsYou(snapshot.needs, workspaces, onOpenPane, onActivity)
            if (snapshot.crew.isNotEmpty()) Crew(snapshot.crew, workspaces) { onOpenChat(it.workspace_id, it.local_thread_id) }
            HorizontalDivider(color = VerdeColors.Border)
            Box(Modifier.weight(1f).fillMaxWidth()) {
                when {
                    transcript != null && transcriptState != null -> {
                        val knownThreads = workspaces.find { it.workspace_id == active.home_workspace_id }?.threads.orEmpty() +
                            workspaces.filter { it.workspace_id != active.home_workspace_id }.flatMap { it.threads }
                        CompanionConversation(transcript, transcriptState, active, knownThreads, voice,
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
    if (settings && active != null) CompanionSettingsSheet(companion, manage, browseState, voice) { settings = false }
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
private fun CompanionHeader(active: CompanionEntry, roster: CompanionRoster?, pose: CompanionPose, status: String, enabled: Boolean,
    onSwitch: (String) -> Unit, onSettings: () -> Unit, onActivity: () -> Unit, onHideBubble: () -> Unit) {
    val character = CompanionCharacter.of(active.character)
    Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        CompanionAvatar(character, pose, size = 48.dp, description = "${active.name}, ${character.label}")
        Column(Modifier.weight(1f)) {
            Text(active.name.ifBlank { character.label }, style = MaterialTheme.typography.titleLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(status, style = MaterialTheme.typography.bodySmall, maxLines = 1, color = when (pose) {
                CompanionPose.Approval -> VerdeColors.Warning
                CompanionPose.Working -> VerdeColors.Accent
                else -> VerdeColors.Muted
            })
        }
        TextButton(onClick = onActivity) { Text("All activity") }
        IconButton(onClick = onSettings) { Icon(Icons.Filled.Settings, contentDescription = "Companion settings") }
        Box {
            var menu by remember { mutableStateOf(false) }
            IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreVert, contentDescription = "More companion options") }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(text = { Text("Hide bubble") }, onClick = { menu = false; onHideBubble() })
                DropdownMenuItem(text = { Text("Settings") }, onClick = { menu = false; onSettings() })
            }
        }
    }
    // Switcher: the other companions, one tap away.
    val others = roster?.companions.orEmpty().filter { it.id != active.id }
    if (others.isNotEmpty()) Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        others.forEach { entry ->
            val look = CompanionCharacter.of(entry.character)
            AssistChip(onClick = { onSwitch(entry.id) }, enabled = enabled,
                label = { Text(entry.name.ifBlank { look.label }, maxLines = 1) },
                leadingIcon = { CompanionAvatar(look, CompanionPose.Idle, size = 20.dp) },
                modifier = Modifier.semantics { contentDescription = "Switch to ${entry.name.ifBlank { look.label }}" })
        }
    }
}

private const val NEEDS_YOU_ROWS = 3

@Composable
private fun NeedsYou(needs: List<Pane>, workspaces: List<Workspace>, onOpen: (Pane) -> Unit, onMore: () -> Unit) {
    VerdeSection("Needs you")
    needs.take(NEEDS_YOU_ROWS).forEach { pane ->
        val where = workspaces.find { it.workspace_id == pane.workspace_id }?.label
        VerdeListRow(
            headlineContent = { Text(pane.title.ifBlank { "Chat" }, maxLines = 1, overflow = TextOverflow.Ellipsis) },
            supportingContent = { Text(listOfNotNull(where, attentionLabel(pane.attention_kind) ?: statusLabel(pane.status)).joinToString(" · "), maxLines = 1) },
            leadingContent = { StatusPip(statusColor(pane.status, true), statusLabel(pane.status), size = 8.dp) },
            modifier = Modifier.fillMaxWidth().clickable(enabled = openable(pane), onClickLabel = "Open") { onOpen(pane) },
        )
    }
    if (needs.size > NEEDS_YOU_ROWS) TextButton(onClick = onMore, modifier = Modifier.padding(horizontal = 8.dp)) {
        Text("${needs.size - NEEDS_YOU_ROWS} more")
    }
}

@Composable
private fun Crew(crew: List<CompanionLink>, workspaces: List<Workspace>, onOpen: (CompanionLink) -> Unit) {
    VerdeSection("Crew")
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        crew.forEach { link ->
            val status = crewStatus(link)
            val title = childTitle(link.local_thread_id, link.title)
            val where = workspaces.find { it.workspace_id == link.workspace_id }?.label
            val color = when {
                status == ChildStatus.Failed -> MaterialTheme.colorScheme.error
                status.needsYou -> VerdeColors.Warning
                status.running -> VerdeColors.Accent
                else -> VerdeColors.Subtle
            }
            Row(Modifier.widthIn(max = 240.dp).background(VerdeColors.Panel, RoundedCornerShape(16.dp))
                .border(1.dp, if (status.needsYou) VerdeColors.Warning else VerdeColors.Border, RoundedCornerShape(16.dp))
                .clickable(onClickLabel = "Open chat", role = Role.Button) { onOpen(link) }
                .padding(horizontal = 10.dp, vertical = 6.dp)
                .semantics { contentDescription = "$title, ${status.label}" },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                ProviderGlyph(link.provider.ifEmpty { null }, Modifier.size(14.dp))
                StatusPip(color, null, active = status.running, size = 8.dp)
                Column {
                    Text(title, style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(listOfNotNull(status.label, where).joinToString(" · "), style = MaterialTheme.typography.labelSmall,
                        color = VerdeColors.Muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

@Composable
private fun CompanionConversation(model: TranscriptModel, state: TranscriptState, active: CompanionEntry, threads: List<ThreadSummary>,
    voice: CompanionVoice?, onCitation: (FileCitation) -> Unit, onOpenThread: (String) -> Unit, onReset: () -> Unit) {
    DisposableEffect(model) {
        model.setVisible(true)
        onDispose { model.setVisible(false) }
    }
    val items = remember(state.thread) { state.thread?.let(::transcriptItems).orEmpty() }
    val now = rememberNow(state.turn?.started_at_ms != null)
    val context = TranscriptContext(model, now, onCitation, state.turn?.started_at_ms, threads, onOpenThread)
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.weight(1f).fillMaxWidth()) {
            when (transcriptPlaceholder(state)) {
                null -> TranscriptList(items, state, context, TranscriptRenderers.Default)
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
        if (voice != null && voice.available) VoiceBar(voice, model, active.name.ifBlank { "your companion" })
        ChatComposer(model, state)
    }
}

/** Mic for the companion sheet: tap to start and again to send, or hold and release; live words go in the draft. */
@Composable
private fun VoiceBar(voice: CompanionVoice, model: TranscriptModel, name: String) {
    val talk by voice.talk.collectAsState()
    val level by voice.level.collectAsState()
    val speaking by voice.speaking.collectAsState()
    val error by voice.error.collectAsState()
    val mic = rememberMicPermission()
    val haptics = LocalHapticFeedback.current
    val currentTalk by rememberUpdatedState(talk)
    val listening = talk !is TalkState.Idle
    Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.size(48.dp)
            .background(if (listening) VerdeColors.Accent else VerdeColors.PanelAlt, CircleShape)
            .pointerInput(model) {
                awaitEachGesture {
                    val down = awaitFirstDown()
                    val wasIdle = currentTalk is TalkState.Idle
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
                contentDescription = micLabel(talk, name)
                onClick(label = if (listening) "Stop and send" else "Talk") {
                    if (listening) voice.release() else if (mic.granted()) voice.press(model, liveDraft = true) else mic.request()
                    true
                }
            }, contentAlignment = Alignment.Center) {
            Icon(painterResource(R.drawable.ic_mic), contentDescription = null,
                tint = if (listening) VerdeColors.Background else VerdeColors.Text, modifier = Modifier.size(22.dp))
        }
        when {
            talk is TalkState.Listening -> {
                LevelBars(level)
                Text(if ((talk as TalkState.Listening).cancelArmed) "Release to cancel" else "Listening\u2026 tap to send",
                    Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = VerdeColors.Muted)
                IconButton(onClick = voice::cancel) { Icon(Icons.Filled.Close, contentDescription = "Cancel recording") }
            }
            talk is TalkState.Finishing -> Text("Sending\u2026", Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = VerdeColors.Muted)
            speaking -> {
                Text("Speaking", Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = VerdeColors.Accent)
                TextButton(onClick = voice::stopSpeaking) { Text("Stop") }
            }
            error != null -> Text(error.orEmpty(), Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
            else -> Text("Hold or tap to talk", Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = VerdeColors.Subtle)
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
internal fun CompanionSettingsSheet(companion: CompanionModel, manage: ManageModel, browse: BrowseState, voice: CompanionVoice? = null, onDismiss: () -> Unit) {
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
            else key(active.id) { EditCompanion(companion, manage, state, browse, roster, active, onRemove = { confirmRemove = true }, onDone = onDismiss) }
            if (voice != null) {
                HorizontalDivider(Modifier.padding(vertical = 8.dp), color = VerdeColors.Border)
                VoiceSettings(voice)
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
    roster: CompanionRoster, active: CompanionEntry, onRemove: () -> Unit, onDone: () -> Unit) {
    var name by rememberSaveable { mutableStateOf(active.name) }
    var character by rememberSaveable { mutableStateOf(CompanionCharacter.of(active.character)) }
    var orders by rememberSaveable { mutableStateOf(active.orders) }
    var provider by rememberSaveable { mutableStateOf(active.provider) }
    var model by rememberSaveable { mutableStateOf(active.model) }
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
    Brain(manage, active.home_workspace_id, provider, model, enabled,
        onProvider = { provider = it; model = "" }, onModel = { model = it })
    Text("Used when ${cleanCompanionName(name).ifEmpty { "your companion" }} starts a conversation. Change the current one from its composer.",
        Modifier.padding(horizontal = 16.dp, vertical = 4.dp), style = MaterialTheme.typography.bodySmall, color = VerdeColors.Muted)
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
            companion.update(active.copy(name = cleanCompanionName(name), character = character.id, orders = cleanOrders(orders),
                provider = provider, model = model), onSaved = onDone)
        }, enabled = enabled && cleanCompanionName(name).isNotEmpty(), shape = MaterialTheme.shapes.small) {
            Text(if (state.saving) "Saving…" else "Save")
        }
    }
}

/** Provider and model from the same catalog as New chat (the core's `manage` new-chat view). */
@Composable
private fun Brain(manage: ManageModel, workspaceId: String, provider: String, model: String, enabled: Boolean,
    onProvider: (String) -> Unit, onModel: (String) -> Unit) {
    val manageState by manage.state.collectAsState()
    LaunchedEffect(workspaceId, provider, manageState.hostId, manageState.view != null) {
        if (workspaceId.isNotEmpty() && manageState.view != null) manage.select(workspaceId, ChatSelection(provider = provider.ifEmpty { null }))
    }
    val chat = manageState.view?.new_chat?.takeIf { it.workspace_id == workspaceId }
    val providers = listOf(ChatChoice("", "Workspace default")) + chat?.providers.orEmpty()
    val models = if (provider.isNotEmpty() && chat?.selection?.provider == provider) listOf(ChatChoice("", "Default")) + chat?.catalogs?.models.orEmpty() else emptyList()
    Picker("Provider", providers.find { it.id == provider }?.label ?: provider.ifEmpty { "Workspace default" }, providers, enabled && chat != null, providerIcons = true, onPick = onProvider)
    if (provider.isNotEmpty()) Picker("Model", models.find { it.id == model }?.label ?: model.ifEmpty { "Default" }, models,
        enabled && chat?.loading == false, onPick = onModel)
}
