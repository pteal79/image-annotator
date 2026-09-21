package com.pteal79.plugins.imageannotator

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import kotlin.math.max

/**
 * Draws shapes and the selection overlay onto a canvas that is already in
 * image pixel space. The same code draws the screen and the exported JPEG.
 * Not thread-safe: the export uses its own instance.
 */
class AnnotatorRenderer : TextMeasurer {
    private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply { style = Paint.Style.FILL }
    private val overlayPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val path = Path()
    private val rect = RectF()

    override fun width(line: String, shape: TextShape): Float {
        if (line.isEmpty()) return 0f
        configureText(shape)
        return textPaint.measureText(line)
    }

    fun draw(canvas: Canvas, shape: Shape) {
        when (shape) {
            is FreehandShape -> drawFreehand(canvas, shape)
            is LineShape -> {
                configureStroke(shape.color, shape.strokeWidth)
                canvas.drawLine(shape.x1, shape.y1, shape.x2, shape.y2, strokePaint)
            }
            is RectShape -> drawRect(canvas, shape)
            is TextShape -> drawText(canvas, shape)
        }
    }

    private fun drawFreehand(canvas: Canvas, shape: FreehandShape) {
        if (shape.points.size < 2) return
        path.reset()
        path.moveTo(shape.points[0].x, shape.points[0].y)
        for (i in 1 until shape.points.size) {
            path.lineTo(shape.points[i].x, shape.points[i].y)
        }
        configureStroke(shape.color, shape.strokeWidth)
        canvas.drawPath(path, strokePaint)
    }

    private fun drawRect(canvas: Canvas, shape: RectShape) {
        val b = shape.bounds()
        rect.set(b.minX, b.minY, b.maxX, b.maxY)
        if (shape.fill) {
            fillPaint.color = parseColor(shape.fillColor)
            canvas.drawRect(rect, fillPaint)
        }
        configureStroke(shape.color, shape.strokeWidth)
        canvas.drawRect(rect, strokePaint)
    }

    private fun drawText(canvas: Canvas, shape: TextShape) {
        configureText(shape)
        val ascent = -textPaint.fontMetrics.ascent
        val lineHeight = shape.fontSize * Metrics.LINE_HEIGHT
        val thickness = max(1f, shape.fontSize * Metrics.UNDERLINE_THICKNESS)

        shape.lines.forEachIndexed { i, line ->
            val top = shape.y + i * lineHeight
            if (line.isNotEmpty()) {
                canvas.drawText(line, shape.x, top + ascent, textPaint)
            }
            if (shape.underline && line.isNotEmpty()) {
                val y = top + shape.fontSize * Metrics.UNDERLINE_OFFSET
                canvas.drawRect(shape.x, y - thickness / 2f, shape.x + textPaint.measureText(line), y + thickness / 2f, textPaint)
            }
        }
    }

    /** Dashed outline plus handles. Never drawn into the export. */
    fun drawOverlay(canvas: Canvas, shape: Shape, scale: Float) {
        overlayPaint.color = parseColor(Metrics.OVERLAY_COLOR)
        overlayPaint.strokeWidth = Metrics.OVERLAY_LINE * scale
        overlayPaint.pathEffect = DashPathEffect(floatArrayOf(Metrics.OVERLAY_DASH * scale, Metrics.OVERLAY_GAP * scale), 0f)

        when (shape) {
            is LineShape -> canvas.drawLine(shape.x1, shape.y1, shape.x2, shape.y2, overlayPaint)
            is RectShape -> drawBounds(canvas, shape.bounds())
            is FreehandShape -> drawBounds(canvas, shape.bounds().expanded(Metrics.FREEHAND_PADDING * scale))
            is TextShape -> drawBounds(canvas, Geometry.textBounds(shape, this).expanded(Metrics.TEXT_PADDING * scale))
        }
        overlayPaint.pathEffect = null

        val half = Metrics.HANDLE_SIZE * scale / 2f
        fillPaint.color = Color.WHITE
        for ((_, c) in Geometry.handles(shape)) {
            rect.set(c.x - half, c.y - half, c.x + half, c.y + half)
            canvas.drawRect(rect, fillPaint)
            canvas.drawRect(rect, overlayPaint)
        }
    }

    private fun drawBounds(canvas: Canvas, b: Bounds) {
        rect.set(b.minX, b.minY, b.maxX, b.maxY)
        canvas.drawRect(rect, overlayPaint)
    }

    private fun configureStroke(color: String, width: Float) {
        strokePaint.color = parseColor(color)
        strokePaint.strokeWidth = width
    }

    private fun configureText(shape: TextShape) {
        textPaint.color = parseColor(shape.color)
        textPaint.textSize = shape.fontSize
        val face = Fonts.typeface(shape.fontFamily, shape.bold, shape.italic)
        textPaint.typeface = face
        // Fake the style when the family has no matching face.
        textPaint.isFakeBoldText = shape.bold && !face.isBold
        textPaint.textSkewX = if (shape.italic && !face.isItalic) -0.25f else 0f
    }

    companion object {
        fun parseColor(hex: String): Int = try {
            Color.parseColor(hex)
        } catch (e: IllegalArgumentException) {
            Color.RED
        }
    }
}

object Fonts {
    private val cache = HashMap<String, Typeface>()

    @Synchronized
    fun typeface(family: FontKey, bold: Boolean, italic: Boolean): Typeface {
        val key = "${family.key}:$bold:$italic"
        return cache.getOrPut(key) {
            val style = when {
                bold && italic -> Typeface.BOLD_ITALIC
                bold -> Typeface.BOLD
                italic -> Typeface.ITALIC
                else -> Typeface.NORMAL
            }
            when (family) {
                FontKey.SANS -> Typeface.create("sans-serif", style)
                FontKey.SERIF, FontKey.GEORGIA -> Typeface.create("serif", style)
                FontKey.MONO -> Typeface.create("monospace", style)
                // Impact is always heavy, so the condensed face is bold either way.
                FontKey.IMPACT -> Typeface.create("sans-serif-condensed", if (italic) Typeface.BOLD_ITALIC else Typeface.BOLD)
            }
        }
    }
}
