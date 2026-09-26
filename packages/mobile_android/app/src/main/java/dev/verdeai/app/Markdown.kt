package dev.verdeai.app

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import dev.verdeai.core.*

/**
 * Block model built from the core's K-11 markdown AST. There is deliberately no Kotlin markdown
 * parser: when the core cannot render a body (too large, query failure) the source is shown as text.
 */
internal sealed interface MdBlock {
    data class Paragraph(val text: AnnotatedString) : MdBlock
    data class Heading(val level: Int, val text: AnnotatedString) : MdBlock
    data class Bullets(val ordered: Boolean, val items: List<List<MdBlock>>) : MdBlock
    data class Quote(val blocks: List<MdBlock>) : MdBlock
    data class Code(val code: String, val language: String?) : MdBlock
    data object Rule : MdBlock
    data class Table(val rows: List<List<AnnotatedString>>) : MdBlock
}

internal data class MdStyle(val link: Color, val codeBackground: Color)

/** K-11 `highlight` queries for code blocks; the transcript and the file viewer (D-12) supply one. */
internal interface HighlightSource {
    fun cachedHighlight(code: String, language: String): RenderResult<List<RenderSpan>>?
    suspend fun highlight(code: String, language: String): RenderResult<List<RenderSpan>>
}

/** Only the link schemes the core admits are ever made tappable. */
internal fun safeLinkUrl(url: String?): String? {
    val value = url?.trim() ?: return null
    val scheme = value.substringBefore(':', "").lowercase()
    return value.takeIf { scheme == "http" || scheme == "https" || scheme == "mailto" }
}

internal fun citationLabel(citation: FileCitation) = basename(citation.path) +
    (citation.line?.let { line -> ":$line" + (citation.end_line?.takeIf { it > line }?.let { "-$it" } ?: "") } ?: "")

internal fun markdownBlocks(nodes: List<MarkdownNode>, style: MdStyle, onCitation: (FileCitation) -> Unit): List<MdBlock> {
    val out = ArrayList<MdBlock>()
    for (node in nodes) block(node, style, onCitation, out)
    return out
}

private fun block(node: MarkdownNode, style: MdStyle, onCitation: (FileCitation) -> Unit, out: MutableList<MdBlock>) {
    when (node.kind) {
        "document" -> node.children.forEach { block(it, style, onCitation, out) }
        "paragraph" -> out.add(MdBlock.Paragraph(inline(node.children, style, onCitation)))
        "heading" -> out.add(MdBlock.Heading((node.level ?: 1).coerceIn(1, 6), inline(node.children, style, onCitation)))
        "list" -> out.add(MdBlock.Bullets(node.ordered == true, node.children.map { item ->
            val blocks = ArrayList<MdBlock>()
            if (item.kind == "item") item.children.forEach { block(it, style, onCitation, blocks) } else block(item, style, onCitation, blocks)
            blocks
        }))
        "quote" -> out.add(MdBlock.Quote(markdownBlocks(node.children, style, onCitation)))
        "code_block" -> out.add(MdBlock.Code(node.text ?: "", node.language?.takeIf { it.isNotBlank() }))
        "thematic_break" -> out.add(MdBlock.Rule)
        "table" -> out.add(MdBlock.Table(node.children.filter { it.kind == "table_row" }.map { row ->
            row.children.map { cell -> inline(cell.children, style, onCitation) }
        }))
        // Inline content at block level (e.g. a bare image) becomes its own paragraph.
        else -> out.add(MdBlock.Paragraph(inline(listOf(node), style, onCitation)))
    }
}

private fun inline(nodes: List<MarkdownNode>, style: MdStyle, onCitation: (FileCitation) -> Unit): AnnotatedString =
    buildAnnotatedString { nodes.forEach { appendInline(it, style, onCitation) } }

private fun AnnotatedString.Builder.appendInline(node: MarkdownNode, style: MdStyle, onCitation: (FileCitation) -> Unit) {
    fun children() = node.children.forEach { appendInline(it, style, onCitation) }
    val linkStyles = TextLinkStyles(SpanStyle(color = style.link, textDecoration = TextDecoration.Underline))
    when (node.kind) {
        "text" -> append(node.text ?: "")
        "emphasis" -> withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { children() }
        "strong" -> withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { children() }
        "strike" -> withStyle(SpanStyle(textDecoration = TextDecoration.LineThrough)) { children() }
        "code" -> withStyle(SpanStyle(fontFamily = VerdeMono, color = VerdeColors.Heading1, background = style.codeBackground)) { append(node.text ?: "") }
        "line_break" -> append('\n')
        "link" -> {
            val citation = node.citation
            val url = safeLinkUrl(node.url)
            when {
                citation != null -> withLink(LinkAnnotation.Clickable("citation", linkStyles) { onCitation(citation) }) {
                    if (node.children.isEmpty()) append(citationLabel(citation)) else children()
                }
                url != null -> withLink(LinkAnnotation.Url(url, linkStyles)) { children() }
                else -> withStyle(SpanStyle(textDecoration = TextDecoration.Underline)) { children() }
            }
        }
        // Remote images are never fetched; the alt text stands in.
        "image" -> withStyle(SpanStyle(fontStyle = FontStyle.Italic)) {
            append("[image")
            if (node.children.isNotEmpty()) { append(": "); children() }
            append("]")
        }
        else -> children()
    }
}

/**
 * Maps every UTF-8 byte offset of [text] to its UTF-16 index (continuation bytes map to the start
 * of their character), so K-11 byte spans can style a Kotlin string.
 */
internal fun utf8ToUtf16(text: String): IntArray {
    var bytes = 0
    var i = 0
    while (i < text.length) { val cp = text.codePointAt(i); bytes += utf8Length(cp); i += Character.charCount(cp) }
    val out = IntArray(bytes + 1)
    var b = 0
    i = 0
    while (i < text.length) {
        val cp = text.codePointAt(i)
        repeat(utf8Length(cp)) { out[b++] = i }
        i += Character.charCount(cp)
    }
    out[b] = text.length
    return out
}

private fun utf8Length(cp: Int) = when { cp < 0x80 -> 1; cp < 0x800 -> 2; cp < 0x10000 -> 3; else -> 4 }

internal fun highlighted(code: String, spans: List<RenderSpan>, color: (String) -> SpanStyle?): AnnotatedString {
    if (spans.isEmpty()) return AnnotatedString(code)
    val map = utf8ToUtf16(code)
    val last = map.size - 1
    return buildAnnotatedString {
        append(code)
        for (span in spans) {
            val style = color(span.kind) ?: continue
            val start = map[span.start.coerceAtMost(last.toULong()).toInt()]
            val end = map[span.end.coerceAtMost(last.toULong()).toInt()]
            if (end > start) addStyle(style, start, end)
        }
    }
}

@Composable
internal fun tokenStyle(): (String) -> SpanStyle? {
    val c = MaterialTheme.colorScheme
    return remember(c) {
        { kind ->
            when (kind) {
                "keyword" -> SpanStyle(color = Color(0xFFFBC12D), fontWeight = FontWeight.SemiBold)
                "string" -> SpanStyle(color = Color(0xFF4EE29E))
                "number", "constant_name" -> SpanStyle(color = VerdeColors.Heading1)
                "comment" -> SpanStyle(color = c.outline, fontStyle = FontStyle.Italic)
                "type_name" -> SpanStyle(color = c.tertiary)
                "function_name" -> SpanStyle(color = Color(0xFF5ECB83))
                "property_name" -> SpanStyle(color = c.secondary)
                "operator", "punctuation" -> SpanStyle(color = c.onSurfaceVariant)
                else -> null
            }
        }
    }
}

internal const val MARKDOWN_TAG = "markdown"
internal const val PLAIN_TAG = "plain-text"

/** Renders [text] from the core's markdown AST, falling back to the literal source. */
@Composable
internal fun MarkdownText(text: String, model: TranscriptModel, onCitation: (FileCitation) -> Unit, modifier: Modifier = Modifier) {
    val result by produceState(model.cachedMarkdown(text), text) { value = model.markdown(text) }
    val nodes = result?.value
    if (nodes == null) {
        // Pending (first frame) or unrenderable: the source text, never re-parsed in Kotlin.
        Text(text, modifier.testTag(PLAIN_TAG), style = MaterialTheme.typography.bodyMedium)
        return
    }
    val colors = MaterialTheme.colorScheme
    val callback by rememberUpdatedState(onCitation)
    val blocks = remember(nodes, colors) { markdownBlocks(nodes, MdStyle(colors.primary, colors.surfaceVariant)) { callback(it) } }
    MarkdownBlocks(blocks, model, modifier.testTag(MARKDOWN_TAG))
}

@Composable
internal fun MarkdownBlocks(blocks: List<MdBlock>, model: HighlightSource, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        blocks.forEach { MdBlockView(it, model) }
    }
}

@Composable
private fun MdBlockView(block: MdBlock, model: HighlightSource) {
    val type = MaterialTheme.typography
    when (block) {
        is MdBlock.Paragraph -> Text(block.text, style = type.bodyMedium)
        is MdBlock.Heading -> Text(block.text,
            color = when (block.level) { 1 -> VerdeColors.Heading1; 2 -> VerdeColors.Heading2; 3 -> VerdeColors.Heading3; else -> VerdeColors.Heading4 },
            style = (when (block.level) { 1 -> type.headlineMedium; 2 -> type.headlineSmall; else -> type.titleLarge }))
        is MdBlock.Bullets -> Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            block.items.forEachIndexed { index, item ->
                Row {
                    Text(if (block.ordered) "${index + 1}." else "•", Modifier.widthIn(min = 20.dp), style = type.bodyMedium)
                    MarkdownBlocks(item, model, Modifier.weight(1f))
                }
            }
        }
        is MdBlock.Quote -> Row(Modifier.height(IntrinsicSize.Min)) {
            Box(Modifier.width(3.dp).fillMaxHeight().background(MaterialTheme.colorScheme.outlineVariant))
            MarkdownBlocks(block.blocks, model, Modifier.padding(start = 8.dp).weight(1f))
        }
        is MdBlock.Code -> CodeBlock(block.code, block.language, model)
        MdBlock.Rule -> HorizontalDivider()
        is MdBlock.Table -> Column(Modifier.horizontalScroll(rememberScrollState())
            .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(4.dp))) {
            block.rows.forEachIndexed { index, row ->
                Row {
                    row.forEach { cell ->
                        Text(cell, Modifier.width(140.dp).padding(6.dp),
                            style = if (index == 0) type.labelLarge else type.bodySmall)
                    }
                }
                if (index < block.rows.size - 1) HorizontalDivider(Modifier.width(140.dp * row.size))
            }
        }
    }
}

internal const val CODE_BLOCK_TAG = "code-block"

@Composable
internal fun CodeBlock(code: String, language: String?, model: HighlightSource) {
    @Suppress("DEPRECATION") val clipboard = LocalClipboardManager.current
    val spans by produceState(language?.let { model.cachedHighlight(code, it) }, code, language) {
        value = language?.let { model.highlight(code, it) }
    }
    val style = tokenStyle()
    // Spans index the exact code the core highlighted; only the trailing newline is dropped for display.
    val text = remember(code, spans, style) { highlighted(code, spans?.value.orEmpty(), style).let { if (code.endsWith("\n")) it.subSequence(0, code.length - 1) else it } }
    Column(Modifier.fillMaxWidth().background(VerdeColors.Background, RoundedCornerShape(7.dp))
        .border(1.dp, VerdeColors.Border, RoundedCornerShape(7.dp)).testTag(CODE_BLOCK_TAG)) {
        Row(Modifier.fillMaxWidth().background(VerdeColors.PanelAlt, RoundedCornerShape(topStart = 7.dp, topEnd = 7.dp)).padding(start = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(language ?: "code", Modifier.weight(1f), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            TextButton(onClick = { clipboard.setText(AnnotatedString(code.removeSuffix("\n"))) }) { Text("Copy code") }
        }
        Text(text, Modifier.horizontalScroll(rememberScrollState()).padding(start = 10.dp, end = 10.dp, bottom = 10.dp),
            style = MaterialTheme.typography.bodySmall.copy(fontFamily = VerdeMono), softWrap = false)
    }
}
