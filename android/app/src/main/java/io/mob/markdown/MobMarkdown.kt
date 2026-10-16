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
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.res.ResourcesCompat
import io.noties.markwon.AbstractMarkwonPlugin
import io.noties.markwon.Markwon
import io.noties.markwon.MarkwonConfiguration
import io.noties.markwon.MarkwonSpansFactory
import io.noties.markwon.core.CoreProps
import io.noties.markwon.core.MarkwonTheme
import io.noties.markwon.ext.strikethrough.StrikethroughPlugin
import io.noties.markwon.ext.tables.TablePlugin
import io.noties.markwon.ext.tables.TableRowSpan
import io.noties.markwon.html.HtmlPlugin
import io.noties.markwon.linkify.LinkifyPlugin
import org.commonmark.node.Emphasis
import org.commonmark.node.Heading
import org.commonmark.node.StrongEmphasis
import kotlin.math.roundToInt

// The Android side of MobMarkdown.View (see the MobMarkdown moduledoc for the
// props). Markwon renders the Markdown to Spannables in a selectable
// TextView, so inline styles wrap like prose and any text can be
// drag-selected and copied. Tables come from Markwon's table plugin, which
// splits the view's width evenly between the columns and wraps each cell
// inside its column: a wide table gets tall, never wider than the view.
//
// mob_dev's generated MobPluginBootstrap registers MobMarkdownView under
// "MobMarkdown_View" (the manifest's ui_components factory).
//
// One Markwon instance per style serves every view; it is rebuilt only when
// the style props change. A view's TextView is created once and re-rendered
// only when its `text` or style changes (a streaming reply grows a few times
// a second; finished ones never change).

/** The send closure MobNativeViewRegistry hands a factory (its MobNativeSend). */
typealias MobMarkdownSend = (event: String, payload: Map<String, Any>) -> Unit

internal object MobMarkdown {
    private var faces: MdFaces? = null
    private var facesKey: List<String>? = null
    private var markwon: Markwon? = null
    private var markwonStyle: MdStyle? = null

    // Main thread only (Compose).
    fun markwon(context: Context, style: MdStyle): Markwon {
        markwon?.let { if (style == markwonStyle) return it }
        val built = build(context.applicationContext, style, faces(context, style))
        markwon = built
        markwonStyle = style
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

    private fun build(ctx: Context, style: MdStyle, faces: MdFaces): Markwon {
        val px = { sp: Float ->
            TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, sp, ctx.resources.displayMetrics)
        }
        // Monospace at the body size reads large next to a proportional face.
        val codePx = px(style.textSize * CODE_SCALE).toInt()
        val pad = px(style.textSize / 2).toInt()

        return Markwon.builder(ctx)
            .usePlugin(StrikethroughPlugin.create())
            .usePlugin(TablePlugin.create(TablePlugin.ThemeConfigure { b ->
                b.tableBorderColor(style.ruleColor)
                    .tableBorderWidth(px(1f).toInt().coerceAtLeast(1))
                    .tableCellPadding(pad)
                    .tableHeaderRowBackgroundColor(style.codeBackground)
                    .tableEvenRowBackgroundColor(0)
                    .tableOddRowBackgroundColor(0)
            }))
            .usePlugin(LinkifyPlugin.create(Linkify.WEB_URLS or Linkify.EMAIL_ADDRESSES))
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

    /** `text` parsed, with the line height on its lines of text (see LineSpacing). */
    fun render(context: Context, style: MdStyle, text: String): Spanned {
        val parsed = SpannableStringBuilder(markwon(context, style).toMarkdown(text))
        dropBareDomainLinks(parsed)
        parsed.setSpan(LineSpacing(style.lineHeight), 0, parsed.length, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
        return parsed
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

// A view's state: what it last rendered, and the `send` of its latest
// composition (MobNativeViewRegistry makes a new one per render).
private class MdHolder {
    var text: String? = null
    var style: MdStyle? = null
    var send: MobMarkdownSend? = null
}

// Selection stays the TextView's own (long-press, handles, Copy); a short tap
// on a link (with no selection showing) follows it. LinkMovementMethod would
// also follow a link after a long-press and drop the selection on any tap.
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
        }
        return super.onTouchEvent(widget, buffer, event)
    }
}

/** The factory mob_dev's MobPluginBootstrap registers under "MobMarkdown_View". */
@Composable
fun MobMarkdownView(props: Map<String, Any?>, send: MobMarkdownSend) {
    val style = MdStyle.from(props)
    val text = props["text"] as? String ?: ""

    AndroidView(
        modifier = Modifier.fillMaxWidth(),
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
                holder.text = null
            }
            if (holder.text != text) {
                MobMarkdown.markwon(tv.context, style)
                    .setParsedMarkdown(tv, MobMarkdown.render(tv.context, style, text))
                holder.text = text
            }
        },
    )
}
