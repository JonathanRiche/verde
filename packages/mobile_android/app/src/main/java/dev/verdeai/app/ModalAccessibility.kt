package dev.verdeai.app

import android.view.View
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView

/** Only the front modal window belongs in TalkBack's reading order. Restore each window's
 * original setting when its last modal closes, including when a parent closes before its child. */
@Stable
internal class ModalLayers {
    private val windows = mutableStateListOf<View>()
    private val originals = java.util.IdentityHashMap<View, Int>()
    private val references = java.util.IdentityHashMap<View, Int>()

    fun add(background: View, modal: View) {
        if (!originals.containsKey(background)) originals[background] = background.importantForAccessibility
        if (!originals.containsKey(modal)) originals[modal] = modal.importantForAccessibility
        references[modal] = (references[modal] ?: 0) + 1
        if (modal !in windows) windows.add(modal)
        update()
    }

    fun remove(modal: View) {
        val remaining = (references[modal] ?: 1) - 1
        if (remaining > 0) { references[modal] = remaining; return }
        references.remove(modal)
        windows.remove(modal)
        originals.remove(modal)?.let { modal.importantForAccessibility = it }
        if (windows.isEmpty()) {
            originals.forEach { (view, original) -> view.importantForAccessibility = original }
            originals.clear()
        } else update()
    }

    fun covered(window: View) = windows.isNotEmpty() && windows.last() !== window

    private fun update() {
        originals.forEach { (view, original) ->
            view.importantForAccessibility = if (view === windows.lastOrNull()) original
                else View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        }
    }
}

internal val LocalModalLayers = compositionLocalOf<ModalLayers?> { null }

@Composable
internal fun ModalAccessibility() {
    val layers = LocalModalLayers.current ?: return
    val context = LocalContext.current
    val activity = remember(context) {
        generateSequence(context) { (it as? android.content.ContextWrapper)?.baseContext }.filterIsInstance<android.app.Activity>().firstOrNull()
    } ?: return
    val root = LocalView.current.rootView
    DisposableEffect(layers, root, activity) {
        val background = activity.window.decorView
        if (root === background) return@DisposableEffect onDispose { }
        layers.add(background, root)
        onDispose { layers.remove(root) }
    }
}

/** Underlying sheets keep their position, but only the top sheet draws a grabber. */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
internal fun TopModalDragHandle(content: @Composable () -> Unit = { androidx.compose.material3.BottomSheetDefaults.DragHandle() }) {
    val root = LocalView.current.rootView
    if (LocalModalLayers.current?.covered(root) != true) content()
}
