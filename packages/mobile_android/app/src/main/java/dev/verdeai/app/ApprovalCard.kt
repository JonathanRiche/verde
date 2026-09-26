package dev.verdeai.app

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.verdeai.core.ChatApproval
import kotlinx.coroutines.launch

internal const val APPROVAL_CARD = "approval-card"
internal const val APPROVAL_BANNER = "approval-banner"
internal const val APPROVAL_OUTCOME = "approval-outcome"
internal const val APPROVE_LABEL = "Approve"
internal const val DENY_LABEL = "Deny"

/** D-09's `approval` renderer: decide inline, with state from the core receipt. */
internal val ApprovalRenderer: @Composable (TranscriptItem.Approval, TranscriptContext) -> Unit =
    { item, ctx -> ApprovalCard(item.approval, ctx.model.approvals) }

internal fun phaseText(phase: ApprovalPhase): String? = when (phase) {
    ApprovalPhase.Idle -> null
    is ApprovalPhase.Sending -> when (phase.decision) {
        ApprovalDecision.Approve -> "Sending your approval…"
        ApprovalDecision.Deny -> "Sending your denial…"
        null -> "Sending your decision…"
    }
    is ApprovalPhase.Sent -> when (phase.decision) {
        ApprovalDecision.Deny -> "Denied — waiting for the agent."
        else -> "Approved — waiting for the agent to continue."
    }
    ApprovalPhase.Stale -> "This request is no longer waiting. It was answered elsewhere or expired."
    is ApprovalPhase.Failed ->
        if (phase.uncertain) "Couldn't confirm your decision reached the host. Try again."
        else "Couldn't send your decision. Try again."
}

@Composable
internal fun ApprovalCard(approval: ChatApproval, controller: ApprovalController) {
    val local by controller.local.collectAsState()
    val phase = approvalPhase(approval, local)
    val haptics = LocalHapticFeedback.current
    @Suppress("DEPRECATION") val clipboard = LocalClipboardManager.current
    val preview = remember(approval.title, approval.body) { approvalPreview(approval) }
    val colors = MaterialTheme.colorScheme
    val title = approval.title.ifBlank { "Permission required" }
    // A failure the user didn't just cause (e.g. a retried send) still gets felt once.
    var lastPhase by remember(approval.key) { mutableStateOf<ApprovalPhase>(phase) }
    LaunchedEffect(phase) {
        if (phase is ApprovalPhase.Failed && lastPhase !is ApprovalPhase.Failed) haptics.performHapticFeedback(HapticFeedbackType.Reject)
        if (phase is ApprovalPhase.Sent && lastPhase !is ApprovalPhase.Sent) haptics.performHapticFeedback(HapticFeedbackType.Confirm)
        lastPhase = phase
    }
    Column(
        Modifier.fillMaxWidth().testTag(APPROVAL_CARD)
            .border(1.dp, colors.tertiary, RoundedCornerShape(10.dp))
            .background(VerdeColors.Assistant, RoundedCornerShape(10.dp))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.size(9.dp).background(colors.tertiary, CircleShape))
            Column(Modifier.weight(1f)) {
                // Announced once when the card appears (TalkBack reads polite live regions on change).
                Text("Approval required", style = MaterialTheme.typography.labelMedium, color = colors.tertiary,
                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite; contentDescription = "Approval required: $title" })
                Text(title, style = MaterialTheme.typography.titleSmall, maxLines = 3, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.semantics { heading() })
            }
        }
        ApprovalSummary(preview)
        ApprovalDetails(approval, preview, onCopy = { clipboard.setText(AnnotatedString(approval.body)) })
        phaseText(phase)?.let { text ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (phase is ApprovalPhase.Sending) CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                Text(text, style = MaterialTheme.typography.bodySmall,
                    color = if (phase is ApprovalPhase.Failed) colors.error else colors.onSurfaceVariant,
                    modifier = Modifier.semantics { liveRegion = if (phase is ApprovalPhase.Failed) LiveRegionMode.Assertive else LiveRegionMode.Polite })
            }
        }
        if (phase !is ApprovalPhase.Stale && phase !is ApprovalPhase.Sent) {
            val enabled = phase.canDecide()
            val sending = (phase as? ApprovalPhase.Sending)?.decision
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
                OutlinedButton(shape = MaterialTheme.shapes.small,
                    onClick = {
                        if (controller.decide(approval, ApprovalDecision.Deny)) haptics.performHapticFeedback(HapticFeedbackType.Reject)
                    },
                    enabled = enabled, modifier = Modifier.heightIn(min = 48.dp).semantics { contentDescription = "Deny: $title" },
                ) { Text(if (sending == ApprovalDecision.Deny) "Denying…" else DENY_LABEL) }
                Button(shape = MaterialTheme.shapes.small,
                    onClick = {
                        if (controller.decide(approval, ApprovalDecision.Approve)) haptics.performHapticFeedback(HapticFeedbackType.Confirm)
                    },
                    enabled = enabled, modifier = Modifier.heightIn(min = 48.dp).semantics { contentDescription = "Approve: $title" },
                ) { Text(if (sending == ApprovalDecision.Approve) "Approving…" else APPROVE_LABEL) }
            }
        }
    }
}

@Composable
private fun ApprovalSummary(preview: ApprovalPreview) {
    val colors = MaterialTheme.colorScheme
    val mono = MaterialTheme.typography.bodySmall.copy(fontFamily = VerdeMono)
    if (preview.tool != null || preview.path != null) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
            preview.tool?.let { Label(it) }
            // Host paths stay abstract on the phone: the file name here, the full request in details.
            preview.path?.let { Text(basename(it), style = mono, maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.semantics { contentDescription = "File ${basename(it)}" }) }
        }
    }
    preview.reason?.let { Text(it, style = MaterialTheme.typography.bodySmall, maxLines = 4, overflow = TextOverflow.Ellipsis) }
    preview.command?.let { command ->
        Text("$ $command", Modifier.fillMaxWidth().background(colors.surfaceContainerHighest, RoundedCornerShape(8.dp))
            .padding(horizontal = 10.dp, vertical = 8.dp).semantics { contentDescription = "Command: $command" },
            style = mono, maxLines = 6, overflow = TextOverflow.Ellipsis)
    }
    if (preview.changes.isNotEmpty()) ChangePreview(preview)
}

@Composable
private fun Label(text: String) {
    Text(text, Modifier.background(MaterialTheme.colorScheme.secondaryContainer, RoundedCornerShape(6.dp)).padding(horizontal = 6.dp, vertical = 2.dp),
        style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSecondaryContainer, fontWeight = FontWeight.Medium)
}

@Composable
private fun ChangePreview(preview: ApprovalPreview) {
    val colors = MaterialTheme.colorScheme
    val mono = MaterialTheme.typography.bodySmall.copy(fontFamily = VerdeMono)
    val added = VerdeColors.DiffAdd.copy(alpha = .08f); val removed = VerdeColors.Danger.copy(alpha = .10f)
    Column(Modifier.fillMaxWidth().background(colors.surfaceContainerHighest, RoundedCornerShape(8.dp)).padding(vertical = 6.dp)
        .horizontalScroll(rememberScrollState())) {
        preview.changes.forEach { line ->
            val (prefix, background) = when (line.kind) {
                PreviewKind.Add -> "+ " to added
                PreviewKind.Remove -> "− " to removed
                PreviewKind.Hunk -> "" to Color.Transparent
                PreviewKind.Context -> "  " to Color.Transparent
            }
            Text(prefix + line.text, Modifier.background(background).padding(horizontal = 10.dp), style = mono, softWrap = false,
                color = if (line.kind == PreviewKind.Hunk) colors.outline else colors.onSurface)
        }
        if (preview.changesTruncated) Text("…", Modifier.padding(horizontal = 10.dp), style = mono, color = colors.outline)
    }
}

private const val DETAIL_LINES = 40

@Composable
private fun ApprovalDetails(approval: ChatApproval, preview: ApprovalPreview, onCopy: () -> Unit) {
    if (approval.body.isBlank()) return
    // Without a structured summary the raw request *is* the summary, so it starts open.
    val structured = preview.command != null || preview.changes.isNotEmpty() || preview.tool != null
    var expanded by rememberSaveable(approval.key) { mutableStateOf(!structured) }
    var all by rememberSaveable(approval.key + ":all") { mutableStateOf(false) }
    val colors = MaterialTheme.colorScheme
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        if (structured) Text(if (expanded) "▾ Hide full request" else "▸ Show full request",
            Modifier.clickable(onClickLabel = if (expanded) "Hide full request" else "Show full request") { expanded = !expanded }
                .padding(vertical = 6.dp), style = MaterialTheme.typography.labelMedium, color = colors.onSurfaceVariant)
        if (expanded) {
            val total = remember(approval.body) { countLines(approval.body) }
            val (shown, truncated) = remember(approval.body, all) { if (all) approval.body.trim() to false else leadingLines(approval.body, DETAIL_LINES) }
            Text(shown, Modifier.fillMaxWidth().background(colors.surfaceContainerHighest, RoundedCornerShape(8.dp))
                .horizontalScroll(rememberScrollState()).padding(horizontal = 10.dp, vertical = 8.dp)
                .semantics { contentDescription = "Approval details" },
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = VerdeMono), softWrap = false)
            Row {
                TextButton(onClick = onCopy) { Text("Copy request") }
                if (truncated) TextButton(onClick = { all = true }) { Text("Show all $total lines") }
            }
        }
    }
}

/**
 * Top-of-transcript strip: while an approval is pending and its card is off screen, a tap jumps to
 * it; after an approval leaves, a short notice says how it was resolved.
 */
@Composable
internal fun ApprovalBanner(reversed: List<TranscriptItem>, list: LazyListState, controller: ApprovalController, modifier: Modifier = Modifier) {
    val scope = rememberCoroutineScope()
    val local by controller.local.collectAsState()
    val outcome by controller.outcome.collectAsState()
    val index = reversed.indexOfFirst { it is TranscriptItem.Approval }
    val approval = (reversed.getOrNull(index) as? TranscriptItem.Approval)?.approval
    val cardKey = approval?.let { reversed[index].key }
    val cardVisible by remember(cardKey) {
        derivedStateOf { cardKey != null && list.layoutInfo.visibleItemsInfo.any { it.key == cardKey } }
    }
    val colors = MaterialTheme.colorScheme
    Box(modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp), contentAlignment = Alignment.TopCenter) {
        when {
            approval != null && !cardVisible -> {
                val phase = approvalPhase(approval, local)
                Surface(
                    onClick = { scope.launch { list.animateScrollToItem(index) } },
                    shape = RoundedCornerShape(20.dp), color = colors.tertiaryContainer, tonalElevation = 3.dp, shadowElevation = 3.dp,
                    modifier = Modifier.testTag(APPROVAL_BANNER).semantics { liveRegion = LiveRegionMode.Polite },
                ) {
                    Row(Modifier.padding(horizontal = 14.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Box(Modifier.size(8.dp).background(colors.tertiary, CircleShape))
                        Text(if (phase.canDecide()) "Needs approval · ${approval.title.ifBlank { "Permission required" }}" else phaseText(phase) ?: "Needs approval",
                            Modifier.weight(1f, fill = false), style = MaterialTheme.typography.labelLarge, color = colors.onTertiaryContainer,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text("View", style = MaterialTheme.typography.labelLarge, color = colors.tertiary, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
            approval == null && outcome != null -> {
                Surface(shape = RoundedCornerShape(20.dp), color = colors.secondaryContainer, tonalElevation = 3.dp) {
                    Text(outcome!!.outcome.text, Modifier.testTag(APPROVAL_OUTCOME).semantics { liveRegion = LiveRegionMode.Polite }
                        .padding(horizontal = 14.dp, vertical = 8.dp), style = MaterialTheme.typography.labelLarge,
                        color = colors.onSecondaryContainer)
                }
            }
        }
    }
}
