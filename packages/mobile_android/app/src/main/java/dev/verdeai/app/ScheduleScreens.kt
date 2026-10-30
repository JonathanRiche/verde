package dev.verdeai.app

import android.text.format.DateFormat
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.verdeai.core.*
import kotlinx.coroutines.delay
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset

internal const val SCHEDULED_SHEET = "scheduled-sheet"
internal const val SCHEDULE_FORM = "schedule-form"
internal const val SCHEDULED_BUTTON = "scheduled-button"

/** "Scheduled tasks, 3 enabled"; the header button's spoken label. */
internal fun scheduledButtonLabel(count: Int?): String = when (count) {
    null -> "Scheduled tasks"
    0 -> "Scheduled tasks, none enabled"
    else -> "Scheduled tasks, $count enabled"
}

/** Companion header entry: a clock with the number of enabled tasks (hidden until the list loads). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ScheduledButton(count: Int?, onClick: () -> Unit) {
    TooltipBox(positionProvider = TooltipDefaults.rememberPlainTooltipPositionProvider(),
        tooltip = { PlainTooltip { Text("Scheduled tasks") } }, state = rememberTooltipState()) {
        Row(Modifier.heightIn(min = 48.dp).widthIn(min = 48.dp).clip(RoundedCornerShape(24.dp))
            .clickable(onClickLabel = "Open scheduled tasks", role = Role.Button, onClick = onClick)
            .semantics { contentDescription = scheduledButtonLabel(count) }
            .padding(horizontal = 8.dp).testTag(SCHEDULED_BUTTON),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterHorizontally)) {
            Icon(painterResource(R.drawable.ic_schedule), contentDescription = null, modifier = Modifier.size(22.dp),
                tint = if ((count ?: 0) > 0) VerdeColors.Accent else VerdeColors.Text)
            if (count != null && count > 0) Text("$count", Modifier.clearAndSetSemantics {}, style = MaterialTheme.typography.labelMedium)
        }
    }
}

/** Phone time for "next in" labels; the list itself refreshes every 15 s. */
@Composable
private fun rememberScheduleNow(): Long {
    val clock = LocalUiClock.current
    val now by produceState(clock.now(), clock) {
        value = clock.now()
        while (clock.ticking) { delay(15_000); value = clock.now() }
    }
    return now
}

/** What the form edits: a new task (prefilled) or an existing one. */
internal sealed interface ScheduleFormRequest {
    data class New(val draft: ScheduleDraft) : ScheduleFormRequest
    data class Edit(val entry: ScheduleEntry) : ScheduleFormRequest
}

/**
 * Scheduled tasks, opened from the companion header: every task on the host with its repeat, next
 * run and last result; a switch, Run now, and a long-press menu (edit, delete). Tapping a row shows
 * the prompt as selectable text. Read-only without `can_edit`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ScheduledSheet(companion: CompanionModel, manage: ManageModel, browse: BrowseState, active: CompanionEntry,
    onOpenChat: (workspaceId: String, threadId: String) -> Unit, onDismiss: () -> Unit) {
    val state by companion.schedules.collectAsState()
    DisposableEffect(companion) {
        companion.setSchedulesOpen(true)
        onDispose { companion.setSchedulesOpen(false) }
    }
    LaunchedEffect(Unit) { companion.clearScheduleErrors() }
    val view = state.view
    val phoneNow = rememberScheduleNow()
    val now = state.clockNow(phoneNow)
    val home = scheduleHome(active)
    val canEdit = view?.can_edit == true
    val workspaces = browse.workspaces?.items.orEmpty()
    val defaultWorkspace = home.workspaceId.takeIf { ws -> workspaces.any { it.workspace_id == ws && it.open } }
        ?: mostRecentOpenWorkspace(workspaces)?.workspace_id
    var form by remember { mutableStateOf<ScheduleFormRequest?>(null) }
    var expanded by rememberSaveable { mutableStateOf<String?>(null) }
    var confirmDelete by remember { mutableStateOf<ScheduleEntry?>(null) }
    fun startNew(example: Boolean = false) {
        form = ScheduleFormRequest.New(if (example) exampleDraft(home, defaultWorkspace, phoneNow) else newDraft(home, defaultWorkspace, phoneNow))
    }

    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = VerdeColors.Panel,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), modifier = Modifier.testTag(SCHEDULED_SHEET)) {
        LiveOverModal()
        Column(Modifier.fillMaxWidth().fillMaxHeight(.9f)) {
            Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Scheduled", style = MaterialTheme.typography.titleLarge)
                    Text("Prompts that run on a timer and report back to ${home.name}.", style = MaterialTheme.typography.bodySmall,
                        color = VerdeColors.Muted)
                }
                if (canEdit && view?.schedules?.isNotEmpty() == true) TextButton(onClick = { startNew() }) {
                    Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(4.dp))
                    Text("New")
                }
            }
            HorizontalDivider(color = VerdeColors.Border)
            Box(Modifier.weight(1f).fillMaxWidth()) {
                when {
                    view?.supported == false -> ScheduleMessage(SCHEDULES_UNSUPPORTED)
                    view == null || (!view.loaded && view.error == null) -> ScheduleMessage(null)
                    !view.loaded -> ScheduleMessage(scheduleError(view.error), retry = companion::refreshSchedules)
                    view.schedules.isEmpty() -> EmptySchedules(home.name, canEdit, onNew = { startNew() }, onExample = { startNew(example = true) })
                    else -> LazyColumn(Modifier.fillMaxSize()) {
                        items(view.schedules, key = { it.id }) { entry ->
                            val run = state.lastRun?.takeIf { it.schedule_id == entry.id }
                            ScheduleRow(entry, state, now, canEdit, expanded = expanded == entry.id,
                                target = targetLabel(entry, home) { ws -> workspaces.find { it.workspace_id == ws }?.label },
                                onToggleExpand = { expanded = if (expanded == entry.id) null else entry.id },
                                onEnabled = { companion.setScheduleEnabled(entry, it) },
                                onRun = { companion.runSchedule(entry) },
                                onEdit = { form = ScheduleFormRequest.Edit(entry) },
                                onDelete = { confirmDelete = entry },
                                onOpenRun = run?.let { r -> { onOpenChat(r.workspace_id, r.thread_id) } })
                        }
                    }
                }
            }
            // A failed refresh keeps the last list; say so under it.
            val staleError = if (view != null && view.loaded && view.supported) view.error else null
            staleError?.let {
                Text(scheduleError(it), Modifier.padding(horizontal = 16.dp, vertical = 4.dp), style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error)
            }
            state.error?.let {
                Text(it, Modifier.padding(horizontal = 16.dp, vertical = 4.dp), style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error)
            }
            if (view?.loaded == true && view.supported && !canEdit) Text("Connect to the host to change scheduled tasks.",
                Modifier.padding(horizontal = 16.dp, vertical = 8.dp), style = MaterialTheme.typography.bodySmall, color = VerdeColors.Muted)
        }
    }
    form?.let { request ->
        ScheduleFormSheet(request, companion, manage, browse, home) { form = null }
    }
    confirmDelete?.let { entry ->
        val title = scheduleTitle(entry)
        AlertDialog(onDismissRequest = { confirmDelete = null },
            title = { LiveOverModal(); Text("Delete “$title”?") },
            text = { Text("It won't run again. Chats it already started stay on the host.") },
            confirmButton = {
                TextButton(onClick = { confirmDelete = null; if (expanded == entry.id) expanded = null; companion.deleteSchedule(entry) }) {
                    Text("Delete", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = null }) { Text("Cancel") } })
    }
}

/** A centered message, a spinner when [text] is null, with an optional retry. */
@Composable
private fun ScheduleMessage(text: String?, retry: (() -> Unit)? = null) {
    Column(Modifier.fillMaxSize().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically)) {
        if (text == null) CircularProgressIndicator()
        else SelectionContainer { Text(text, textAlign = TextAlign.Center, color = VerdeColors.Muted) }
        retry?.let { Button(onClick = it, shape = MaterialTheme.shapes.small) { Text("Try again") } }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun EmptySchedules(name: String, canEdit: Boolean, onNew: () -> Unit, onExample: () -> Unit) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically)) {
        Icon(painterResource(R.drawable.ic_schedule), contentDescription = null, tint = VerdeColors.Accent, modifier = Modifier.size(40.dp))
        Text("No scheduled tasks yet", style = MaterialTheme.typography.titleMedium)
        Text("A scheduled task sends a prompt to a chat at a set time, once or on repeat. The chat does the work and $name hears how it went.",
            style = MaterialTheme.typography.bodyMedium, color = VerdeColors.Muted, textAlign = TextAlign.Center)
        OutlinedCard(onClick = onExample, enabled = canEdit, modifier = Modifier.fillMaxWidth()
            .semantics { contentDescription = "Use the example: every weekday at 9, check CI and summarize" }) {
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("For example", style = MaterialTheme.typography.labelSmall, color = VerdeColors.Subtle)
                Text("“Every weekday at 9, check CI and summarize”", style = MaterialTheme.typography.bodyMedium)
            }
        }
        Button(onClick = onNew, enabled = canEdit, shape = MaterialTheme.shapes.small) {
            Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text("New scheduled task")
        }
        Text("Or ask $name: “remind me every morning to…”", style = MaterialTheme.typography.bodySmall, color = VerdeColors.Subtle,
            textAlign = TextAlign.Center)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ScheduleRow(entry: ScheduleEntry, state: ScheduleUiState, now: Long, canEdit: Boolean, expanded: Boolean, target: String,
    onToggleExpand: () -> Unit, onEnabled: (Boolean) -> Unit, onRun: () -> Unit, onEdit: () -> Unit, onDelete: () -> Unit,
    onOpenRun: (() -> Unit)?) {
    var menu by remember { mutableStateOf(false) }
    val busy = entry.id in state.view?.busy_ids.orEmpty()
    val enabled = state.enabled(entry)
    val title = scheduleTitle(entry)
    @Suppress("DEPRECATION") val clipboard = LocalClipboardManager.current
    Column(Modifier.fillMaxWidth()) {
        Box {
            Row(Modifier.fillMaxWidth().heightIn(min = 64.dp)
                .combinedClickable(onClickLabel = if (expanded) "Hide prompt" else "Show prompt", onLongClickLabel = "More actions",
                    onClick = onToggleExpand, onLongClick = { menu = true })
                .padding(start = 16.dp, end = 8.dp, top = 8.dp, bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(title, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        color = if (enabled) VerdeColors.Text else VerdeColors.Muted)
                    Text("${repeatLabel(entry, now)} · ${nextRunLabel(entry.copy(enabled = enabled), now)}",
                        style = MaterialTheme.typography.bodySmall, color = VerdeColors.Muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(lastRunLabel(entry, now), style = MaterialTheme.typography.labelSmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        color = if (lastRunFailed(entry)) MaterialTheme.colorScheme.error else VerdeColors.Subtle)
                }
                if (busy) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                IconButton(onClick = onRun, enabled = canEdit && !busy) {
                    Icon(Icons.Filled.PlayArrow, contentDescription = "Run $title now")
                }
                Switch(checked = enabled, onCheckedChange = onEnabled, enabled = canEdit && entry.id !in state.toggling,
                    modifier = Modifier.semantics { contentDescription = "$title enabled" })
            }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                LiveOverMenu()
                DropdownMenuItem(text = { Text("Run now") }, enabled = canEdit && !busy, onClick = { menu = false; onRun() })
                DropdownMenuItem(text = { Text("Edit") }, enabled = canEdit, onClick = { menu = false; onEdit() })
                DropdownMenuItem(text = { Text(if (enabled) "Pause" else "Resume") }, enabled = canEdit && entry.id !in state.toggling,
                    onClick = { menu = false; onEnabled(!enabled) })
                DropdownMenuItem(text = { Text("Copy prompt") }, onClick = { menu = false; clipboard.setText(AnnotatedString(entry.prompt)) })
                DropdownMenuItem(text = { Text("Delete…", color = MaterialTheme.colorScheme.error) }, enabled = canEdit,
                    onClick = { menu = false; onDelete() })
            }
        }
        onOpenRun?.let { open ->
            Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Started just now.", Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = VerdeColors.Accent)
                TextButton(onClick = open) { Text("Open chat") }
            }
        }
        if (expanded) Column(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            SelectionContainer {
                Text(entry.prompt, Modifier.fillMaxWidth().background(VerdeColors.PanelAlt, RoundedCornerShape(8.dp)).padding(10.dp),
                    style = MaterialTheme.typography.bodyMedium)
            }
            Text(target, style = MaterialTheme.typography.labelSmall, color = VerdeColors.Subtle)
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                TextButton(onClick = onEdit, enabled = canEdit) { Text("Edit") }
                TextButton(onClick = { clipboard.setText(AnnotatedString(entry.prompt)) }) { Text("Copy") }
                Spacer(Modifier.weight(1f))
                TextButton(onClick = onDelete, enabled = canEdit) { Text("Delete", color = if (canEdit) MaterialTheme.colorScheme.error else VerdeColors.Subtle) }
            }
        }
        HorizontalDivider(color = VerdeColors.Border)
    }
}

private enum class TimeFor { Once, Daily }

/** "New scheduled task" / "Edit scheduled task": prompt, name, where it sends, and when it repeats. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ScheduleFormSheet(request: ScheduleFormRequest, companion: CompanionModel, manage: ManageModel, browse: BrowseState,
    home: ScheduleHome, onDismiss: () -> Unit) {
    val state by companion.schedules.collectAsState()
    val original = (request as? ScheduleFormRequest.Edit)?.entry
    var draft by remember(request) {
        mutableStateOf(when (request) {
            is ScheduleFormRequest.New -> request.draft
            is ScheduleFormRequest.Edit -> draftOf(request.entry, home)
        })
    }
    val phoneNow = rememberNow(false)
    val zone = remember { ZoneId.systemDefault() }
    val canEdit = state.view?.can_edit == true
    val problem = draftProblem(draft, home, phoneNow, original)
    val workspaces = browse.workspaces?.items.orEmpty()
    val open = workspaces.filter { it.open }
    var pickDate by remember { mutableStateOf(false) }
    var pickTime by remember { mutableStateOf<TimeFor?>(null) }
    LaunchedEffect(Unit) { companion.clearScheduleErrors() }

    // A new chat's workspace defaults to the companion's home, else the most recent one.
    LaunchedEffect(draft.sendTo, open.map { it.workspace_id }) {
        if (draft.sendTo == ScheduleSendTo.NewChat && draft.workspaceId.isEmpty()) {
            (home.workspaceId.takeIf { ws -> open.any { it.workspace_id == ws } } ?: mostRecentOpenWorkspace(open)?.workspace_id)
                ?.let { draft = draft.copy(workspaceId = it) }
        }
    }
    // Providers and models come from the same source as New chat, for the chosen workspace.
    val manageState by manage.state.collectAsState()
    val ws = draft.workspaceId
    LaunchedEffect(draft.sendTo, ws, draft.provider, manageState.hostId, manageState.view != null) {
        if (draft.sendTo == ScheduleSendTo.NewChat && ws.isNotEmpty() && manageState.view != null)
            manage.select(ws, ChatSelection(provider = draft.provider.ifEmpty { null }))
    }
    val chat = manageState.view?.new_chat?.takeIf { it.workspace_id == ws }
    LaunchedEffect(chat?.selection?.provider, draft.sendTo) {
        val provider = chat?.selection?.provider
        if (draft.sendTo == ScheduleSendTo.NewChat && draft.provider.isEmpty() && provider != null) draft = draft.copy(provider = provider)
    }

    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = VerdeColors.Panel,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), modifier = Modifier.testTag(SCHEDULE_FORM)) {
        LiveOverModal()
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
            Text(if (original == null) "New scheduled task" else "Edit scheduled task", Modifier.padding(horizontal = 16.dp),
                style = MaterialTheme.typography.titleLarge)
            OutlinedTextField(draft.prompt, onValueChange = { draft = draft.copy(prompt = it) }, label = { Text("Prompt") },
                placeholder = { Text("Check CI for every workspace and summarize what failed.") }, minLines = 3, maxLines = 10,
                enabled = canEdit, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).testTag("schedule-prompt"))
            OutlinedTextField(draft.name, onValueChange = { draft = draft.copy(name = clipUtf8(it.replace('\n', ' '), SCHEDULE_MAX_NAME_BYTES)) },
                label = { Text("Name (optional)") }, singleLine = true, enabled = canEdit,
                supportingText = { Text("Defaults to the prompt's first line.") },
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp).testTag("schedule-name"))

            VerdeSection("Send to")
            Column(Modifier.selectableGroup()) {
                ChoiceRow("${home.name}'s chat", if (home.ready) "Each run is a message in this conversation." else "Available once ${home.name}'s chat is set up.",
                    selected = draft.sendTo == ScheduleSendTo.Companion, enabled = canEdit && home.ready) {
                    draft = draft.copy(sendTo = ScheduleSendTo.Companion)
                }
                if (original != null && draftOf(original, home).sendTo == ScheduleSendTo.ExistingChat) {
                    val where = workspaces.find { it.workspace_id == original.target_workspace_id }?.label ?: "another workspace"
                    ChoiceRow("Its current chat", "A chat in $where", selected = draft.sendTo == ScheduleSendTo.ExistingChat, enabled = canEdit) {
                        draft = draft.copy(sendTo = ScheduleSendTo.ExistingChat, workspaceId = original.target_workspace_id, threadId = original.target_thread_id)
                    }
                }
                ChoiceRow("A new chat in a workspace", "Each run starts a fresh chat; ${home.name} hears how it went.",
                    selected = draft.sendTo == ScheduleSendTo.NewChat, enabled = canEdit) {
                    draft = draft.copy(sendTo = ScheduleSendTo.NewChat,
                        workspaceId = if (draft.sendTo == ScheduleSendTo.ExistingChat) "" else draft.workspaceId)
                }
            }
            if (draft.sendTo == ScheduleSendTo.NewChat) {
                val choices = open.map { ChatChoice(it.workspace_id, it.label) }.let { list ->
                    if (ws.isEmpty() || list.any { it.id == ws }) list
                    else list + ChatChoice(ws, workspaces.find { it.workspace_id == ws }?.label ?: "Current workspace")
                }
                Picker("Workspace", choices.find { it.id == ws }?.label ?: "Choose a workspace", choices, canEdit) {
                    if (it != ws) draft = draft.copy(workspaceId = it)
                }
                val providers = chat?.providers.orEmpty()
                val providerLabel = providers.find { it.id == draft.provider }?.label
                    ?: PROVIDERS.find { it.first == draft.provider }?.second ?: draft.provider.ifEmpty { "Provider" }
                Picker("Provider", providerLabel, providers, canEdit && chat != null, providerIcons = true) {
                    if (it != draft.provider) draft = draft.copy(provider = it, model = "")
                }
                val catalog = chat?.takeIf { it.selection.provider == draft.provider && !it.loading }?.catalogs?.models.orEmpty()
                val models = listOf(ChatChoice("", "Default")) + catalog
                Picker("Model", models.find { it.id == draft.model }?.label ?: draft.model, models, canEdit && catalog.isNotEmpty()) {
                    draft = draft.copy(model = it)
                }
                if (chat == null && ws.isNotEmpty()) LinearProgressIndicator(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp))
            }

            VerdeSection("Repeat")
            ChipRow {
                RepeatChoice.entries.forEach { choice ->
                    FilterChip(selected = draft.repeat == choice, onClick = { draft = draft.copy(repeat = choice) }, enabled = canEdit,
                        label = { Text(when (choice) { RepeatChoice.Once -> "Once"; RepeatChoice.Interval -> "Every…"; RepeatChoice.Daily -> "Daily" }) })
                }
            }
            when (draft.repeat) {
                RepeatChoice.Once -> {
                    val at = draft.atMs ?: nextHourMs(phoneNow, zone)
                    val local = Instant.ofEpochMilli(at).atZone(zone)
                    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(onClick = { pickDate = true }, enabled = canEdit, shape = MaterialTheme.shapes.small, modifier = Modifier.weight(1f)
                            .semantics { contentDescription = "Date, ${whenLabel(at, phoneNow, zone).substringBeforeLast(' ')}" }) {
                            Text(whenLabel(at, phoneNow, zone).substringBeforeLast(' '), maxLines = 1)
                        }
                        OutlinedButton(onClick = { pickTime = TimeFor.Once }, enabled = canEdit, shape = MaterialTheme.shapes.small, modifier = Modifier.weight(1f)
                            .semantics { contentDescription = "Time, ${clockLabel(local.hour, local.minute)}" }) {
                            Text(clockLabel(local.hour, local.minute))
                        }
                    }
                    Hint("Runs once, then turns itself off.")
                }
                RepeatChoice.Interval -> {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedTextField(draft.every, onValueChange = { draft = draft.copy(every = it.filter(Char::isDigit).take(5)) },
                            label = { Text("Every") }, singleLine = true, enabled = canEdit, modifier = Modifier.width(112.dp).testTag("schedule-every"),
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                        IntervalUnit.entries.forEach { unit ->
                            FilterChip(selected = draft.unit == unit, onClick = { draft = draft.copy(unit = unit) }, enabled = canEdit,
                                label = { Text(if (unit == IntervalUnit.Minutes) "minutes" else "hours") })
                        }
                    }
                    Hint("Between 5 minutes and 7 days.")
                }
                RepeatChoice.Daily -> {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
                        OutlinedButton(onClick = { pickTime = TimeFor.Daily }, enabled = canEdit, shape = MaterialTheme.shapes.small,
                            modifier = Modifier.semantics { contentDescription = "Time, ${draft.time}" }) { Text("At ${draft.time}") }
                    }
                    ChipRow {
                        DayPreset.entries.forEach { preset ->
                            FilterChip(selected = draft.days == preset, onClick = { draft = draft.copy(days = preset) }, enabled = canEdit,
                                label = { Text(when (preset) { DayPreset.Every -> "Every day"; DayPreset.Weekdays -> "Weekdays"; DayPreset.Custom -> "Custom" }) })
                        }
                    }
                    if (draft.days == DayPreset.Custom) ChipRow {
                        DAY_ORDER.forEach { day ->
                            val on = day in draft.customDays
                            FilterChip(selected = on, enabled = canEdit, label = { Text(DAY_SHORT[day]) },
                                onClick = { draft = draft.copy(customDays = if (on) draft.customDays - day else draft.customDays + day) })
                        }
                    }
                    Hint("On your desktop's clock.")
                }
            }

            val shownError = state.formError ?: problem?.takeIf { draft.prompt.isNotBlank() || original != null }
            shownError?.let {
                Text(it, Modifier.padding(horizontal = 16.dp, vertical = 4.dp), style = MaterialTheme.typography.bodySmall,
                    color = if (state.formError != null) MaterialTheme.colorScheme.error else VerdeColors.Muted)
            }
            if (!canEdit) Text("Connect to the host to save scheduled tasks.", Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                style = MaterialTheme.typography.bodySmall, color = VerdeColors.Muted)
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onDismiss) { Text("Cancel") }
                Button(onClick = { companion.saveSchedule(original, draft, home, onSaved = onDismiss) },
                    enabled = canEdit && !state.saving && problem == null, shape = MaterialTheme.shapes.small,
                    modifier = Modifier.testTag("schedule-save")) {
                    Text(when {
                        state.saving -> "Saving…"
                        original == null -> "Schedule"
                        else -> "Save"
                    })
                }
            }
        }
    }

    if (pickDate) {
        val current = Instant.ofEpochMilli(draft.atMs ?: nextHourMs(phoneNow, zone)).atZone(zone)
        val picker = rememberDatePickerState(initialSelectedDateMillis = current.toLocalDate().atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli())
        DatePickerDialog(onDismissRequest = { pickDate = false },
            confirmButton = {
                TextButton(onClick = {
                    picker.selectedDateMillis?.let { utc ->
                        val date = Instant.ofEpochMilli(utc).atZone(ZoneOffset.UTC).toLocalDate()
                        draft = draft.copy(atMs = localAtMs(date, current.hour, current.minute, zone))
                    }
                    pickDate = false
                }) { Text("OK") }
            },
            dismissButton = { TextButton(onClick = { pickDate = false }) { Text("Cancel") } }) {
            LiveOverModal()
            DatePicker(state = picker)
        }
    }
    pickTime?.let { target ->
        val context = LocalContext.current
        val (hour, minute) = when (target) {
            TimeFor.Once -> Instant.ofEpochMilli(draft.atMs ?: nextHourMs(phoneNow, zone)).atZone(zone).let { it.hour to it.minute }
            TimeFor.Daily -> parseTime(draft.time)
        }
        val picker = rememberTimePickerState(initialHour = hour, initialMinute = minute, is24Hour = DateFormat.is24HourFormat(context))
        AlertDialog(onDismissRequest = { pickTime = null },
            confirmButton = {
                TextButton(onClick = {
                    draft = when (target) {
                        TimeFor.Once -> {
                            val date = Instant.ofEpochMilli(draft.atMs ?: nextHourMs(phoneNow, zone)).atZone(zone).toLocalDate()
                            draft.copy(atMs = localAtMs(date, picker.hour, picker.minute, zone))
                        }
                        TimeFor.Daily -> draft.copy(time = clockLabel(picker.hour, picker.minute))
                    }
                    pickTime = null
                }) { Text("OK") }
            },
            dismissButton = { TextButton(onClick = { pickTime = null }) { Text("Cancel") } },
            text = { LiveOverModal(); TimePicker(state = picker) })
    }
}

@Composable
private fun ChipRow(content: @Composable RowScope.() -> Unit) {
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically, content = content)
}

@Composable
private fun Hint(text: String) {
    Text(text, Modifier.padding(horizontal = 16.dp, vertical = 2.dp), style = MaterialTheme.typography.bodySmall, color = VerdeColors.Subtle)
}

@Composable
private fun ChoiceRow(label: String, detail: String, selected: Boolean, enabled: Boolean, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).selectable(selected = selected, enabled = enabled, role = Role.RadioButton, onClick = onClick)
        .padding(horizontal = 16.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        RadioButton(selected = selected, onClick = null, enabled = enabled)
        Column(Modifier.weight(1f)) {
            Text(label, style = MaterialTheme.typography.bodyMedium, color = if (enabled) VerdeColors.Text else VerdeColors.Subtle)
            Text(detail, style = MaterialTheme.typography.labelSmall, color = VerdeColors.Subtle)
        }
    }
}
