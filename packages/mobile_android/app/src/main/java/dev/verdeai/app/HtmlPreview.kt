package dev.verdeai.app

import android.content.Intent
import android.net.Uri
import android.webkit.*
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import java.io.ByteArrayInputStream

internal const val PREVIEW_HOST = "verde-preview.invalid"

/** Resolve once-decoded URL paths lexically; the host separately confines symlinks. */
internal fun previewPath(path: String): String? {
    if (!path.startsWith('/') || path.any { it < ' ' || it == '\u007f' || it == '\\' }) return null
    val parts = ArrayList<String>()
    for (part in path.split('/')) when (part) {
        "", "." -> Unit
        ".." -> if (parts.isEmpty()) return null else parts.removeAt(parts.lastIndex)
        else -> parts.add(part)
    }
    return "/" + parts.joinToString("/")
}
internal class PreviewLocation(document: String, root: String?) {
    private val document = requireNotNull(previewPath(document))
    private val root = requireNotNull(previewPath(root ?: document.substringBeforeLast('/').ifEmpty { "/" }))
    val url: String = Uri.Builder().scheme("https").authority(PREVIEW_HOST).path(this.document).build().toString()
    init { require(contains(this.document)) }
    private fun contains(path: String) = root == "/" || path == root || path.startsWith("$root/")
    fun resolve(url: Uri): String? {
        if (url.scheme != "https" || url.encodedAuthority != PREVIEW_HOST) return null
        return url.path?.let(::previewPath)?.takeIf(::contains)
    }
}

internal const val PREVIEW_CSP = "default-src 'none'; script-src 'self' https: http: 'unsafe-inline' 'unsafe-eval' blob:; style-src 'self' https: http: 'unsafe-inline'; img-src 'self' https: http: data: blob:; media-src 'self' https: http: data: blob:; font-src 'self' https: http: data:; connect-src 'self' https: http:; frame-src 'none'; object-src 'none'; base-uri 'self'; form-action 'none'"

/** This script only edits its own document; there is no native message handler or app bridge. */
internal val previewFailureScript = """
<script>(()=>{
 const failed=new Set(); let note;
 function render(){if(!document.body)return;if(!note){note=document.createElement('div');note.setAttribute('role','status');note.setAttribute('aria-live','polite');note.tabIndex=0;note.style.cssText='position:fixed!important;bottom:8px!important;left:8px!important;right:8px!important;z-index:2147483647!important;padding:8px!important;background:#fff4d6!important;color:#352800!important;font:13px system-ui!important;user-select:text!important;border-radius:6px!important';document.body.appendChild(note)}note.textContent=failed.size+(failed.size===1?" linked file couldn't load":" linked files couldn't load");}
 addEventListener('error',e=>{const t=e.target;if(t&&t!==window&&/^(IMG|SCRIPT|LINK|AUDIO|VIDEO|SOURCE)$/.test(t.tagName)){failed.add(t.currentSrc||t.src||t.href||t.tagName);render()}},true);
 addEventListener('DOMContentLoaded',()=>{if(failed.size)render();if(document.fonts)document.fonts.addEventListener('loadingerror',e=>{for(const f of e.fontfaces)failed.add('font:'+f.family);render()})});
})();</script>
""".trimIndent()
internal fun isolatedHtml(source: String) = """<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="$PREVIEW_CSP"><meta name="viewport" content="width=device-width, initial-scale=1">""" + previewFailureScript + source

internal fun previewMime(path: String, reported: String?): String = when (fileExtension(path)) {
    "css" -> "text/css"
    "js", "mjs", "cjs" -> "text/javascript"
    "html", "htm" -> "text/html"
    "svg" -> "image/svg+xml"
    "mp3" -> "audio/mpeg"
    "m4a" -> "audio/mp4"
    "ogg" -> "audio/ogg"
    "wav" -> "audio/wav"
    "woff" -> "font/woff"
    "woff2" -> "font/woff2"
    "ttf" -> "font/ttf"
    "otf" -> "font/otf"
    else -> MimeTypeMap.getSingleton().getMimeTypeFromExtension(fileExtension(path)) ?: reported ?: "application/octet-stream"
}

@Composable
internal fun HtmlFile(content: FileContent.Html, path: String, root: String?) {
    val location = remember(path, root) { PreviewLocation(path, root) }
    val html = remember(content) { isolatedHtml(content.source.text) }
    AndroidView(modifier = Modifier.fillMaxSize(), factory = { context ->
        WebView(context).apply {
            settings.javaScriptEnabled = true
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            settings.domStorageEnabled = false
            settings.mediaPlaybackRequiresUserGesture = true
            settings.blockNetworkLoads = false
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    if (location.resolve(request.url) != null) return false
                    if (request.isForMainFrame && request.hasGesture() && request.url.scheme in listOf("https", "http")) {
                        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, request.url)) }
                    }
                    return true
                }
                override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                    if (request.url.host != PREVIEW_HOST) {
                        return if (request.url.scheme in listOf("https", "http", "data", "blob")) null else denied(403)
                    }
                    val target = location.resolve(request.url) ?: return denied(403)
                    if (request.method !in listOf("GET", "HEAD")) return denied(405)
                    return try {
                        val access = content.access ?: return denied(503)
                        val range = request.requestHeaders.entries.firstOrNull { it.key.equals("Range", true) }?.value
                        val response = access.open(target, request.method, range)
                        if (response.code in 300..399) { response.close(); return denied(502) }
                        val mime = previewMime(target, response.body?.contentType()?.toString()?.substringBefore(';'))
                        val headers = buildMap {
                            for (name in listOf("Content-Length", "Content-Range", "Accept-Ranges", "Last-Modified", "ETag")) response.header(name)?.let { put(name, it) }
                            put("Content-Type", mime); put("Cache-Control", "no-store"); put("Content-Security-Policy", PREVIEW_CSP)
                        }
                        WebResourceResponse(mime, null, response.code, response.message.ifBlank { "File response" }, headers, access.stream(response))
                    } catch (_: Exception) { denied(502) }
                }
            }
            loadDataWithBaseURL(location.url, html, "text/html", "utf-8", null)
        }
    }, onRelease = { it.stopLoading(); it.destroy(); content.access?.cancel() })
}
private fun denied(status: Int) = WebResourceResponse("text/plain", "utf-8", status, "File unavailable", emptyMap(), ByteArrayInputStream(ByteArray(0)))
