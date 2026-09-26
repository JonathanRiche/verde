package dev.verdeai.app

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.pm.PackageManager
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.ui.res.painterResource
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.foundation.clickable
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import dev.verdeai.core.*
import kotlinx.coroutines.launch

internal const val COMPOSER = "composer"
internal const val COMPOSER_FIELD = "composer-field"
internal const val COMPOSER_SEND = "composer-send"
internal const val COMPOSER_STOP = "composer-stop"
internal const val COMPOSER_ATTACH = "composer-attach"
internal const val COMPOSER_NOTICE = "composer-notice"
internal const val COMPOSER_FOLLOWUP = "composer-followup"
internal const val COMPOSER_SUGGESTIONS = "composer-suggestions"
internal const val COMPOSER_SHELL = "composer-shell"
internal const val COMPOSER_PICKER = "composer-picker"

private val DELIVERY_LABELS = mapOf("unsent" to "Not sent", "sending" to "Sending", "uncertain" to "Unconfirmed", "accepted" to "Delivered")

/** Web `followupHint`, plus the core's paused state (restored follow-ups never auto-send). */
internal fun followupHint(pending: ChatFollowup?, kind: EventFollowupSubmitKind): String = when {
    pending?.delivery == "uncertain" -> "Delivery is unconfirmed. Retry to check recorded delivery."
    pending?.delivery == "sending" -> "Sending follow-up…"
    pending?.state == "sent_inline" -> "Steer applied to the current reply."
    pending != null && pending.paused && pending.delivery == "unsent" -> "Paused after a reconnect. Retry to send it."
    pending != null -> if (pending.state == "fallback_next_turn") "Steering unavailable. Queued for the next turn." else "Queued. Sends after the current reply."
    kind == EventFollowupSubmitKind.steer -> "Send to steer the current reply."
    else -> "Send to queue after the current reply."
}

internal fun followupTitle(f: ChatFollowup) = when {
    f.state == "sent_inline" -> "Steer delivered"
    f.state == "fallback_next_turn" || f.kind == "queue" -> "Queued follow-up"
    else -> "Steer follow-up"
}

/** The send button's verb for this draft and turn. */
internal fun sendLabel(text: String, running: Boolean, kind: EventFollowupSubmitKind) = when (composerAction(text)) {
    ComposerAction.Shell, is ComposerAction.Slash -> "Run"
    else -> if (!running) "Send" else if (kind == EventFollowupSubmitKind.steer) "Steer" else "Queue"
}

private fun attachmentSize(bytes: Long) = if (bytes < 1024 * 1024) "${(bytes + 1023) / 1024} KB" else "%.1f MB".format(bytes / (1024.0 * 1024.0))

/** D-08: the chat composer in the transcript's bottom bar. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
internal fun ChatComposer(model: TranscriptModel, state: TranscriptState) {
    val composer = model.composer
    val view = state.composer
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val lifecycle = LocalLifecycleOwner.current
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) composer.flushNow() }
        lifecycle.lifecycle.addObserver(observer)
        onDispose { lifecycle.lifecycle.removeObserver(observer) }
    }

    fun add(uris: List<Uri>, camera: Boolean = false) = scope.launch {
        val prepared = ImageAttachments.prepare(context, uris)
        if (camera) ImageAttachments.clearCamera(context)
        composer.attach(prepared.images, prepared.rejected)
    }
    val photos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(ComposerModel.MAX_IMAGES)) { if (it.isNotEmpty()) add(it) }
    val files = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { if (it.isNotEmpty()) add(it) }
    var cameraUri by rememberSaveable { mutableStateOf<Uri?>(null) }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok ->
        val uri = cameraUri
        cameraUri = null
        if (ok && uri != null) add(listOf(uri), camera = true) else ImageAttachments.clearCamera(context)
    }
    fun startCamera() {
        val uri = ImageAttachments.cameraTarget(context)
        cameraUri = uri
        try { camera.launch(uri) } catch (_: ActivityNotFoundException) { composer.showNotice("No camera app is available.") }
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) startCamera() else composer.showNotice("Camera access is off. Allow it in Settings to take photos.")
    }

    val fieldFocus = remember { FocusRequester() }
    LaunchedEffect(composer.focusRequest) { if (composer.focusRequest > 0) fieldFocus.requestFocus() }
    var picker by remember { mutableStateOf<ComposerPicker?>(null) }
    val running = state.turn != null
    val provider = view?.selection?.provider ?: state.thread?.thread?.provider
    val attachments = view?.draft?.attachments.orEmpty()
    val kind = followupKind(provider, attachments.isNotEmpty())
    val sendPending = view?.send_operation?.state == "pending"
    val text = composer.field.text
    val action = composerAction(text)
    val hasContent = text.isNotBlank() || attachments.isNotEmpty()
    val ready = view?.provider_ready == true
    val canSubmit = view != null && hasContent && !composer.busy && !sendPending && when {
        action is ComposerAction.Slash -> ready
        running -> ready && (action == ComposerAction.Shell || view.followup == null)
        else -> view.can_send
    }

    var composerFocused by remember { mutableStateOf(false) }
    Surface(color = VerdeColors.Panel, shape = RoundedCornerShape(14.dp),
        border = BorderStroke(if (composerFocused) 1.5.dp else 1.dp,
            if (composerFocused) VerdeColors.Accent else VerdeColors.PanelMuted),
        modifier = Modifier.fillMaxWidth().imePadding().padding(horizontal = 8.dp, vertical = 6.dp).testTag(COMPOSER)
            .onFocusChanged { composerFocused = it.hasFocus }.focusGroup()) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            view?.followup?.let { FollowupCard(it, composer, kind) }
            val notice = composer.notice ?: composerError(view?.error)
            if (notice != null) {
                Text(notice, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.testTag(COMPOSER_NOTICE).semantics { liveRegion = LiveRegionMode.Polite })
            }
            Suggestions(composer, view)
            if (attachments.isNotEmpty()) Attachments(attachments, sendPending || composer.busy, composer)
            BasicTextField(
                value = composer.field,
                onValueChange = { if (!sendPending) composer.edit(it) },
                modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp).focusRequester(fieldFocus).testTag(COMPOSER_FIELD),
                readOnly = sendPending,
                decorationBox = { innerTextField ->
                    Box(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
                        if (text.isEmpty()) Text(when {
                            view == null -> "Loading…"
                            !ready -> "Offline. Your draft is kept."
                            running -> followupHint(null, kind)
                            else -> "Message"
                        }, color = VerdeColors.Subtle, style = MaterialTheme.typography.bodyLarge,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                        innerTextField()
                    }
                },
                cursorBrush = SolidColor(VerdeColors.Accent),
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = VerdeColors.Text),
                maxLines = 6,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
            )
            FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                AttachButton(enabled = view != null && !sendPending && !composer.busy,
                    onPhotos = { photos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
                    onCamera = {
                        if (context.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) startCamera()
                        else permission.launch(Manifest.permission.CAMERA)
                    },
                    onFiles = { files.launch(arrayOf("image/*")) })
                IconButton(onClick = composer::openSlashCommands,
                    enabled = ready && !sendPending && !composer.busy && (text.isBlank() || composer.slash != null),
                    modifier = Modifier.semantics { contentDescription = "Slash commands" }) {
                    Text("/", style = MaterialTheme.typography.titleMedium, color = VerdeColors.Muted)
                }
                if (view != null) SettingsControls(view, state, provider) { picker = it }
                if (running) {
                    StopControl(state.stopping, state.canStop, model::stop, Modifier.testTag(COMPOSER_STOP))
                }
                SendControl(label = if (sendPending || composer.busy) "Sending…" else sendLabel(text, running, kind),
                    enabled = canSubmit, onClick = composer::submit, modifier = Modifier.testTag(COMPOSER_SEND))
            }
            if (running && view?.followup == null) Text(followupHint(null, kind),
                color = VerdeColors.Subtle, style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.testTag("composer-action-hint"))
        }
    }

    val open = picker
    if (open != null && view != null) {
        PickerSheet(open, view, provider, onDismiss = { picker = null }) { id -> picker = null; composer.select(open, id) }
    }
    view?.shell_confirmation?.let { ShellSheet(it, composer) }
}

@Composable
private fun AttachButton(enabled: Boolean, onPhotos: () -> Unit, onCamera: () -> Unit, onFiles: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { menu = true }, enabled = enabled, modifier = Modifier.testTag(COMPOSER_ATTACH)) {
            Icon(painterResource(R.drawable.composer_attach), contentDescription = "Attach image", modifier = Modifier.size(18.dp))
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text("Photos") }, onClick = { menu = false; onPhotos() })
            DropdownMenuItem(text = { Text("Camera") }, onClick = { menu = false; onCamera() })
            DropdownMenuItem(text = { Text("Image files") }, onClick = { menu = false; onFiles() })
        }
    }
}

@Composable
private fun FollowupCard(f: ChatFollowup, composer: ComposerModel, kind: EventFollowupSubmitKind) {
    Card(Modifier.fillMaxWidth().testTag(COMPOSER_FOLLOWUP).semantics { contentDescription = "Follow-up" },
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)) {
        Column(Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(followupTitle(f), fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                Text(DELIVERY_LABELS[f.delivery] ?: f.delivery, style = MaterialTheme.typography.labelMedium)
            }
            if (f.text.isNotEmpty()) Text(f.text, maxLines = 4, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium)
            if (f.attachments.isNotEmpty()) Text(if (f.attachments.size == 1) "1 image" else "${f.attachments.size} images", style = MaterialTheme.typography.labelMedium)
            Text(followupHint(f, kind), style = MaterialTheme.typography.bodySmall, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
            if (f.delivery == "uncertain" || f.delivery == "accepted") {
                Text("This follow-up cannot be recalled while delivery is unconfirmed or already accepted.", style = MaterialTheme.typography.bodySmall)
            }
            composerError(f.error)?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                if (f.delivery == "unsent" && f.can_pull_back) {
                    TextButton(onClick = { composer.pullBackFollowup(f) }, enabled = !composer.busy) { Text("Pull back to edit") }
                    TextButton(onClick = { composer.cancelFollowup(f) }, enabled = !composer.busy) { Text("Remove") }
                }
                if (f.can_retry && (f.delivery == "unsent" || f.delivery == "uncertain")) {
                    TextButton(onClick = { composer.retryFollowup(f) }, enabled = !composer.busy) { Text("Retry") }
                }
            }
        }
    }
}

@Composable
private fun Suggestions(composer: ComposerModel, view: ChatComposerView?) {
    val slash = composer.slash
    val mention = composer.mention
    val rows: List<Pair<String, () -> Unit>> = when {
        view == null -> emptyList()
        slash != null -> {
            val prefix = "/" + slash.query
            view.catalogs.slash.map { it to if (it.label.startsWith("/")) it.label else "/" + it.label }
                .filter { (c, name) -> c.enabled && name.startsWith(prefix, ignoreCase = true) }
                .map { (_, name) -> name to { composer.acceptSlash(name) } }
        }
        mention != null -> view.mentions.take(8).map { m -> m.path to { composer.acceptMention(m.path) } }
        else -> emptyList()
    }
    if (slash != null) {
        Column(Modifier.fillMaxWidth().heightIn(max = 168.dp).verticalScroll(rememberScrollState()).testTag(COMPOSER_SUGGESTIONS)) {
            VerdeSection("Commands")
            if (rows.isEmpty()) Text(if (composer.slashLoading) "Loading commands…" else "No matching commands for this provider.",
                color = VerdeColors.Subtle, style = MaterialTheme.typography.bodySmall)
            for ((label, accept) in rows) TextButton(onClick = accept, modifier = Modifier.fillMaxWidth().heightIn(min = 44.dp)) {
                Text(label, modifier = Modifier.fillMaxWidth(), color = VerdeColors.Text)
            }
        }
        return
    }
    if (rows.isEmpty()) return
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).testTag(COMPOSER_SUGGESTIONS), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        for ((label, accept) in rows) {
            SuggestionChip(onClick = accept, label = { Text(label, maxLines = 1, overflow = TextOverflow.Ellipsis) })
        }
    }
}

@Composable
private fun Attachments(items: List<ChatAttachment>, locked: Boolean, composer: ComposerModel) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        for (a in items) {
            val size = a.byte_size.toLongOrNull() ?: 0L
            val uploaded = a.uploaded_bytes.toLongOrNull() ?: 0L
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                composer.imagePreviews[a.local_id]?.let { DraftImagePreview(it, a.name) }
                Column(Modifier.weight(1f)) {
                    Text("${a.name} · ${attachmentSize(size)}", maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall)
                    if (a.status == "uploading" || (locked && uploaded in 1 until size)) {
                        LinearProgressIndicator(progress = { if (size > 0) (uploaded.toFloat() / size).coerceIn(0f, 1f) else 0f },
                            modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Uploading ${a.name}" })
                    }
                    composerError(a.error)?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                }
                if (!locked) IconButton(onClick = { composer.detach(a.local_id) }) { Icon(Icons.Filled.Close, contentDescription = "Remove ${a.name}") }
            }
        }
    }
}

private fun label(choices: List<ChatChoice>, id: String?) = choices.find { it.id == (id ?: "") }?.label ?: choices.firstOrNull()?.label

@Composable
private fun SettingsControls(view: ChatComposerView, state: TranscriptState, provider: String?, open: (ComposerPicker) -> Unit) {
    val c = view.catalogs
    val s = view.selection
    // Like the desktop, the provider is fixed once a conversation has started.
    val fresh = state.thread?.rows?.isEmpty() == true && state.turn == null

        val providerLabel = PROVIDERS.find { it.first == provider }?.second ?: provider ?: "Provider"
        if (fresh) SettingChip("Provider", providerLabel) { open(ComposerPicker.Provider) }
        SettingChip("Model", label(c.models, s.model ?: c.models.firstOrNull()?.id) ?: "Model", provider) { open(ComposerPicker.Model) }
        if (c.efforts.isNotEmpty()) SettingChip("Effort", label(c.efforts, s.effort) ?: "Default") { open(ComposerPicker.Effort) }
        if (c.access.isNotEmpty()) SettingChip("Access", label(c.access, s.access) ?: "Access") { open(ComposerPicker.Access) }
        if (c.speeds.size > 1) SettingChip("Speed", label(c.speeds, s.speed) ?: "Speed") { open(ComposerPicker.Speed) }
}

@Composable
private fun SettingChip(name: String, value: String, provider: String? = null, onClick: () -> Unit) {
    AssistChip(onClick = onClick, leadingIcon = provider?.let { { ProviderGlyph(it, Modifier.size(14.dp)) } }, label = { Text(value, style = MaterialTheme.typography.labelMedium,
        maxLines = 1, overflow = TextOverflow.Ellipsis) },
        shape = RoundedCornerShape(14.dp), border = null,
        colors = AssistChipDefaults.assistChipColors(containerColor = VerdeColors.PanelAlt, labelColor = VerdeColors.Muted),
        modifier = Modifier.semantics { contentDescription = "$name: $value. Change" })
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PickerSheet(kind: ComposerPicker, view: ChatComposerView, provider: String?, onDismiss: () -> Unit, onPick: (String) -> Unit) {
    val c = view.catalogs
    val s = view.selection
    val (title, choices, current) = when (kind) {
        ComposerPicker.Provider -> Triple("Provider", PROVIDERS.map { ChatChoice(it.first, it.second) }, provider)
        // Desktop favourites first, otherwise in catalog order.
        ComposerPicker.Model -> Triple("Model", c.models.sortedByDescending { it.favorite }, s.model ?: c.models.firstOrNull()?.id)
        ComposerPicker.Effort -> Triple("Reasoning effort", c.efforts, s.effort ?: "")
        ComposerPicker.Access -> Triple("Access", c.access, s.access ?: c.access.firstOrNull()?.id)
        ComposerPicker.Speed -> Triple("Speed", c.speeds, s.speed ?: c.speeds.firstOrNull()?.id)
    }
    ModalBottomSheet(onDismissRequest = onDismiss, modifier = Modifier.testTag(COMPOSER_PICKER)) {
        Text(title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp))
        LazyColumn(Modifier.fillMaxWidth().padding(bottom = 16.dp)) {
            items(choices, key = { it.id }) { choice ->
                val selected = choice.id == current
                VerdeListRow(
                    headlineContent = { Text(choice.label) },
                    supportingContent = if (!choice.enabled) ({ Text(choice.reason ?: "Unavailable") }) else null,
                    leadingContent = if (kind == ComposerPicker.Provider) ({ ProviderGlyph(choice.id) }) else if (choice.favorite) ({ Icon(Icons.Filled.Star, contentDescription = "Favourite") }) else null,
                    trailingContent = if (selected) ({ Icon(Icons.Filled.Check, contentDescription = "Selected") }) else null,
                    modifier = Modifier.fillMaxWidth().clickable(enabled = choice.enabled && !selected) { onPick(choice.id) },
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ShellSheet(confirmation: ChatShellConfirmation, composer: ComposerModel) {
    ModalBottomSheet(onDismissRequest = { composer.confirmShell(confirmation, false) }, modifier = Modifier.testTag(COMPOSER_SHELL)) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Run this command on the host?", style = MaterialTheme.typography.titleMedium)
            Surface(color = MaterialTheme.colorScheme.surfaceVariant, shape = MaterialTheme.shapes.small) {
                Text(confirmation.command, fontFamily = VerdeMono, modifier = Modifier.fillMaxWidth().padding(10.dp))
            }
            if (confirmation.cwd.isNotEmpty()) Text("In ${confirmation.cwd}", style = MaterialTheme.typography.bodySmall)
            Text("It runs in a terminal with your desktop's permissions.", style = MaterialTheme.typography.bodySmall)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = { composer.confirmShell(confirmation, false) }, enabled = !composer.busy) { Text("Cancel") }
                Button(onClick = { composer.confirmShell(confirmation, true) }, enabled = !composer.busy) { Text("Run") }
            }
        }
    }
}
