package dev.verdeai.app

import androidx.compose.foundation.background
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/**
 * Top-bar host picker. Every saved host keeps its own core, so switching only changes the
 * catalog's active id; [BrowseModel] then drops the old projection and observes the new core.
 * Hosts that cannot be used yet open their pairing flow instead of becoming active.
 */
@Composable
internal fun HostSwitcher(model: HostsModel, onSwitched: () -> Unit, onPairing: () -> Unit) {
    val state by model.state.collectAsState()
    var expanded by remember { mutableStateOf(false) }
    var adding by remember { mutableStateOf(false) }
    val active = state.rows.find { it.saved.id == state.active }
    Box {
        // S22: the host pill (iOS parity): status dot, name, chevron; a 48dp target.
        OutlinedButton(onClick = { expanded = true }, enabled = !state.loading, shape = RoundedCornerShape(50),
            border = androidx.compose.foundation.BorderStroke(1.dp, VerdeColors.Border),
            contentPadding = PaddingValues(start = 12.dp, end = 6.dp),
            modifier = Modifier.heightIn(min = 48.dp).widthIn(max = 200.dp)
                .semantics { contentDescription = "Host: ${active?.saved?.label ?: "none"}" + (active?.let { ", ${hostStatus(it)}" } ?: "") + ". Switch host" }) {
            active?.let { Box(Modifier.size(8.dp).background(hostDotColor(it), CircleShape)) }
            Spacer(Modifier.width(6.dp))
            Text(active?.saved?.label ?: "Choose host", style = MaterialTheme.typography.labelLarge, color = VerdeColors.Text,
                maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
            Icon(Icons.Filled.ArrowDropDown, contentDescription = null, tint = VerdeColors.Muted)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            LiveOverMenu()
            state.rows.forEach { row ->
                val id = row.saved.id
                val selected = id == state.active
                DropdownMenuItem(
                    text = { Column {
                        Text(row.saved.label, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Box(Modifier.size(7.dp).background(hostDotColor(row), CircleShape))
                            Text(hostStatus(row), style = MaterialTheme.typography.bodySmall, color = VerdeColors.Muted,
                                maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    } },
                    leadingIcon = {
                        if (selected) Icon(Icons.Filled.Check, contentDescription = "Active host", tint = VerdeColors.Accent)
                        else Spacer(Modifier.size(24.dp))
                    },
                    enabled = !state.busy && !row.fatal,
                    onClick = {
                        expanded = false
                        when {
                            selected -> Unit
                            usable(row) -> model.select(id, onSwitched)
                            row.view?.auth_state != "signing_out" -> { model.showPairing(id); onPairing() }
                        }
                    })
            }
            HorizontalDivider()
            DropdownMenuItem(text = { Text("Add new host") },
                leadingIcon = { Icon(Icons.Filled.Add, contentDescription = null) },
                enabled = !state.busy,
                onClick = { expanded = false; adding = true })
        }
    }
    if (adding) AddHostDialog(onAdd = { model.add(it); onPairing() }, onDismiss = { adding = false })
}

/** Matches the Hosts screen's "Use" button: paired and with no pending identity review. */
private fun usable(row: HostRow) = row.view?.auth_state == "paired" && row.view.trust_proposal == null
