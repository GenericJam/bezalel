package io.mob.markdown

import android.content.Context
import android.graphics.Paint
import android.graphics.Typeface
import android.text.Spannable
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.TextPaint
import android.text.method.ArrowKeyMovementMethod
import android.text.style.ClickableSpan
import android.text.style.ForegroundColorSpan
import android.text.style.LineHeightSpan
import android.text.style.MetricAffectingSpan
import android.text.style.RelativeSizeSpan
import android.text.style.URLSpan
import android.text.util.Linkify
import android.util.TypedValue
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.widget.TextView
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.res.ResourcesCompat
import io.noties.markwon.AbstractMarkwonPlugin
import io.noties.markwon.Markwon
import io.noties.markwon.MarkwonConfiguration
import io.noties.markwon.MarkwonSpansFactory
import io.noties.markwon.core.CoreProps
import io.noties.markwon.core.MarkwonTheme
import io.noties.markwon.ext.strikethrough.StrikethroughPlugin
import io.noties.markwon.ext.tables.TableAwareMovementMethod
import io.noties.markwon.ext.tables.TablePlugin
import io.noties.markwon.ext.tables.TableRowSpan
import io.noties.markwon.html.HtmlPlugin
import io.noties.markwon.linkify.LinkifyPlugin
import org.commonmark.ext.gfm.tables.TableBlock
import org.commonmark.ext.gfm.tables.TableRow
import org.commonmark.node.AbstractVisitor
import org.commonmark.node.Code
import org.commonmark.node.CustomBlock
import org.commonmark.node.CustomNode
import org.commonmark.node.Document
import org.commonmark.node.Emphasis
import org.commonmark.node.Heading
import org.commonmark.node.Node
import org.commonmark.node.StrongEmphasis
import org.commonmark.node.Text
import kotlin.math.roundToInt

// The Android side of MobMarkdown.View (see the MobMarkdown moduledoc for the
// props). Markwon renders the Markdown to Spannables in selectable
// TextViews, so inline styles wrap like prose and any text can be
// drag-selected and copied. The document is cut at its tables: the prose
// between them wraps to the view's width, and each table (Markwon's table
// plugin, which splits its width evenly between the columns) gets its own
// TextView at the table's natural width, at least the view's, in a
// horizontal scroller: a wide table scrolls sideways, a narrow one fills the
// view and sits still.
//
// mob_dev's generated MobPluginBootstrap registers MobMarkdownView under
// "MobMarkdown_View" (the manifest's ui_components factory).
//
// One Markwon instance per style serves every view. The segments are
// re-parsed only when `text` or the style changes (a streaming reply grows a
// few times a second; finished ones never change), and a segment's TextView
// takes new text only when its own text changed.

/** The send closure MobNativeViewRegistry hands a factory (its MobNativeSend). */
typealias MobMarkdownSend = (event: String, payload: Map<String, Any>) -> Unit

internal object MobMarkdown {
    private var faces: MdFaces? = null
    private var facesKey: List<String>? = null
    // One Markwon per style in use (an app may interleave a few, e.g. a
    // reply's and an aside's), with and without Linkify; cleared if styles
    // keep changing.
    private val markwons = HashMap<Pair<MdStyle, Boolean>, Markwon>()

    // Main thread only (Compose). Tables get no Linkify: their cells keep
    // links of their own (TableRowSpan), out of dropBareDomainLinks' reach,
    // so a module name in a cell would turn into a web link.
    fun markwon(context: Context, style: MdStyle, linkify: Boolean = true): Markwon {
        val key = style to linkify
        markwons[key]?.let { return it }
        if (markwons.size >= MAX_STYLES) markwons.clear()
        val built = build(context.applicationContext, style, faces(context, style), linkify)
        markwons[key] = built
        return built
    }

    fun faces(context: Context, style: MdStyle): MdFaces {
        val key = listOf(
            style.fontRegular, style.fontBold, style.fontItalic, style.fontBoldItalic,
            style.fontHeading, style.fontCode,
        )
        faces?.let { if (key == facesKey) return it }
        val ctx = context.applicationContext
        val regular = font(ctx, style.fontRegular) ?: Typeface.DEFAULT
        val bold = font(ctx, style.fontBold) ?: Typeface.create(regular, Typeface.BOLD)
        // No italic face: Typeface.create asks for the style and the text
        // stack slants the upright face (fake italic).
        val italic = font(ctx, style.fontItalic) ?: Typeface.create(regular, Typeface.ITALIC)
        val boldItalic = font(ctx, style.fontBoldItalic) ?: Typeface.create(bold, Typeface.BOLD_ITALIC)
        val loaded = MdFaces(
            regular = regular,
            bold = bold,
            italic = italic,
            boldItalic = boldItalic,
            heading = font(ctx, style.fontHeading) ?: bold,
            code = font(ctx, style.fontCode) ?: Typeface.MONOSPACE,
        )
        faces = loaded
        facesKey = key
        return loaded
    }

    // A bundled res/font face by name (normalised like MobBridge's font
    // lookup), or null for "" and a name the app doesn't bundle.
    private fun font(ctx: Context, name: String): Typeface? {
        val res = name.lowercase().replace(Regex("[^a-z0-9_]"), "_")
        if (res.isEmpty()) return null
        val id = ctx.resources.getIdentifier(res, "font", ctx.packageName)
        if (id == 0) {
            android.util.Log.w("MobMarkdown", "no font resource $res")
            return null
        }
        return try {
            ResourcesCompat.getFont(ctx, id)
        } catch (e: Exception) {
            android.util.Log.w("MobMarkdown", "font $res failed to load: ${e.message}")
            null
        }
    }

    private fun build(ctx: Context, style: MdStyle, faces: MdFaces, linkify: Boolean): Markwon {
        val px = { sp: Float ->
            TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, sp, ctx.resources.displayMetrics)
        }
        // Monospace at the body size reads large next to a proportional face.
        val codePx = px(style.textSize * CODE_SCALE).toInt()
        val pad = px(style.textSize / 2).toInt()

        val builder = Markwon.builder(ctx)
            .usePlugin(StrikethroughPlugin.create())
            .usePlugin(TablePlugin.create(TablePlugin.ThemeConfigure { b ->
                b.tableBorderColor(style.ruleColor)
                    .tableBorderWidth(px(1f).toInt().coerceAtLeast(1))
                    .tableCellPadding(pad)
                    .tableHeaderRowBackgroundColor(style.codeBackground)
                    .tableEvenRowBackgroundColor(0)
                    .tableOddRowBackgroundColor(0)
            }))
        if (linkify) builder.usePlugin(LinkifyPlugin.create(Linkify.WEB_URLS or Linkify.EMAIL_ADDRESSES))
        return builder
            .usePlugin(HtmlPlugin.create())
            .usePlugin(object : AbstractMarkwonPlugin() {
                override fun configureTheme(builder: MarkwonTheme.Builder) {
                    builder
                        .codeTextColor(style.codeColor)
                        .codeBackgroundColor(style.codeBackground)
                        .codeTypeface(faces.code)
                        .codeTextSize(codePx)
                        .codeBlockTextColor(style.codeColor)
                        .codeBlockBackgroundColor(style.codeBackground)
                        .codeBlockTypeface(faces.code)
                        .codeBlockTextSize(codePx)
                        .codeBlockMargin(pad)
                        .linkColor(style.linkColor)
                        .isLinkUnderlined(true)
                        .blockQuoteColor(style.quoteColor)
                        .listItemColor(style.quoteColor)
                        .thematicBreakColor(style.ruleColor)
                        .thematicBreakHeight(px(1f).toInt().coerceAtLeast(1))
                        .headingBreakHeight(0)
                }

                // Links go to the BEAM (MobMarkdown.View handles "open_link"
                // and opens only web and mail links), through the view's
                // current `send`.
                override fun configureConfiguration(builder: MarkwonConfiguration.Builder) {
                    builder.linkResolver { view, link ->
                        (view.tag as? MdHolder)?.send?.invoke("open_link", mapOf("url" to link))
                    }
                }

                override fun configureSpansFactory(builder: MarkwonSpansFactory.Builder) {
                    builder.setFactory(StrongEmphasis::class.java) { _, _ -> FaceSpan(faces, bold = true) }
                    builder.setFactory(Emphasis::class.java) { _, _ -> FaceSpan(faces, bold = false) }
                    builder.setFactory(Heading::class.java) { _, props ->
                        val level = CoreProps.HEADING_LEVEL.require(props)
                        arrayOf(
                            RelativeSizeSpan(HEADING_SIZES[(level - 1).coerceIn(0, HEADING_SIZES.size - 1)]),
                            HeadingSpan(faces.heading),
                            ForegroundColorSpan(style.headingColor),
                        )
                    }
                }
            })
            .build()
    }

    /**
     * `text` parsed and cut at its tables: the prose between them (with the
     * line height on its lines of text, see LineSpacing) and each table with
     * its natural width in px.
     */
    fun segments(context: Context, style: MdStyle, text: String): List<MdSegment> {
        val markwon = markwon(context, style)
        val doc = markwon.parse(text)
        val out = mutableListOf<MdSegment>()
        var prose: Document? = null
        fun closeProse() {
            prose?.let {
                // A table nested in a quote or list keeps its cells' links out
                // of dropBareDomainLinks' reach too: no Linkify there either.
                val nested = hasTable(it)
                out.add(MdSegment.Prose(prose(markwon(context, style, linkify = !nested), style, it), key(it)))
            }
            prose = null
        }
        for (node in generateSequence(doc.firstChild) { it.next }.toList()) {
            node.unlink()
            if (node is TableBlock) {
                closeProse()
                val width = naturalWidth(context, style, node)
                val table = Document().apply { appendChild(node) }
                val key = key(table)
                out.add(MdSegment.Table(trimmed(markwon(context, style, linkify = false).render(table)), width, key))
            } else {
                (prose ?: Document().also { prose = it }).appendChild(node)
            }
        }
        closeProse()
        return out
    }

    private fun prose(markwon: Markwon, style: MdStyle, doc: Document): Spanned {
        val parsed = trimmed(markwon.render(doc))
        dropBareDomainLinks(parsed)
        parsed.setSpan(LineSpacing(style.lineHeight), 0, parsed.length, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
        return parsed
    }

    // Without the block's trailing line breaks (the gap between segments is
    // the column's). Only "\n": a table row and a rule are drawn by spans
    // over a no-break space.
    private fun trimmed(text: Spanned): SpannableStringBuilder {
        val out = SpannableStringBuilder(text)
        while (out.isNotEmpty() && out[out.length - 1] == '\n') out.delete(out.length - 1, out.length)
        return out
    }

    // The width Markwon's table needs to show each column's cells unwrapped
    // (up to MAX_COLUMN code columns, past which they wrap): TableRowSpan
    // splits its width evenly, so every column as wide as the widest, with
    // its padding.
    private fun naturalWidth(context: Context, style: MdStyle, table: TableBlock): Int {
        val metrics = context.resources.displayMetrics
        val px = { sp: Float -> TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, sp, metrics) }
        val faces = faces(context, style)
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { typeface = faces.bold; textSize = px(style.textSize) }
        val code = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { typeface = faces.code; textSize = px(style.textSize * CODE_SCALE) }
        val cap = code.measureText("0") * MAX_COLUMN
        val widths = HashMap<Int, Float>()
        table.accept(object : AbstractVisitor() {
            override fun visit(node: CustomNode) {
                if (node is TableRow) {
                    var column = 0
                    for (cell in generateSequence(node.firstChild) { it.next }) {
                        val width = minOf(cap, paint.measureText(plain(cell)))
                        widths[column] = maxOf(widths[column] ?: 0f, width)
                        column++
                    }
                } else {
                    visitChildren(node)
                }
            }

            override fun visit(node: CustomBlock) = visitChildren(node)
        })
        // TableRowSpan gives every column width / n: each needs the widest's.
        val padding = px(style.textSize / 2) * 2 + px(1f)
        val widest = widths.values.maxOrNull() ?: return 0
        return ((widest + padding) * widths.size).toInt() + px(1f).toInt() + 1
    }

    private fun hasTable(node: Node): Boolean =
        node is TableBlock || generateSequence(node.firstChild) { it.next }.any(::hasTable)

    // A segment's key: everything its nodes render from (kind, text,
    // attributes). The rendered string alone misses a table cell growing in
    // place (a row is one no-break space drawn by its span) and span-only
    // changes.
    private fun key(node: Node): String {
        val out = StringBuilder()
        fun walk(n: Node) {
            out.append('<').append(n.javaClass.simpleName)
            val attributes: List<Any?> = when (n) {
                is Text -> listOf(n.literal)
                is Code -> listOf(n.literal)
                is org.commonmark.node.FencedCodeBlock -> listOf(n.info, n.literal)
                is org.commonmark.node.IndentedCodeBlock -> listOf(n.literal)
                is org.commonmark.node.HtmlInline -> listOf(n.literal)
                is org.commonmark.node.HtmlBlock -> listOf(n.literal)
                is org.commonmark.node.Link -> listOf(n.destination, n.title)
                is org.commonmark.node.Image -> listOf(n.destination, n.title)
                is Heading -> listOf(n.level)
                is org.commonmark.node.OrderedList -> listOf(n.startNumber, n.delimiter, n.isTight)
                is org.commonmark.node.BulletList -> listOf(n.bulletMarker, n.isTight)
                is org.commonmark.ext.gfm.tables.TableCell -> listOf(n.isHeader, n.alignment)
                else -> emptyList()
            }
            for (a in attributes) out.append('\u0000').append(a)
            generateSequence(n.firstChild) { it.next }.forEach(::walk)
            out.append('>')
        }
        walk(node)
        return out.toString()
    }

    private fun plain(node: Node): String {
        val text = StringBuilder()
        node.accept(object : AbstractVisitor() {
            override fun visit(node: Text) { text.append(node.literal) }
            override fun visit(node: Code) { text.append(node.literal) }
        })
        return text.toString()
    }

    // Linkify's WEB_URLS also links a bare name with a dot in a known TLD
    // ("Task.Supervised.run", "Bezalel.Dyn.G3.NetProbe.run/2" in a stack
    // trace) by putting "http://" in front. Keep links written as links, URLs
    // with a scheme and www. names (GitHub's autolinks, what iOS links).
    private fun dropBareDomainLinks(text: SpannableStringBuilder) {
        for (span in text.getSpans(0, text.length, URLSpan::class.java)) {
            val shown = text.subSequence(text.getSpanStart(span), text.getSpanEnd(span)).toString()
            if (span.url == "http://$shown" && !shown.startsWith("www.", ignoreCase = true)) {
                text.removeSpan(span)
            }
        }
    }

    private const val CODE_SCALE = 0.9f
    private const val MAX_STYLES = 8
    /** The widest a table column grows, in code columns (iOS draws the same). */
    private const val MAX_COLUMN = 32
    private val HEADING_SIZES = floatArrayOf(1.45f, 1.3f, 1.18f, 1.08f, 1f, 1f)
}

// The line height, on lines of text only. TextView's own multiplier would
// also stretch each table row (one line, drawn by Markwon's TableRowSpan, as
// tall as its wrapped cells) and the blank line between blocks.
//
// StaticLayout carries the metrics a line ends with into the next line of
// the same style run, so `fm` may arrive as this span left it: then the
// line's own metrics are the ones it had before, or the spacing would
// compound line after line. Half the extra goes above the text, half below,
// so an inline code background stays centred on its text.
private class LineSpacing(private val multiplier: Float) : LineHeightSpan {
    private var inAscent = 0
    private var inDescent = 0
    private var outAscent = 0
    private var outDescent = 0

    override fun chooseHeight(
        text: CharSequence, start: Int, end: Int, spanstartv: Int, lineHeight: Int, fm: Paint.FontMetricsInt,
    ) {
        if (multiplier <= 1f || (start until end).all { text[it].isWhitespace() }) return
        if (text is Spanned && text.getSpans(start, end, TableRowSpan::class.java).isNotEmpty()) return
        val carried = fm.ascent == outAscent && fm.descent == outDescent
        val ascent = if (carried) inAscent else fm.ascent
        val descent = if (carried) inDescent else fm.descent
        val extra = ((descent - ascent) * (multiplier - 1f)).roundToInt()
        fm.ascent = ascent - extra / 2
        fm.descent = descent + (extra - extra / 2)
        fm.top = minOf(fm.top, fm.ascent)
        fm.bottom = maxOf(fm.bottom, fm.descent)
        inAscent = ascent
        inDescent = descent
        outAscent = fm.ascent
        outDescent = fm.descent
    }
}

internal data class MdStyle(
    val textSize: Float,
    val lineHeight: Float,
    val textColor: Int,
    val headingColor: Int,
    val linkColor: Int,
    val codeColor: Int,
    val codeBackground: Int,
    val quoteColor: Int,
    val ruleColor: Int,
    val selectionColor: Int,
    val fontRegular: String,
    val fontBold: String,
    val fontItalic: String,
    val fontBoldItalic: String,
    val fontHeading: String,
    val fontCode: String,
) {
    companion object {
        fun from(props: Map<String, Any?>): MdStyle {
            fun color(key: String, default: Long) = ((props[key] as? Number)?.toLong() ?: default).toInt()
            fun float(key: String, default: Float) = (props[key] as? Number)?.toFloat() ?: default
            fun font(key: String) = props[key] as? String ?: ""
            return MdStyle(
                textSize = float("text_size", 15f),
                lineHeight = float("line_height", 1.4f),
                textColor = color("text_color", 0xFF1E1E1E),
                headingColor = color("heading_color", 0xFF1E1E1E),
                linkColor = color("link_color", 0xFF1A5FB4),
                codeColor = color("code_color", 0xFF1E1E1E),
                codeBackground = color("code_background", 0x14000000),
                quoteColor = color("quote_color", 0xFF6B6B6B),
                ruleColor = color("rule_color", 0xFFCCCCCC),
                selectionColor = color("selection_color", 0xFF1A5FB4),
                fontRegular = font("font_regular"),
                fontBold = font("font_bold"),
                fontItalic = font("font_italic"),
                fontBoldItalic = font("font_bold_italic"),
                fontHeading = font("font_heading"),
                fontCode = font("font_code"),
            )
        }
    }
}

internal class MdFaces(
    val regular: Typeface,
    val bold: Typeface,
    val italic: Typeface,
    val boldItalic: Typeface,
    val heading: Typeface,
    val code: Typeface,
) {
    /** `current` plus bold (`addBold`) or plus italic, as one face. */
    fun plus(current: Typeface?, addBold: Boolean): Typeface {
        val b = addBold || current === bold || current === boldItalic
        val i = !addBold || current === italic || current === boldItalic
        return when {
            b && i -> boldItalic
            b -> bold
            i -> italic
            else -> regular
        }
    }
}

// Strong / emphasis as a face. Nested styles compose whatever order the spans
// apply in: each adds its trait to the face already on the paint.
private class FaceSpan(private val faces: MdFaces, private val bold: Boolean) : MetricAffectingSpan() {
    override fun updateDrawState(tp: TextPaint) = restyle(tp)
    override fun updateMeasureState(tp: TextPaint) = restyle(tp)

    private fun restyle(tp: TextPaint) {
        tp.typeface = faces.plus(tp.typeface, bold)
    }
}

private class HeadingSpan(private val face: Typeface) : MetricAffectingSpan() {
    override fun updateDrawState(tp: TextPaint) {
        tp.typeface = face
    }

    override fun updateMeasureState(tp: TextPaint) {
        tp.typeface = face
    }
}

internal sealed class MdSegment {
    class Prose(val text: Spanned, val key: String) : MdSegment()
    class Table(val text: Spanned, val width: Int, val key: String) : MdSegment()
}

// A text view's state: what it last showed, and the `send` of its latest
// composition (MobNativeViewRegistry makes a new one per render).
private class MdHolder {
    var shown: String? = null
    var style: MdStyle? = null
    var send: MobMarkdownSend? = null
}

// Selection stays the TextView's own (long-press, handles, Copy); a short tap
// on a link (with no selection showing) follows it. LinkMovementMethod would
// also follow a link after a long-press and drop the selection on any tap. A
// table's cells are laid out by TableRowSpan outside the TextView's own
// text, so a tap there goes to Markwon's table hit test.
private object SelectableLinkMovement : ArrowKeyMovementMethod() {
    override fun onTouchEvent(widget: TextView, buffer: Spannable, event: MotionEvent): Boolean {
        if (event.action == MotionEvent.ACTION_UP &&
            event.eventTime - event.downTime < ViewConfiguration.getLongPressTimeout() &&
            !widget.hasSelection()
        ) {
            val layout = widget.layout
            if (layout != null) {
                val x = event.x.toInt() - widget.totalPaddingLeft + widget.scrollX
                val y = event.y.toInt() - widget.totalPaddingTop + widget.scrollY
                val line = layout.getLineForVertical(y)
                if (x >= layout.getLineLeft(line) && x <= layout.getLineRight(line)) {
                    val offset = layout.getOffsetForHorizontal(line, x.toFloat())
                    val links = buffer.getSpans(offset, offset, ClickableSpan::class.java)
                    if (links.isNotEmpty()) {
                        links[0].onClick(widget)
                        return true
                    }
                }
            }
            if (TableAwareMovementMethod.handleTableRowTouchEvent(widget, buffer, event)) return true
        }
        return super.onTouchEvent(widget, buffer, event)
    }
}

/**
 * The factory mob_dev's MobPluginBootstrap registers under "MobMarkdown_View":
 * the prose wraps to the view's width; each table sits at its natural width
 * (at least the view's) in a horizontal scroller of its own.
 */
@Composable
fun MobMarkdownView(props: Map<String, Any?>, send: MobMarkdownSend) {
    val style = MdStyle.from(props)
    val text = props["text"] as? String ?: ""
    val context = LocalContext.current
    val segments = remember(text, style) { MobMarkdown.segments(context, style, text) }
    val density = LocalDensity.current
    val gap = with(density) { (style.textSize * 0.8f).sp.toDp() }

    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val viewWidth = constraints.maxWidth
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(gap)) {
            for (segment in segments) {
                when (segment) {
                    is MdSegment.Prose -> MdText(segment.text, segment.key, style, send, Modifier.fillMaxWidth())
                    is MdSegment.Table -> {
                        val width = with(density) { maxOf(viewWidth, segment.width).toDp() }
                        Box(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())) {
                            MdText(segment.text, segment.key, style, send, Modifier.width(width))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MdText(text: Spanned, key: String, style: MdStyle, send: MobMarkdownSend, modifier: Modifier) {
    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            TextView(ctx).apply {
                tag = MdHolder()
                background = null
                setPadding(0, 0, 0, 0)
                setTextIsSelectable(true)
                movementMethod = SelectableLinkMovement
            }
        },
        update = { tv ->
            val holder = tv.tag as MdHolder
            holder.send = send
            if (holder.style != style) {
                tv.typeface = MobMarkdown.faces(tv.context, style).regular
                tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, style.textSize)
                tv.setLineSpacing(0f, 1f)
                tv.setTextColor(style.textColor)
                tv.setLinkTextColor(style.linkColor)
                tv.highlightColor = (style.selectionColor and 0x00FFFFFF) or 0x66000000
                holder.style = style
                holder.shown = null
            }
            if (holder.shown != key) {
                // Linkify adds nothing at set time: either instance applies the plugins.
                MobMarkdown.markwon(tv.context, style).setParsedMarkdown(tv, text)
                holder.shown = key
            }
        },
    )
}
