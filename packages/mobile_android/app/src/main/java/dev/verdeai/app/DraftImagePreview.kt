package dev.verdeai.app

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Already-bounded draft JPEG bytes only; no network, disk cache, or public URI. */
@Composable
internal fun DraftImagePreview(bytes: ByteArray, name: String) {
    val bitmap by produceState<android.graphics.Bitmap?>(null, bytes) {
        value = withContext(Dispatchers.Default) { BitmapFactory.decodeByteArray(bytes, 0, bytes.size) }
    }
    val decoded = bitmap ?: return
    var expanded by remember { mutableStateOf(false) }
    Image(decoded.asImageBitmap(), "Preview $name", contentScale = ContentScale.Crop,
        modifier = Modifier.size(64.dp).padding(end = 8.dp).clickable { expanded = true })
    if (expanded) Dialog(onDismissRequest = { expanded = false }) {
        Surface(shape = MaterialTheme.shapes.large, color = VerdeColors.Panel) {
            Column(Modifier.padding(12.dp)) {
                Image(decoded.asImageBitmap(), name, contentScale = ContentScale.Fit,
                    modifier = Modifier.fillMaxWidth().heightIn(max = 480.dp))
                TextButton(onClick = { expanded = false }) { Text("Close preview") }
            }
        }
    }
}
