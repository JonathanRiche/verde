package dev.verdeai.app

import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.window.DialogWindowProvider
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex

/** Outside the scrolling body, and above it in both hit testing and accessibility bounds. */
@Composable
internal fun SheetHeader(title: String, onClose: () -> Unit, style: TextStyle = MaterialTheme.typography.titleLarge) {
    Column(Modifier.zIndex(1f).background(VerdeColors.Panel)) {
        Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(title, Modifier.weight(1f), style = style)
            SheetCloseButton(onClose)
        }
        HorizontalDivider(color = VerdeColors.Border)
    }
}

/** Material's full-window scrim is exposed as a tiny clipped "Close sheet" target beside the nav
 * bar. Sheets with a pinned Close use this decorative, pointer-dismiss backdrop instead. It adds
 * no keyboard/AX stop: the visible 48dp Close and Back/Escape own that action. Pass Unspecified as
 * ModalBottomSheet.scrimColor so the duplicate Material target isn't created. */
@Composable
internal fun SheetDismissBackdrop(onDismiss: () -> Unit) {
    val view = LocalView.current
    val dismiss by rememberUpdatedState(onDismiss)
    DisposableEffect(view) {
        // Dim the activity behind the sheet's dialog. A child at decor index zero can be painted
        // over by the Compose root, leaving the transcript undimmed on some OEMs.
        val window = generateSequence(view.parent) { it.parent }.filterIsInstance<DialogWindowProvider>().firstOrNull()?.window
        val oldDim = window?.attributes?.dimAmount
        val hadDim = window?.attributes?.flags?.and(android.view.WindowManager.LayoutParams.FLAG_DIM_BEHIND) != 0
        window?.addFlags(android.view.WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        window?.setDimAmount(.5f)
        val decor = view.rootView as? FrameLayout ?: return@DisposableEffect onDispose { }
        val backdrop = View(view.context).apply {
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            isFocusable = false
            setOnClickListener { dismiss() }
        }
        decor.addView(backdrop, 0, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        onDispose {
            // Dismissal can be in the middle of Android's window-detach walk.
            android.os.Handler(android.os.Looper.getMainLooper()).post { decor.removeView(backdrop) }
            oldDim?.let { window?.setDimAmount(it) }
            if (!hadDim) window?.clearFlags(android.view.WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        }
    }
}
