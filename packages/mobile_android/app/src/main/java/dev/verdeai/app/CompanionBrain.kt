package dev.verdeai.app

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.verdeai.core.*

internal const val COMPANION_BRAIN = "companion-brain"

/**
 * Settings → Companion → Brain: provider (as New chat offers them, unavailable ones dimmed with
 * their reason), model, effort and speed. Same-provider changes apply to the live conversation in
 * place; switching an ongoing conversation's provider goes through [CompanionModel.switchCompanionProvider].
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CompanionBrainSheet(companion: CompanionModel, manage: ManageModel, browse: BrowseState, transcript: TranscriptModel?,
    onDismiss: () -> Unit) {
    val state by companion.state.collectAsState()
    val entry = state.active ?: return
    val name = entry.name.ifBlank { CompanionCharacter.of(entry.character).label }
    val ws = entry.home_workspace_id.ifEmpty { mostRecentOpenWorkspace(browse.workspaces?.items.orEmpty())?.workspace_id.orEmpty() }
    val live = transcript?.takeIf { entry.thread_id.isNotEmpty() && it.threadId == entry.thread_id && it.workspaceId == entry.home_workspace_id }
    val liveState = live?.state?.collectAsState()?.value
    val summary = browse.workspaces?.items?.find { it.workspace_id == entry.home_workspace_id }?.threads?.find { it.thread_id == entry.thread_id }
    val threadProvider = liveState?.thread?.thread?.provider ?: summary?.provider
    val threadEmpty = when {
        liveState?.thread != null -> liveState.thread.rows.isEmpty() && liveState.turn == null
        summary != null -> !summary.committed
        else -> entry.thread_id.isEmpty()
    }
    val current = liveState?.composer?.selection?.let { ChatSelection(it.provider, it.model, it.effort, null, it.speed) }
        ?: ChatSelection(provider = entry.provider.ifEmpty { threadProvider }, model = entry.model.ifEmpty { null })
    var draft by remember(entry.id) { mutableStateOf(current) }
    var touched by remember(entry.id) { mutableStateOf(false) }
    LaunchedEffect(current) { if (!touched) draft = current }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var confirm by remember { mutableStateOf(false) }
    var skipBrief by remember { mutableStateOf(false) }

    // The provider list, readiness and model catalogs come from the same source as New chat.
    val manageState by manage.state.collectAsState()
    LaunchedEffect(ws, draft.provider, manageState.hostId, manageState.view != null) {
        if (ws.isNotEmpty() && manageState.view != null) manage.select(ws, ChatSelection(provider = draft.provider))
    }
    val chat = manageState.view?.new_chat?.takeIf { it.workspace_id == ws }
    val catalog = chat?.takeIf { draft.provider == null || it.selection.provider == draft.provider }
    val providers = chat?.providers.orEmpty()
    val providerName = providers.find { it.id == draft.provider }?.label ?: draft.provider
    val change = classifyBrainChange(entry.thread_id, threadProvider, threadEmpty, current, draft)
    fun apply() {
        busy = true; message = null
        companion.applyBrain(entry, draft, change, live, brief = !skipBrief) { error ->
            busy = false
            message = error
            if (error == null) onDismiss()
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = VerdeColors.Panel,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), modifier = Modifier.testTag(COMPANION_BRAIN)) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
            Text("$name's brain", Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.titleLarge)
            Text(brainLabel(providerName, catalog?.let { composerChoiceLabel(it.catalogs.models, draft.model) } ?: draft.model,
                catalog?.takeIf { it.catalogs.efforts.isNotEmpty() }?.let { composerChoiceLabel(it.catalogs.efforts, draft.effort) }),
                Modifier.padding(horizontal = 16.dp, vertical = 4.dp), style = MaterialTheme.typography.bodyMedium, color = VerdeColors.Accent)
            Text("Your companion's brain does the real work; Live voice uses a separate voice provider.",
                Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.bodySmall, color = VerdeColors.Muted)

            VerdeSection("Provider")
            if (chat == null) LinearProgressIndicator(Modifier.fillMaxWidth().padding(16.dp))
            Column(Modifier.selectableGroup()) {
                providers.forEach { choice ->
                    BrainRow(choice.label, choice.reason.takeIf { !choice.enabled }, selected = choice.id == draft.provider,
                        enabled = choice.enabled && !busy, leading = { ProviderGlyph(choice.id) }) {
                        touched = true
                        if (choice.id != draft.provider) draft = ChatSelection(provider = choice.id)
                    }
                }
            }
            if (change == BrainChange.HandOff) Text("$name keeps this conversation; the current brain hands off with a short brief.",
                Modifier.padding(horizontal = 16.dp, vertical = 4.dp), style = MaterialTheme.typography.bodySmall, color = VerdeColors.Warning)

            VerdeSection("Model")
            when {
                catalog == null || catalog.loading -> LinearProgressIndicator(Modifier.fillMaxWidth().padding(16.dp))
                else -> Column(Modifier.selectableGroup()) {
                    catalog.catalogs.models.sortedByDescending { it.favorite }.forEach { choice ->
                        BrainRow(choice.label, choice.reason.takeIf { !choice.enabled },
                            selected = choice.id == (draft.model ?: catalog.selection.model), enabled = choice.enabled && !busy) {
                            touched = true
                            draft = draft.copy(model = choice.id)
                        }
                    }
                }
            }
            catalog?.catalogs?.efforts?.takeIf { it.isNotEmpty() }?.let { efforts ->
                VerdeSection("Effort")
                ChoiceChips(efforts, draft.effort ?: "", !busy) { touched = true; draft = draft.copy(effort = it.ifEmpty { null }) }
            }
            catalog?.catalogs?.speeds?.takeIf { it.size > 1 }?.let { speeds ->
                VerdeSection("Speed")
                ChoiceChips(speeds, draft.speed ?: "off", !busy) { touched = true; draft = draft.copy(speed = it) }
            }
            message?.let { Text(it, Modifier.padding(horizontal = 16.dp, vertical = 4.dp), color = MaterialTheme.colorScheme.error) }
            if (state.view?.can_edit != true) Text("Connect to the host to change the brain.", Modifier.padding(horizontal = 16.dp), color = VerdeColors.Muted)
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onDismiss) { Text("Cancel") }
                Button(onClick = { if (change == BrainChange.HandOff) confirm = true else apply() },
                    enabled = !busy && change != BrainChange.None && state.view?.can_edit == true && draft.provider != null,
                    shape = MaterialTheme.shapes.small) { Text(if (busy) "Saving…" else "Use this brain") }
            }
        }
    }
    val fromName = providers.find { it.id == threadProvider }?.label ?: PROVIDERS.find { it.first == threadProvider }?.second
    val (dialogTitle, dialogText) = brainSwitchDialog(name, fromName, providerName ?: "another provider")
    if (confirm) AlertDialog(onDismissRequest = { confirm = false },
        title = { Text(dialogTitle) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(dialogText)
                Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(skipBrief, role = Role.Checkbox) { skipBrief = it },
                    verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = skipBrief, onCheckedChange = null)
                    Text("Skip the brief", Modifier.padding(start = 8.dp))
                }
            }
        },
        confirmButton = { TextButton(onClick = { confirm = false; apply() }) { Text("Switch") } },
        dismissButton = { TextButton(onClick = { confirm = false }) { Text("Cancel") } })
}

@Composable
private fun BrainRow(label: String, reason: String?, selected: Boolean, enabled: Boolean, leading: (@Composable () -> Unit)? = null, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).selectable(selected = selected, enabled = enabled, role = Role.RadioButton, onClick = onClick)
        .padding(horizontal = 16.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        RadioButton(selected = selected, onClick = null, enabled = enabled)
        leading?.invoke()
        Column(Modifier.weight(1f)) {
            Text(label, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis,
                color = if (enabled) VerdeColors.Text else VerdeColors.Subtle)
            reason?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = VerdeColors.Subtle, maxLines = 2) }
        }
    }
}

@Composable
private fun ChoiceChips(choices: List<ChatChoice>, selected: String, enabled: Boolean, onPick: (String) -> Unit) {
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        choices.forEach { choice ->
            FilterChip(selected = choice.id == selected, onClick = { onPick(choice.id) }, enabled = enabled && choice.enabled,
                label = { Text(choice.label, maxLines = 1) })
        }
    }
}
