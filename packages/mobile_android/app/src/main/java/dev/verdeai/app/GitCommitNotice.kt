package dev.verdeai.app

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.platform.LocalUriHandler
import java.net.URI
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

internal data class GitCommitNoticeData(val title: String, val commits: String?, val pushed: Boolean,
    val subject: String? = null, val branch: String? = null, val remotes: List<String> = emptyList())

/** Accept old one-line receipts; preserve unfamiliar receipts without inventing metadata. */
internal fun parseGitCommitNotice(body: String): GitCommitNoticeData {
    val lines = body.lines()
    val first = lines.firstOrNull().orEmpty().trim()
    val match = Regex("^(Committed [0-9]+ files?): (.+?)( · pushed)?$").matchEntire(first)
        ?: return GitCommitNoticeData(first, null, false)
    // Positional fields retain blank lines; a subject starting with "branch" is still a subject.
    val subject = lines.getOrNull(1)?.trim()?.takeIf { it.isNotEmpty() }
    val branch = lines.getOrNull(2)?.trim()?.takeIf { it.startsWith("branch ") }?.removePrefix("branch ")?.takeIf { it.isNotBlank() }
    val remotes = lines.drop(3).mapNotNull { line ->
        line.removePrefix("remote ").takeIf { line.startsWith("remote ") && gitCommitLinkHost(it) != null }
    }.distinct()
    return GitCommitNoticeData(match.groupValues[1], match.groupValues[2], match.groupValues[3].isNotEmpty(), subject, branch, remotes)
}

internal fun gitCommitLinkHost(url: String): String? = try {
    val uri = URI(url)
    uri.host?.takeIf { uri.scheme == "https" && uri.userInfo == null && uri.fragment == null && uri.query == null && uri.path.contains("/commit/") }
} catch (_: Exception) { null }

internal fun showGitCardPush(notice: GitCommitNoticeData, state: GitChangesState, chat: GitChat) =
    !notice.pushed && state.snapshot.access[chat] == GitAccess.Writable &&
        state.snapshot.branches[chat].orEmpty().any { it.hasRemote && it.ahead > 0 }

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun GitCommitNotice(body: String, model: GitChangesModel? = null) {
    val uriHandler = LocalUriHandler.current
    val state = model?.state?.collectAsState()?.value
    val notice = remember(body) { parseGitCommitNotice(body) }
    Surface(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp).testTag("git-commit-notice"),
        color = VerdeColors.Panel, shape = RoundedCornerShape(10.dp), border = BorderStroke(1.dp, VerdeColors.Border.copy(alpha = .5f))) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Filled.Check, null, tint = VerdeColors.Accent, modifier = Modifier.size(18.dp))
                Text(if (notice.pushed) notice.title.replaceFirst("Committed", "Committed & pushed") else notice.title, Modifier.weight(1f), style = MaterialTheme.typography.labelLarge)
                if (notice.pushed) Surface(color = VerdeColors.Accent.copy(alpha = .12f), shape = RoundedCornerShape(7.dp)) {
                    Text("Pushed", Modifier.padding(horizontal = 7.dp, vertical = 2.dp), color = VerdeColors.Accent, style = MaterialTheme.typography.labelSmall)
                }
            }
            notice.commits?.let { Text(it, fontFamily = VerdeMono, style = MaterialTheme.typography.bodySmall, color = VerdeColors.Muted) }
            notice.subject?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = VerdeColors.Muted, maxLines = 1, overflow = TextOverflow.Ellipsis) }
            notice.branch?.let {
                Surface(color = VerdeColors.Background, shape = RoundedCornerShape(7.dp)) {
                    Text("branch $it", Modifier.padding(horizontal = 7.dp, vertical = 3.dp), style = MaterialTheme.typography.labelSmall,
                        color = VerdeColors.Subtle, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            notice.remotes.forEach { url ->
                TextButton(onClick = { try { uriHandler.openUri(url) } catch (_: Exception) { /* No browser installed. */ } }) {
                    Text("View on ${gitCommitLinkHost(url)}")
                }
            }
            if (model != null && state != null && showGitCardPush(notice, state, model.chat)) {
                TextButton(onClick = { model.push() }, enabled = !state.busy && state.snapshot.connected, modifier = Modifier.testTag("git-card-push")) {
                    if (state.busy) CircularProgressIndicator(Modifier.size(16.dp).padding(end = 4.dp), strokeWidth = 2.dp)
                    Text(if (state.busy) "Pushing…" else "Push")
                }
            }
        }
    }
}
