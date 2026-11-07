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
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.foundation.clickable
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
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
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import dev.verdeai.core.*
import kotlinx.coroutines.launch

internal const val COMPOSER = "composer"

/** The chat screen's handle on the composer's text field, so focus can be sent to it (A5-3). */
internal val LocalComposerFocus = staticCompositionLocalOf<FocusRequester?> { null }
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
    pending != null && pending.kind == "interrupt" -> "Stopping the current reply to continue with this\u2026"
    pending != null -> if (pending.state == "fallback_next_turn") "Steering unavailable. Queued for the next turn." else "Queued. Sends after the current reply."
    else -> followupKindHint(kind)
}

internal fun followupTitle(f: ChatFollowup) = when {
    f.state == "sent_inline" -> "Steer delivered"
    f.state == "fallback_next_turn" || f.kind == "queue" -> "Queued follow-up"
    else -> "Steer follow-up"
}

/** The send button's verb for this draft and turn. */
internal fun sendLabel(text: String, running: Boolean, kind: EventFollowupSubmitKind) = when (composerAction(text)) {
    ComposerAction.Shell, is ComposerAction.Slash -> "Run"
    else -> if (!running) "Send" else when (kind) {
        EventFollowupSubmitKind.steer -> "Steer"
        EventFollowupSubmitKind.interrupt -> "Interrupt"
        EventFollowupSubmitKind.queue -> "Queue"
    }
}

/** What sending now does while a turn runs (placeholder / hint, shown once). */
internal fun followupKindHint(kind: EventFollowupSubmitKind): String = when (kind) {
    EventFollowupSubmitKind.steer -> "Steer the current reply"
    EventFollowupSubmitKind.interrupt -> "Interrupts and continues with this"
    EventFollowupSubmitKind.queue -> "Queue after the current reply"
}

private fun attachmentSize(bytes: Long) = if (bytes < 1024 * 1024) "${(bytes + 1023) / 1024} KB" else "%.1f MB".format(bytes / (1024.0 * 1024.0))

/** D-08: the chat composer in the transcript's bottom bar. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
internal fun ChatComposer(model: TranscriptModel, state: TranscriptState,
    /** Companion sheet: one row (settings chip, growing input, [inlineAction], send); no resize handle or toolbars. */
    compact: Boolean = false, inlineAction: (@Composable () -> Unit)? = null,
    /** Compact only: the model chip becomes a read-only label that calls this (e.g. Settings → Brain). */
    onBrain: (() -> Unit)? = null,
    /** Compact only: the idle placeholder ("Message Moss…"). */
    placeholderText: String? = null) {
    val composer = model.composer
    val view = state.composer?.let { current ->
        composer.pendingSelection?.let { current.copy(selection = it) } ?: current
    }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val lifecycle = LocalLifecycleOwner.current
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) composer.flushNow() }
        lifecycle.lifecycle.addObserver(observer)
        onDispose { lifecycle.lifecycle.removeObserver(observer) }
    }

    fun add(uris: List<Uri>, camera: Boolean = false) = scope.launch {
        // Never decode more than a message can carry (the file picker has no count limit).
        val picked = uris.take(ComposerModel.MAX_IMAGES)
        val prepared = ImageAttachments.prepare(context, picked)
        if (camera) ImageAttachments.clearCamera(context)
        composer.attach(prepared.images, prepared.rejected, overflow = uris.size - picked.size)
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

    val fieldFocus = LocalComposerFocus.current ?: remember { FocusRequester() }
    val focusManager = androidx.compose.ui.platform.LocalFocusManager.current
    val imeVisibleNow = WindowInsets.isImeVisible
    val shellFocus = LocalShellFocus.current
    LaunchedEffect(composer.focusRequest) { if (composer.focusRequest > 0) fieldFocus.requestFocus() }
    var picker by remember { mutableStateOf<ComposerPicker?>(null) }
    val running = state.turn != null
    val provider = view?.selection?.provider ?: state.thread?.thread?.provider
    val attachments = view?.draft?.attachments.orEmpty()
    val kind = followupKind(provider, attachments.isNotEmpty())
    val alternatives = followupAlternatives(provider, attachments.isNotEmpty())
    var sendMenu by remember { mutableStateOf(false) }
    // Send; while a turn runs a long-press offers steer / interrupt / queue.
    val sendButton = @Composable { canSend: Boolean ->
        val label = if (view?.send_operation?.state == "pending" || composer.busy) "Sending…" else sendLabel(composer.field.text, state.turn != null, kind)
        val followup = state.turn != null && composerAction(composer.field.text).let { it == ComposerAction.Prompt || it is ComposerAction.Literal }
        Box {
            SendControl(label = label, enabled = canSend, onClick = {
                // A6-5: a send keeps the keyboard as it was: closed stays closed.
                val keyboardWasUp = imeVisibleNow
                composer.submit()
                if (!keyboardWasUp) { focusManager.clearFocus(); shellFocus?.let { runCatching { it.requestFocus() } } }
            }, modifier = Modifier.testTag(COMPOSER_SEND),
                onLongClick = if (followup) ({ sendMenu = true }) else null)
            DropdownMenu(expanded = sendMenu, onDismissRequest = { sendMenu = false }) {
                LiveOverMenu()
                alternatives.forEach { option ->
                    DropdownMenuItem(text = { Text(followupChoiceLabel(option)) }, onClick = { sendMenu = false; composer.submitAs(option) })
                }
            }
        }
    }
    val sendPending = view?.send_operation?.state == "pending"
    val text = composer.field.text
    val action = composerAction(text)
    val hasContent = text.isNotBlank() || attachments.isNotEmpty()
    val ready = view?.provider_ready == true
    val canSubmit = view != null && hasContent && composer.pendingSelection == null && !composer.busy && !sendPending && when {
        action is ComposerAction.Slash -> ready
        running -> ready && (action == ComposerAction.Shell || view.followup == null)
        else -> view.can_send
    }

    val density = LocalDensity.current
    val screenHeight = LocalConfiguration.current.screenHeightDp.dp
    val keyboardHeight = with(density) { WindowInsets.ime.getBottom(this).toDp() }
    val maxFieldHeight = ((screenHeight - keyboardHeight) * .6f).coerceAtLeast(56.dp)
    var resizedHeight by rememberSaveable { mutableStateOf<Float?>(null) }
    var measuredHeight by remember { mutableStateOf(56f) }
    val resizeField: (Float) -> Unit = { delta ->
        resizedHeight = ((resizedHeight ?: measuredHeight) + delta).coerceIn(56f, maxFieldHeight.value)
    }
    var composerFocused by remember { mutableStateOf(false) }
    // Wide windows: one row of controls under a short field, lined up with the capped transcript.
    val wideRow = !compact && LocalWindowTier.current.wide
    val dense = compact || wideRow
    // A3-1: the card is the focus indication (2dp from a keyboard), never a ring round the text field.
    val keyboardMode = androidx.compose.ui.platform.LocalInputModeManager.current.inputMode == androidx.compose.ui.input.InputMode.Keyboard
    Surface(color = VerdeColors.Panel, shape = RoundedCornerShape(14.dp),
        border = BorderStroke(if (composerFocused) (if (keyboardMode) 2.dp else 1.5.dp) else 1.dp,
            if (composerFocused) VerdeColors.Accent else VerdeColors.PanelMuted),
        modifier = Modifier.fillMaxWidth().imePadding()
            // S17: the composer lines up with the capped transcript at every width.
            .then(if (!compact) Modifier.wrapContentWidth(Alignment.CenterHorizontally).widthIn(max = TRANSCRIPT_TEXT_MAX_WIDTH + 16.dp).fillMaxWidth() else Modifier)
            .padding(horizontal = 8.dp, vertical = 6.dp).testTag(COMPOSER)
            .onFocusChanged { composerFocused = it.hasFocus }.focusGroup()) {
        Column(Modifier.fillMaxWidth().padding(horizontal = if (dense) 8.dp else 12.dp, vertical = if (dense) 2.dp else 6.dp),
            verticalArrangement = Arrangement.spacedBy(if (dense) 0.dp else 6.dp)) {
            view?.followup?.let { FollowupCard(it, composer, kind) }
            val notice = composer.notice ?: composerError(view?.error)
            if (notice != null) {
                Text(notice, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.testTag(COMPOSER_NOTICE).semantics { liveRegion = LiveRegionMode.Polite })
            }
            // Full composer: the resize handle tops the card, so suggestions never strand it mid-card.
            val extras = @Composable {
                Suggestions(composer, view)
                if (attachments.isNotEmpty()) Attachments(attachments, sendPending || composer.busy, composer)
            }
            if (dense) extras()
            val placeholder = when {
                view == null -> "Loading…"
                !ready -> "Offline. Your draft is kept."
                running -> followupHint(null, kind)
                compact && placeholderText != null -> placeholderText
                // S49: at the largest text sizes the hint stays short enough to fit.
                LocalDensity.current.fontScale > 1.3f -> "Ask anything"
                else -> "Ask anything, or use / for commands and @ to search files."
            }
            val attach = view != null && !sendPending && !composer.busy
            val onPhotos = { photos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
            val onCamera = {
                if (context.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) startCamera()
                else permission.launch(Manifest.permission.CAMERA)
            }
            val onFiles = { files.launch(arrayOf("image/*")) }
            if (dense) {
                // The input gets the full width; controls sit on one compact row below it.
                BasicTextField(
                    value = composer.field,
                    onValueChange = { if (!sendPending) composer.edit(it) },
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).focusRequester(fieldFocus).ownsFocusRing().tabMovesFocus().testTag(COMPOSER_FIELD),
                    readOnly = sendPending,
                    decorationBox = { innerTextField ->
                        Box(Modifier.fillMaxWidth().padding(vertical = 12.dp), contentAlignment = Alignment.CenterStart) {
                            // The steer/interrupt/queue hint appears here only, never repeated below.
                            if (text.isEmpty()) Text(placeholder, color = VerdeColors.Subtle, style = MaterialTheme.typography.bodyMedium,
                                maxLines = 1, overflow = TextOverflow.Ellipsis)
                            innerTextField()
                        }
                    },
                    cursorBrush = SolidColor(VerdeColors.Accent),
                    textStyle = MaterialTheme.typography.bodyMedium.copy(color = VerdeColors.Text),
                    minLines = 1, maxLines = 6,
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
                )
                if (wideRow) WideComposerRow(view?.catalogs, view?.selection, provider,
                    fresh = state.thread?.rows?.isEmpty() == true && state.turn == null, onPicker = { picker = it },
                    attach = { AttachButton(enabled = attach, onPhotos = onPhotos, onCamera = onCamera, onFiles = onFiles) },
                    actions = {
                        if (running) StopControl(state.stopping, state.canStop, model::stop, Modifier.testTag(COMPOSER_STOP))
                        sendButton(canSubmit)
                    })
                else Row(Modifier.fillMaxWidth().testTag("composer-actions"), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                    // Weighted so the settings shrink in a narrow pane instead of squeezing send, measured last.
                    Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                        if (view != null) CompactSettings(view, state, provider, attach, onPicker = { picker = it },
                            onPhotos = onPhotos, onCamera = onCamera, onFiles = onFiles, onBrain = onBrain)
                    }
                    inlineAction?.invoke()
                    if (running) StopControl(state.stopping, state.canStop, model::stop, Modifier.testTag(COMPOSER_STOP))
                    sendButton(canSubmit)
                }
            } else {
            Box(Modifier.fillMaxWidth().height(24.dp).testTag("composer-resize")
                .semantics {
                    contentDescription = "Drag to resize the prompt box"
                    customActions = listOf(
                        CustomAccessibilityAction("Expand prompt box") { resizeField(56f); true },
                        CustomAccessibilityAction("Shrink prompt box") { resizeField(-56f); true },
                        CustomAccessibilityAction("Reset prompt box size") { resizedHeight = null; true },
                    )
                }
                .pointerInput(maxFieldHeight, density) {
                    detectVerticalDragGestures { change, amount ->
                        change.consume()
                        resizeField(-amount / density.density)
                    }
                }
                .pointerInput(Unit) { detectTapGestures(onDoubleTap = { resizedHeight = null }) },
                contentAlignment = Alignment.Center) {
                Box(Modifier.size(40.dp, 4.dp).background(VerdeColors.Border, RoundedCornerShape(2.dp)))
            }
            extras()
            BasicTextField(
                value = composer.field,
                onValueChange = { if (!sendPending) composer.edit(it) },
                modifier = Modifier.fillMaxWidth()
                    .then(resizedHeight?.let { Modifier.height(it.dp.coerceIn(56.dp, maxFieldHeight)) }
                        ?: Modifier.heightIn(min = 56.dp))
                    .onSizeChanged { measuredHeight = it.height / density.density }
                    .focusRequester(fieldFocus).ownsFocusRing().tabMovesFocus().testTag(COMPOSER_FIELD),
                readOnly = sendPending,
                decorationBox = { innerTextField ->
                    Box(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
                        if (text.isEmpty()) Text(placeholder, color = VerdeColors.Subtle, style = MaterialTheme.typography.bodyLarge,
                            maxLines = 3, overflow = TextOverflow.Ellipsis)
                        innerTextField()
                    }
                },
                cursorBrush = SolidColor(VerdeColors.Accent),
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = VerdeColors.Text),
                maxLines = if (resizedHeight == null) 6 else Int.MAX_VALUE,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
            )
            // S11: one row: the paperclip and the chips (wrapping only when they don't fit), then
            // Stop and Send at the trailing end. While a turn runs with nothing typed, Stop is the
            // only action (desktop): Send appears once there is something to steer with.
            Row(Modifier.fillMaxWidth().testTag("composer-actions"),
                verticalAlignment = Alignment.Bottom,
                horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Box(Modifier.weight(1f)) {
                    if (view != null) SettingsControls(view, state, provider, leading = {
                        AttachButton(enabled = attach, onPhotos = onPhotos, onCamera = onCamera, onFiles = onFiles)
                    }) { picker = it }
                    else AttachButton(enabled = attach, onPhotos = onPhotos, onCamera = onCamera, onFiles = onFiles)
                }
                if (running) {
                    StopControl(state.stopping, state.canStop, model::stop, Modifier.testTag(COMPOSER_STOP))
                }
                if (!running || hasContent) sendButton(canSubmit)
            }
            // A2-10: while the field is empty its placeholder already says this; say it once.
            if (running && view?.followup == null && text.isNotEmpty()) Text(followupHint(null, kind),
                color = VerdeColors.Subtle, style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.testTag("composer-action-hint"))
            }
        }
    }

    val open = picker
    if (open != null && view != null) {
        PickerSheet(open, view, provider, onDismiss = { picker = null }) { id -> picker = null; composer.select(open, id) }
    }
    view?.shell_confirmation?.let { ShellSheet(it, composer) }
}

/** S27: the companion's brain everywhere: provider, then model ("Codex · GPT-6.1 Sol"). */
internal fun compactSettingsLabel(c: ChatCatalogs, selection: ChatSelection, provider: String? = selection.provider): String {
    val model = modelValueLabel(c, selection)
    val name = provider?.let { id -> PROVIDERS.find { it.first == id }?.second ?: id.replaceFirstChar { it.uppercase() } }
    return if (name != null) "$name \u00b7 $model" else model
}

internal const val COMPOSER_SETTINGS = "composer-settings"

/** One chip for model + effort; its menu holds every picker plus attachments (compact composer). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CompactSettings(view: ChatComposerView, state: TranscriptState, provider: String?, attach: Boolean,
    onPicker: (ComposerPicker) -> Unit, onPhotos: () -> Unit, onCamera: () -> Unit, onFiles: () -> Unit, onBrain: (() -> Unit)? = null) {
    val c = view.catalogs
    val s = view.selection
    val fresh = state.thread?.rows?.isEmpty() == true && state.turn == null
    val label = compactSettingsLabel(c, s, provider)
    var menu by remember { mutableStateOf(false) }
    if (onBrain != null) {
        // The brain is chosen in settings; here: a "+" for access and attachments, and a read-only label.
        Box {
            IconButton(onClick = { menu = true }, modifier = Modifier.testTag(COMPOSER_ATTACH).named("Attach or change access")) {
                Icon(Icons.Filled.Add, contentDescription = null, tint = VerdeColors.Muted)
            }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                LiveOverMenu()
                if (c.access.isNotEmpty()) DropdownMenuItem(text = { Text("Access: ${accessChipLabel(c.access, s.access)}") },
                    onClick = { menu = false; onPicker(ComposerPicker.Access) })
                DropdownMenuItem(text = { Text("Attach photos") }, enabled = attach, onClick = { menu = false; onPhotos() })
                DropdownMenuItem(text = { Text("Take a photo") }, enabled = attach, onClick = { menu = false; onCamera() })
                DropdownMenuItem(text = { Text("Image files") }, enabled = attach, onClick = { menu = false; onFiles() })
            }
        }
        // r5: the brain reads in full ("Codex · GPT-6.1 Sol") wherever the row has room, the foldable's
        // companion pane included; a squeeze keeps both ends.
        ChipSurface("Brain: $label. Open brain settings", onBrain, RoundedCornerShape(12.dp),
            Modifier.widthIn(max = 280.dp).testTag(COMPOSER_SETTINGS)) {
            Row(Modifier.padding(horizontal = 8.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                ProviderGlyph(provider, Modifier.size(14.dp))
                // F6: a long brain name wraps rather than losing its middle.
                Text(label, style = MaterialTheme.typography.labelSmall, color = VerdeColors.Muted, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
        return
    }
    Box {
        ChipSurface("Model and options: $label. Change", { menu = true }, RoundedCornerShape(12.dp),
            Modifier.widthIn(max = 136.dp).testTag(COMPOSER_SETTINGS)) {
            Row(Modifier.padding(horizontal = 8.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                ProviderGlyph(provider, Modifier.size(14.dp))
                Text(label, style = MaterialTheme.typography.labelSmall, color = VerdeColors.Muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            LiveOverMenu()
            val pickers = buildList {
                if (fresh) add("Provider: ${PROVIDERS.find { it.first == provider }?.second ?: provider ?: "Provider"}" to ComposerPicker.Provider)
                add("Model: ${modelValueLabel(c, s)}" to ComposerPicker.Model)
                if (c.efforts.isNotEmpty()) add("Effort: ${effortValueLabel(c, s)}" to ComposerPicker.Effort)
                if (c.speeds.size > 1) add("Speed: ${composerChoiceLabel(c.speeds, s.speed ?: "off") ?: "Standard"}" to ComposerPicker.Speed)
                if (c.access.isNotEmpty()) add("Access: ${accessChipLabel(c.access, s.access)}" to ComposerPicker.Access)
            }
            pickers.forEach { (text, picker) -> DropdownMenuItem(text = { Text(text) }, onClick = { menu = false; onPicker(picker) }) }
            HorizontalDivider()
            DropdownMenuItem(text = { Text("Attach photos") }, enabled = attach, onClick = { menu = false; onPhotos() },
                modifier = Modifier.testTag(COMPOSER_ATTACH))
            DropdownMenuItem(text = { Text("Take a photo") }, enabled = attach, onClick = { menu = false; onCamera() })
            DropdownMenuItem(text = { Text("Image files") }, enabled = attach, onClick = { menu = false; onFiles() })
        }
    }
}

@Composable
private fun AttachButton(enabled: Boolean, onPhotos: () -> Unit, onCamera: () -> Unit, onFiles: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { menu = true }, enabled = enabled, modifier = Modifier.testTag(COMPOSER_ATTACH).named("Attach image")) {
            Icon(painterResource(R.drawable.composer_attach), contentDescription = null, modifier = Modifier.size(18.dp))
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            LiveOverMenu()
            DropdownMenuItem(text = { Text("Photos") }, onClick = { menu = false; onPhotos() })
            DropdownMenuItem(text = { Text("Camera") }, onClick = { menu = false; onCamera() })
            DropdownMenuItem(text = { Text("Image files") }, onClick = { menu = false; onFiles() })
        }
    }
}

@Composable
private fun FollowupCard(f: ChatFollowup, composer: ComposerModel, kind: EventFollowupSubmitKind) {
    // Core retains the receipt until the turn ends; it is no longer pending UI.
    if (f.state == "sent_inline" && f.delivery == "accepted") return
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

/** One suggestion row: the value, and for files the folder it lives in. */
internal data class Suggestion(val label: String, val detail: String?, val accept: () -> Unit)

/** Slash commands matching [query], one row per command name (catalogs can repeat a command). */
internal fun slashSuggestions(choices: List<ChatChoice>, query: String): List<String> {
    val prefix = "/$query"
    return choices.filter { it.enabled }.map { if (it.label.startsWith("/")) it.label else "/" + it.label }
        .filter { it.startsWith(prefix, ignoreCase = true) }.distinctBy { it.lowercase() }
}

/** `@` file results: one row per path, file name first and its folder as detail. */
internal fun mentionSuggestions(mentions: List<ChatMention>, max: Int = 8): List<Pair<String, String?>> =
    mentions.distinctBy { it.path }.take(max).map { m ->
        val name = basename(m.path)
        val folder = m.path.removeSuffix(name).trimEnd('/').ifEmpty { null }
        name to folder
    }

/** S5: `/` and `@` share one vertical list of 48dp rows inside the composer card. */
@Composable
private fun Suggestions(composer: ComposerModel, view: ChatComposerView?) {
    val slash = composer.slash
    val mention = composer.mention
    if (view == null || (slash == null && mention == null)) return
    val rows: List<Suggestion> = if (slash != null)
        slashSuggestions(view.catalogs.slash, slash.query).map { name -> Suggestion(name, null) { composer.acceptSlash(name) } }
    else {
        val paths = view.mentions.distinctBy { it.path }.take(8)
        mentionSuggestions(paths).zip(paths).map { (shown, m) -> Suggestion(shown.first, shown.second) { composer.acceptMention(m.path) } }
    }
    if (mention != null && rows.isEmpty()) return
    Column(Modifier.fillMaxWidth().heightIn(max = 200.dp).verticalScroll(rememberScrollState()).testTag(COMPOSER_SUGGESTIONS)) {
        VerdeSection(if (slash != null) "Commands" else "Files", inset = 4.dp)
        if (rows.isEmpty()) Text(if (composer.slashLoading) "Loading commands…" else "No matching commands for this provider.",
            Modifier.padding(horizontal = 4.dp, vertical = 8.dp), color = VerdeColors.Subtle, style = MaterialTheme.typography.bodySmall)
        for (row in rows) Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(RoundedCornerShape(7.dp))
            .clickable(role = Role.Button, onClick = row.accept)
            .nameOnly(listOfNotNull(row.label, row.detail).joinToString(", "))
            .padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(row.label, style = MaterialTheme.typography.bodyMedium.copy(fontFamily = if (slash != null) VerdeMono else VerdeSans),
                color = VerdeColors.Text, maxLines = 1, overflow = TextOverflow.Ellipsis)
            row.detail?.let { Text(it, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.bodySmall,
                color = VerdeColors.Subtle, maxLines = 1, overflow = TextOverflow.MiddleEllipsis) }
        }
    }
}

@Composable
private fun Attachments(items: List<ChatAttachment>, locked: Boolean, composer: ComposerModel) {
    // Up to 16 images (the host's limit): one horizontally scrolling strip of thumbnails, each with
    // its own remove button and upload progress, so the composer never grows a row per image.
    val scroll = rememberScrollState()
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        if (items.size > 1) Text(draftImageCount(items.size), style = MaterialTheme.typography.labelSmall, color = VerdeColors.Muted)
        Row(Modifier.fillMaxWidth().horizontalEdgeFade(scroll, VerdeColors.Panel).horizontalScroll(scroll).testTag(COMPOSER_ATTACHMENTS),
            horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            // A11-3: names that tell the images apart; generic ones become "Photo 1…16".
            val names = draftImageNames(items.map { it.name })
            for ((index, a) in items.withIndex()) key(a.local_id) {
                val name = names[index]
                val size = a.byte_size.toLongOrNull() ?: 0L
                val uploaded = a.uploaded_bytes.toLongOrNull() ?: 0L
                Column(Modifier.width(72.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Box(Modifier.size(72.dp)) {
                        val tile = Modifier.align(Alignment.BottomStart).size(64.dp).clip(RoundedCornerShape(8.dp))
                        // A6-4: a draft image restored without its preview (the core still has its
                        // bytes) shows a photo glyph instead of a blank square.
                        val preview = composer.imagePreviews[a.local_id]
                        if (preview != null) DraftImagePreview(preview, "$name, ${attachmentSize(size)}", tile)
                        else Box(tile.background(VerdeColors.PanelAlt).semantics { contentDescription = "$name, ${attachmentSize(size)}" },
                            contentAlignment = Alignment.Center) {
                            Icon(painterResource(R.drawable.composer_attach), contentDescription = null, tint = VerdeColors.Muted, modifier = Modifier.size(22.dp))
                        }
                        if (!locked) Box(Modifier.align(Alignment.TopEnd).offset(x = 12.dp, y = (-12).dp).size(48.dp)
                            .clickable(role = androidx.compose.ui.semantics.Role.Button) { composer.detach(a.local_id) }.nameOnly("Remove $name"),
                            contentAlignment = Alignment.Center) {
                            Box(Modifier.size(22.dp).background(VerdeColors.Panel, CircleShape).border(1.dp, VerdeColors.Border, CircleShape),
                                contentAlignment = Alignment.Center) {
                                Icon(Icons.Filled.Close, contentDescription = null, tint = VerdeColors.Text, modifier = Modifier.size(14.dp))
                            }
                        }
                    }
                    if (a.status == "uploading" || (locked && uploaded in 1 until size)) {
                        LinearProgressIndicator(progress = { if (size > 0) (uploaded.toFloat() / size).coerceIn(0f, 1f) else 0f },
                            modifier = Modifier.width(64.dp).semantics { contentDescription = "Uploading $name" })
                    }
                }
            }
        }
        for (a in items) composerError(a.error)?.let {
            Text("${attachmentDisplayName(a.name)}: $it", color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
        }
    }
}

internal const val COMPOSER_ATTACHMENTS = "composer-attachments"

/** S44: each draft image's indexed name, "Photo 3 of 16"; a lone image keeps its own name. */
internal fun draftImageNames(raw: List<String>): List<String> =
    if (raw.size <= 1) raw.map(::attachmentDisplayName) else raw.indices.map { "Photo ${it + 1} of ${raw.size}" }

/** S44: the strip's count, "16 photos". */
internal fun draftImageCount(count: Int): String = if (count == 1) "1 photo" else "$count photos"

internal fun composerChoiceLabel(choices: List<ChatChoice>, id: String?) = choices.find { it.id == (id ?: "") }?.label ?: id?.takeIf { it.isNotEmpty() }

/**
 * S5: what the Access chip says — the chosen mode ("Supervised", "Full access"), or the mode a
 * chat without a choice resolves to ("Default · Full access"). Never just "Access".
 */
internal fun accessValueLabel(access: List<ChatChoice>, selected: String?): String {
    val chosen = selected?.takeIf { it.isNotEmpty() }
    if (chosen != null) return composerChoiceLabel(access, chosen) ?: chosen
    if (access.isEmpty()) return "Default"
    return "Default \u00b7 ${composerChoiceLabel(access, DEFAULT_ACCESS) ?: "Full access"}"
}

/**
 * What an unset access runs as: the core sends no access_mode (chat.zig) and the host falls back to
 * full access, as the core's own thread_create does (manage.zig `selection.access orelse "full_access"`).
 */
internal const val DEFAULT_ACCESS = "full_access"

/** The access a chat effectively has: its own choice, else [DEFAULT_ACCESS]. */
internal fun effectiveAccess(selected: String?) = selected?.takeIf { it.isNotEmpty() } ?: DEFAULT_ACCESS

/** The provider's own default model/effort choice ("default" or the empty id). */
internal fun isDefaultChoice(id: String?) = id.isNullOrEmpty() || id == "default"

/**
 * S18: the model chip shows the resolved model only ("Opus 5.5" for the provider's default when the
 * core knows it, core C6); the picker marks which row is the default.
 */
internal fun modelValueLabel(c: ChatCatalogs, s: ChatSelection): String {
    val id = s.model ?: c.models.firstOrNull()?.id
    val label = composerChoiceLabel(c.models, id) ?: "Model"
    val resolved = c.default_model_label?.takeIf { it.isNotBlank() }
    return if (isDefaultChoice(id) && resolved != null) resolved else label
}

/**
 * S25: the effort a chat runs with: its own, else the provider default's name when the core knows
 * it, else "Auto". Never a bare "Default".
 */
internal fun effortValueLabel(c: ChatCatalogs, s: ChatSelection): String {
    if (isDefaultChoice(s.effort)) return c.default_effort_label?.takeIf { it.isNotBlank() } ?: "Auto"
    return composerChoiceLabel(c.efforts, s.effort) ?: "Auto"
}

/**
 * S25: the one abbreviation table both apps use for composer chips. Effort: Low / Med / High / XHigh
 * / Max / Auto; speed: Std / Fast; access: Supervised → "Ask", Full access → "Full". The model keeps
 * its name and is truncated instead.
 */
internal fun chipShort(picker: ComposerPicker, value: String): String = when (picker) {
    ComposerPicker.Effort -> when (value.lowercase()) {
        "low" -> "Low"; "medium" -> "Med"; "high" -> "High"; "xhigh" -> "XHigh"; "max" -> "Max"; "auto", "default" -> "Auto"
        else -> value
    }
    ComposerPicker.Speed -> if (value.equals("Fast", ignoreCase = true) || value == "on") "Fast" else "Std"
    ComposerPicker.Access -> when (value) { "Supervised", "supervised" -> "Ask"; "Full access", "full_access" -> "Full"; else -> value }
    else -> value
}

/**
 * S35: one wording on both platforms. A picker row that is the host's default says what it is and
 * is marked "(default)": "Opus 5.5 (default)", "Auto (default)", "Standard (default)",
 * "Full access (default)"; never a bare "Default".
 */
internal fun pickerRowLabel(kind: ComposerPicker, choice: ChatChoice, c: ChatCatalogs? = null): String = when (kind) {
    ComposerPicker.Effort -> if (isDefaultChoice(choice.id)) defaultMarked("Auto") else choice.label
    // S45: one row for the default model, "Opus 5.5 (default)" (the explicit duplicate is left out,
    // see [modelChoices]); "Default" when the core doesn't name it.
    ComposerPicker.Model -> if (isDefaultChoice(choice.id)) c?.default_model_label?.takeIf { it.isNotBlank() }?.let(::defaultMarked) ?: "Default" else choice.label
    ComposerPicker.Speed -> when (choice.id) { "off" -> defaultMarked("Standard"); "on" -> "Fast"; else -> choice.label }
    ComposerPicker.Access -> if (choice.id == DEFAULT_ACCESS) defaultMarked(choice.label) else choice.label
    else -> choice.label
}

internal fun defaultMarked(label: String) = "$label (default)"

/** S45: the model choices with the default named once: the explicit row the default resolves to is left out. */
internal fun modelChoices(c: ChatCatalogs): List<ChatChoice> {
    val resolved = c.default_model_label?.takeIf { it.isNotBlank() } ?: return c.models
    if (c.models.none { isDefaultChoice(it.id) }) return c.models
    return c.models.filter { isDefaultChoice(it.id) || it.label != resolved }
}

/** The id the picker marks for [selected]: a hidden duplicate of the default selects the default row. */
internal fun modelCurrent(c: ChatCatalogs, selected: String?): String? {
    val shown = modelChoices(c)
    return selected?.takeIf { id -> shown.any { it.id == id } }
        ?: shown.firstOrNull { isDefaultChoice(it.id) }?.id
        ?: if (isDefaultChoice(selected)) shown.firstOrNull { it.label == c.default_model_label }?.id ?: shown.firstOrNull()?.id else selected
}

/** S18: the access chip names the mode the chat runs with; an unset one is [DEFAULT_ACCESS]. */
internal fun accessChipLabel(access: List<ChatChoice>, selected: String?): String =
    composerChoiceLabel(access, effectiveAccess(selected)) ?: "Full access"

internal fun accessIsFull(@Suppress("UNUSED_PARAMETER") access: List<ChatChoice>, selected: String?) = effectiveAccess(selected) == "full_access"

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun SettingsControls(view: ChatComposerView, state: TranscriptState, provider: String?,
    leading: (@Composable () -> Unit)? = null, open: (ComposerPicker) -> Unit) {
    val c = view.catalogs
    val s = view.selection
    // Like the desktop, the provider is fixed once a conversation has started.
    val fresh = state.thread?.rows?.isEmpty() == true && state.turn == null

    val providerLabel = PROVIDERS.find { it.first == provider }?.second ?: provider ?: "Provider"
    // S31 (locked): model · effort · speed · access; every chip is glyph + short label, always.
    // The model name truncates in the middle first; when even that doesn't fit, or at large text,
    // the chips wrap to more rows. Idle, running and Steer use this same row.
    data class Chip(val name: String, val value: String, val short: String, val provider: String?, val icon: Int?, val fill: Float,
        val picker: ComposerPicker)
    val effortValue = effortValueLabel(c, s)
    val accessValue = accessChipLabel(c.access, s.access)
    val speedValue = speedLabel(s.speed)
    val model = modelValueLabel(c, s)
    val chips = buildList {
        if (fresh) add(Chip("Provider", providerLabel, providerLabel, provider, null, 1f, ComposerPicker.Provider))
        add(Chip("Model", model, model, provider, null, 1f, ComposerPicker.Model))
        if (c.efforts.isNotEmpty()) add(Chip("Effort", effortValue, chipShort(ComposerPicker.Effort, effortValue), null, R.drawable.composer_reasoning,
            (c.efforts.indexOfFirst { it.id == (s.effort ?: "") }.coerceAtLeast(0) + 1).toFloat() / c.efforts.size, ComposerPicker.Effort))
        // Speed: a bolt for Fast, a gauge for Standard.
        if (c.speeds.size > 1) add(Chip("Speed", speedValue, chipShort(ComposerPicker.Speed, s.speed ?: "off"), null,
            if (s.speed == "on") R.drawable.composer_fast else R.drawable.composer_standard, 1f, ComposerPicker.Speed))
        if (c.access.isNotEmpty()) add(Chip("Access", accessValue, chipShort(ComposerPicker.Access, accessValue), null,
            if (accessIsFull(c.access, s.access)) R.drawable.composer_unlocked else R.drawable.composer_locked, 1f, ComposerPicker.Access))
    }
    val large = LocalDensity.current.fontScale > 1.15f
    val measurer = androidx.compose.ui.text.rememberTextMeasurer()
    val labelStyle = MaterialTheme.typography.labelMedium
    val density = LocalDensity.current
    BoxWithConstraints(Modifier.fillMaxWidth().testTag(COMPOSER_CHIPS)) {
        fun textWidth(text: String) = with(density) { measurer.measure(text, labelStyle).size.width.toDp().value }
        fun width(chip: Chip): Float = textWidth(chip.short) + (if (chip.icon == null && chip.provider == null) CHIP_CHROME.value - 18f else CHIP_CHROME.value)
        val available = (maxWidth - (if (leading != null) 52.dp else 0.dp)).value
        val modelChip = chips.first { it.picker == ComposerPicker.Model }
        val modelFull = width(modelChip)
        // A model name narrower than this (with its glyph) reads as noise: wrap rather than squeeze it.
        val modelFloor = minOf(modelFull, 84f)
        val others = chips.filter { it !== modelChip }.sumOf { width(it).toDouble() }.toFloat() + chips.size * 4f
        val rowWidth = maxWidth
        if (large || available - others < modelFloor) {
            FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp), verticalArrangement = Arrangement.spacedBy(0.dp),
                itemVerticalAlignment = Alignment.CenterVertically) {
                leading?.invoke()
                chips.forEach {
                    SettingChip(it.name, it.value, it.provider, it.icon, it.fill, shown = it.short,
                        maxWidth = if (it === modelChip) rowWidth else 220.dp) { open(it.picker) }
                }
            }
            return@BoxWithConstraints
        }
        val modelRoom = (available - others).coerceIn(modelFloor, modelFull)
        // S45: the same middle truncation as iOS, "GPT…Sol" (no space beside the ellipsis).
        val modelShown = middleFit(modelChip.short, modelRoom - (modelFull - textWidth(modelChip.short)), ::textWidth)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
            leading?.invoke()
            chips.forEach {
                SettingChip(it.name, it.value, it.provider, it.icon, it.fill, shown = if (it === modelChip) modelShown else it.short,
                    maxWidth = if (it === modelChip) modelRoom.dp else 220.dp) { open(it.picker) }
            }
        }
    }
}

internal const val COMPOSER_CHIPS = "composer-chips"

/** Keeps both ends of [text] within [max] (as measured by [width]), with no space beside the ellipsis: "GPT…Sol". */
internal fun middleFit(text: String, max: Float, width: (String) -> Float): String {
    if (width(text) <= max) return text
    var keep = text.length - 1
    while (keep > 1) {
        val candidate = text.take((keep + 1) / 2).trimEnd() + "\u2026" + text.takeLast(keep / 2).trimStart()
        if (width(candidate) <= max) return candidate
        keep--
    }
    return text.take(1) + "\u2026"
}

/** S31 / I10-2: the speed a label or picker names: "Standard" or "Fast", never the core's "Normal". */
internal fun speedLabel(id: String?) = if (id == "on") "Fast" else "Standard"

/** A compact chip's padding, icon and gap around its label. */
private val CHIP_CHROME = 34.dp

/**
 * The wide-window composer's single row: attach, the settings chips, then send. The model chip takes
 * only the width its label needs and gives way last, so it truncates only when the row truly runs out.
 */
@Composable
internal fun WideComposerRow(catalogs: ChatCatalogs?, selection: ChatSelection?, provider: String?, fresh: Boolean,
    onPicker: (ComposerPicker) -> Unit, attach: @Composable () -> Unit, actions: @Composable () -> Unit) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        // S31: the same glyph + short label chips as the phone row at every width.
        val tight = false
        Row(Modifier.fillMaxWidth().testTag("composer-actions"), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            attach()
            Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                if (catalogs != null && selection != null) {
                    val c = catalogs
                    val s = selection
                    if (fresh) SettingChip("Provider", PROVIDERS.find { it.first == provider }?.second ?: provider ?: "Provider", provider, compact = tight) { onPicker(ComposerPicker.Provider) }
                    SettingChip("Model", modelValueLabel(c, s), provider,
                        modifier = Modifier.weight(1f, fill = false), maxWidth = 360.dp) { onPicker(ComposerPicker.Model) }
                    if (c.efforts.isNotEmpty()) SettingChip("Effort", effortValueLabel(c, s), compact = tight,
                        icon = R.drawable.composer_reasoning,
                        fill = ((c.efforts.indexOfFirst { it.id == (s.effort ?: "") }.coerceAtLeast(0) + 1).toFloat() / c.efforts.size),
                        shown = chipShort(ComposerPicker.Effort, effortValueLabel(c, s))) { onPicker(ComposerPicker.Effort) }
                    if (c.speeds.size > 1) SettingChip("Speed", speedLabel(s.speed), compact = tight,
                        icon = if (s.speed == "on") R.drawable.composer_fast else R.drawable.composer_standard,
                        shown = chipShort(ComposerPicker.Speed, s.speed ?: "off")) { onPicker(ComposerPicker.Speed) }
                    if (c.access.isNotEmpty()) SettingChip("Access", accessChipLabel(c.access, s.access), compact = tight,
                        icon = if (accessIsFull(c.access, s.access)) R.drawable.composer_unlocked else R.drawable.composer_locked,
                        shown = chipShort(ComposerPicker.Access, accessChipLabel(c.access, s.access))) { onPicker(ComposerPicker.Access) }
                }
            }
            actions()
        }
    }
}

@Composable
private fun SettingChip(name: String, value: String, provider: String? = null,
    icon: Int? = null, fill: Float = 1f, compact: Boolean = false, iconOnly: Boolean = false,
    /** The label to draw (a short form of [value]); TalkBack always reads [value]. */
    shown: String = value,
    modifier: Modifier = Modifier, maxWidth: Dp = 220.dp, onClick: () -> Unit) {
    val leading: (@Composable () -> Unit)? = if (provider != null) {
        { ProviderGlyph(provider, Modifier.size(14.dp)) }
    } else icon?.let { resource -> {
        SettingGlyph(resource, fill)
    } }
    val label = "$name: $value. Change"
    val controlModifier = modifier.semantics { contentDescription = label }
    if (compact) {
        FilledTonalIconButton(onClick = onClick, modifier = controlModifier.size(48.dp),
            colors = IconButtonDefaults.filledTonalIconButtonColors(containerColor = VerdeColors.PanelAlt)) {
            leading?.invoke()
        }
        return
    }
    // A 32dp chip inside a 48dp target; icon-only when the row is short of room (S18).
    // S29: the clickable node itself carries "Name: value. Change" (no unnamed wrapper over a named child).
    ChipSurface(label, onClick, RoundedCornerShape(14.dp), modifier.widthIn(max = maxWidth)) {
        Row(Modifier.heightIn(min = 32.dp).padding(start = if (iconOnly) 12.dp else 7.dp, end = if (iconOnly) 12.dp else 8.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            leading?.invoke()
            // A8-2: a long model name keeps both ends ("GPT…Sol"), like iOS.
            if (!iconOnly) Text(shown, style = MaterialTheme.typography.labelMedium, maxLines = 1,
                overflow = if (name == "Model") TextOverflow.MiddleEllipsis else TextOverflow.Ellipsis)
        }
    }
}

/** A Surface-like chip whose clickable node is the one named target (S29); 48dp touch, [shape] face. */
@Composable
private fun ChipSurface(label: String, onClick: () -> Unit, shape: androidx.compose.ui.graphics.Shape, modifier: Modifier,
    content: @Composable () -> Unit) {
    Box(modifier.minimumInteractiveComponentSize().clip(shape).background(VerdeColors.PanelAlt, shape)
        .clickable(role = Role.Button, onClick = onClick).nameOnly(label)) {
        CompositionLocalProvider(LocalContentColor provides VerdeColors.Muted) { content() }
    }
}

/** Shared glyph rendering for toolbar controls and their picker rows. */
@Composable
private fun SettingGlyph(resource: Int, fill: Float = 1f) {
        Box(Modifier.size(16.dp)) {
            if (fill < 1f) Icon(painterResource(resource), contentDescription = null,
                tint = VerdeColors.Muted.copy(alpha = .32f), modifier = Modifier.fillMaxSize())
            Icon(painterResource(resource), contentDescription = null, tint = VerdeColors.Muted,
                modifier = Modifier.fillMaxSize().drawWithContent {
                    clipRect(top = size.height * (1f - fill.coerceIn(0f, 1f))) { this@drawWithContent.drawContent() }
                })
        }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PickerSheet(kind: ComposerPicker, view: ChatComposerView, provider: String?, onDismiss: () -> Unit, onPick: (String) -> Unit) {
    val c = view.catalogs
    val s = view.selection
    val (title, choices, current) = when (kind) {
        ComposerPicker.Provider -> Triple("Provider", PROVIDERS.map { ChatChoice(it.first, it.second) }, provider)
        // Desktop favourites first, otherwise in catalog order.
        ComposerPicker.Model -> Triple("Model", modelChoices(c).sortedByDescending { it.favorite }, modelCurrent(c, s.model))
        ComposerPicker.Effort -> Triple("Reasoning effort", c.efforts, s.effort ?: "")
        ComposerPicker.Access -> Triple("Access", c.access, effectiveAccess(s.access))
        ComposerPicker.Speed -> Triple("Speed", c.speeds, s.speed ?: c.speeds.firstOrNull()?.id)
    }
    // F5: on wide windows (the unfolded Fold, tablets) the choices open as a menu over the composer,
    // inside the chat pane, instead of a sheet centred across the whole window over the sidebar.
    if (LocalWindowTier.current.wide) {
        DropdownMenu(expanded = true, onDismissRequest = onDismiss,
            modifier = Modifier.widthIn(min = 280.dp, max = 380.dp).heightIn(max = 480.dp).testTag(COMPOSER_PICKER)) {
            LiveOverMenu()
            Text(title, style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
            Column(Modifier.selectableGroup()) { PickerRows(kind, choices, current, c, provider, onPick) }
        }
        return
    }
    // The list scrolls inside a fully expanded sheet, so the last choice is never cut off.
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        modifier = Modifier.testTag(COMPOSER_PICKER), contentWindowInsets = { WindowInsets(0) }, scrimColor = androidx.compose.ui.graphics.Color.Unspecified) {
        SheetDismissBackdrop(onDismiss)
        LiveOverModal()
        Column(Modifier.fillMaxWidth().heightIn(max = sheetMaxContentHeight() - 48.dp).navigationBarsPadding()) {
            SheetHeader(title, onDismiss, style = MaterialTheme.typography.titleMedium)
            Column(Modifier.fillMaxWidth().weight(1f, fill = false).heightIn(max = 560.dp).verticalScroll(rememberScrollState()).padding(bottom = 16.dp).selectableGroup()) {
                PickerRows(kind, choices, current, c, provider, onPick)
            }
        }
    }
}

@Composable
private fun PickerRows(kind: ComposerPicker, choices: List<ChatChoice>, current: String?, c: ChatCatalogs, provider: String?, onPick: (String) -> Unit) {
        choices.forEach { choice -> key(choice.id) {
                val selected = choice.id == current
                // The Default row names what it resolves to, when the core knows (iOS wording).
                val subtitle = when {
                    !choice.enabled -> choice.reason ?: "Unavailable"
                    // iOS wording: what an "Auto" effort runs, under it.
                    kind == ComposerPicker.Effort && isDefaultChoice(choice.id) -> c.default_effort_label?.takeIf { it.isNotBlank() } ?: "provider default"
                    else -> null
                }
                VerdeListRow(
                    headlineContent = { Text(pickerRowLabel(kind, choice, c)) },
                    supportingContent = subtitle?.let { { Text(it) } },
                    leadingContent = {
                        when (kind) {
                            ComposerPicker.Provider -> ProviderGlyph(choice.id)
                            ComposerPicker.Model -> ProviderGlyph(provider ?: "codex")
                            ComposerPicker.Effort -> SettingGlyph(R.drawable.composer_reasoning,
                                (choices.indexOf(choice) + 1).toFloat() / choices.size)
                            ComposerPicker.Speed -> SettingGlyph(if (choice.id == "on") R.drawable.composer_fast else R.drawable.composer_standard)
                            ComposerPicker.Access -> SettingGlyph(if (choice.id == "full_access") R.drawable.composer_unlocked else R.drawable.composer_locked)
                        }
                    },
                    trailingContent = {
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            if (choice.favorite) Icon(Icons.Filled.Star, contentDescription = "Favourite", modifier = Modifier.size(18.dp))
                            if (selected) Icon(Icons.Filled.Check, contentDescription = null, tint = VerdeColors.Accent)
                        }
                    },
                    // TalkBack hears "Selected" on the current choice (a radio group), not just a check glyph.
                    modifier = Modifier.fillMaxWidth().selectable(selected = selected, enabled = choice.enabled,
                        role = Role.RadioButton) { if (!selected) onPick(choice.id) }
                        .nameOnly(listOfNotNull(pickerRowLabel(kind, choice, c), subtitle, "Favourite".takeIf { choice.favorite }).joinToString(", "),
                            selected = selected),
                )
            }
        }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ShellSheet(confirmation: ChatShellConfirmation, composer: ComposerModel) {
    ModalBottomSheet(onDismissRequest = { composer.confirmShell(confirmation, false) }, modifier = Modifier.testTag(COMPOSER_SHELL)) {
        LiveOverModal()
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

/** A5-3: Tab / Shift+Tab move between controls instead of typing a tab into the prompt. */
@Composable
internal fun Modifier.tabMovesFocus(): Modifier {
    val focus = androidx.compose.ui.platform.LocalFocusManager.current
    return onPreviewKeyEvent { event ->
        if (event.key != androidx.compose.ui.input.key.Key.Tab) return@onPreviewKeyEvent false
        if (event.type == androidx.compose.ui.input.key.KeyEventType.KeyDown)
            focus.moveFocus(if (event.isShiftPressed) androidx.compose.ui.focus.FocusDirection.Previous else androidx.compose.ui.focus.FocusDirection.Next)
        true
    }
}
