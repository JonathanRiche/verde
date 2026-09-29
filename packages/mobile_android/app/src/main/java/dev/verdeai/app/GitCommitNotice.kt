package dev.verdeai.app

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

internal data class GitCommitNoticeData(val title: String, val commits: String?, val pushed: Boolean,
    val subject: String? = null, val branch: String? = null)

/** Accept old one-line receipts; preserve unfamiliar receipts without inventing metadata. */
internal fun parseGitCommitNotice(body: String): GitCommitNoticeData {
    val lines = body.lines()
    val first = lines.firstOrNull().orEmpty().trim()
    val match = Regex("^(Committed [0-9]+ files?): (.+?)( · pushed)?$").matchEntire(first)
        ?: return GitCommitNoticeData(first, null, false)
    val extra = lines.drop(1).map(String::trim)
    val branch = extra.lastOrNull()?.takeIf { it.startsWith("branch ") }?.removePrefix("branch ")?.takeIf { it.isNotBlank() }
    val subject = extra.firstOrNull()?.takeIf { it.isNotBlank() && !(extra.size == 1 && branch != null) }
    return GitCommitNoticeData(match.groupValues[1], match.groupValues[2], match.groupValues[3].isNotEmpty(), subject, branch)
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun GitCommitNotice(body: String) {
    val notice = remember(body) { parseGitCommitNotice(body) }
    Surface(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp).testTag("git-commit-notice"),
        color = VerdeColors.Panel, shape = RoundedCornerShape(10.dp), border = BorderStroke(1.dp, VerdeColors.Border.copy(alpha = .5f))) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Filled.Check, null, tint = VerdeColors.Accent, modifier = Modifier.size(18.dp))
                Text(notice.title, Modifier.weight(1f), style = MaterialTheme.typography.labelLarge)
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
        }
    }
}
