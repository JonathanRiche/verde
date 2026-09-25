package dev.verdeai.app

import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage

/** Frames and decoded links stay in memory. No image files, URI launch or payload logging. */
@androidx.annotation.OptIn(androidx.camera.core.ExperimentalGetImage::class)
@Composable
internal fun QrScanner(onLink: (String) -> Unit, onClose: () -> Unit, onError: () -> Unit) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    val previewView = remember { PreviewView(context) }
    val currentLink by rememberUpdatedState(onLink)
    val currentError by rememberUpdatedState(onError)
    DisposableEffect(owner) {
        val executor = ContextCompat.getMainExecutor(context)
        val scanner = BarcodeScanning.getClient(BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build())
        val preview = Preview.Builder().build().apply { setSurfaceProvider(previewView.surfaceProvider) }
        val analysis = ImageAnalysis.Builder().setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
        var disposed = false
        var delivered = false
        var provider: ProcessCameraProvider? = null
        analysis.setAnalyzer(executor) { frame ->
            val image = frame.image
            if (disposed || delivered || image == null) frame.close()
            else try {
                scanner.process(InputImage.fromMediaImage(image, frame.imageInfo.rotationDegrees))
                    .addOnSuccessListener(executor) { results ->
                        if (!disposed && !delivered) results.firstOrNull { it.rawValue != null }?.rawValue?.let {
                            delivered=true
                            currentLink(it)
                        }
                    }.addOnFailureListener(executor) { if (!disposed && !delivered) { delivered=true; currentError() } }
                    .addOnCompleteListener(executor) { frame.close() }
            } catch (_: Exception) { frame.close(); if (!disposed && !delivered) { delivered=true; currentError() } }
        }
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            if (!disposed) try {
                provider = future.get().also { it.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis) }
            } catch (_: Exception) { currentError() }
        }, executor)
        onDispose {
            disposed=true
            analysis.clearAnalyzer()
            provider?.unbind(preview, analysis)
            scanner.close()
        }
    }
    Dialog(onDismissRequest=onClose) {
        Surface {
            Column(Modifier.padding(16.dp), verticalArrangement=Arrangement.spacedBy(12.dp)) {
                Text("Scan the Verde pairing QR code")
                AndroidView(factory={ previewView }, modifier=Modifier.fillMaxWidth().height(320.dp))
                TextButton(onClick=onClose) { Text("Cancel scan") }
            }
        }
    }
}
