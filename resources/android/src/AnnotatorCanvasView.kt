package com.pteal79.plugins.imageannotator

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PointF
import android.graphics.RectF
import android.view.MotionEvent
import android.view.View
import kotlin.math.hypot
import kotlin.math.min

/**
 * Shows the image with its annotations and turns touches into editor calls.
 * All drawing happens in image pixels through one transform.
 *
 * One finger draws, selects or edits. Two fingers pinch-zoom and pan; the
 * second finger drops any gesture in progress and never starts a shape. In
 * Select mode, one finger on empty space pans while zoomed in.
 */
@SuppressLint("ViewConstructor")
class AnnotatorCanvasView(
    context: Context,
    private val editor: AnnotatorEditor,
    private val renderer: AnnotatorRenderer,
) : View(context) {

    interface Host {
        /** True while the inline text editor is open. */
        fun isEditingText(): Boolean

        /** A touch landed outside the text editor: commit it. */
        fun commitTextEditing()

        fun beginTextEditing(session: TextEditSession)

        fun onEditorChanged()
    }

    private enum class Mode { NONE, DRAW, PAN, ZOOM, SWALLOW }

    var host: Host? = null

    var image: Bitmap? = null
        set(value) {
            field = value
            zoom = 1f
            imageRect.setEmpty()
            updateLayout()
            invalidate()
        }

    /** Where the image sits in this view, in view pixels. */
    val imageRect = RectF()

    /** 1 when the image is fitted, up to MAX_ZOOM. */
    var zoom = 1f
        private set

    val canZoomIn: Boolean get() = image != null && zoom < MAX_ZOOM - 0.001f
    val canZoomOut: Boolean get() = image != null && zoom > 1.001f

    /** View pixels per image pixel with the image fitted. */
    private var fitViewPerImage = 1f

    /** View pixels per image pixel at the current zoom. */
    private val viewPerImage: Float get() = fitViewPerImage * zoom

    private val density = resources.displayMetrics.density
    private val imagePaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
    private val placeholderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#9ca3af")
        textSize = 15f * density
        textAlign = Paint.Align.CENTER
    }

    private var mode = Mode.NONE
    private var lastX = 0f
    private var lastY = 0f
    private var lastSpan = 0f

    init {
        setBackgroundColor(Color.parseColor("#0f0f0f"))
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        // Keep the image point at the centre of the old size in the centre.
        val centre = if (!imageRect.isEmpty && oldw > 0 && oldh > 0) toImage(oldw / 2f, oldh / 2f) else null
        updateLayout(centre)
    }

    /** Fits the image, applies zoom and pan, and recomputes the editor's scales. Shapes never change. */
    private fun updateLayout(keepCentred: Pt? = null) {
        val bitmap = image ?: return
        if (width == 0 || height == 0) return

        fitViewPerImage = min(width.toFloat() / bitmap.width, height.toFloat() / bitmap.height)
        val w = bitmap.width * viewPerImage
        val h = bitmap.height * viewPerImage

        when {
            keepCentred != null -> imageRect.set(
                width / 2f - keepCentred.x * viewPerImage,
                height / 2f - keepCentred.y * viewPerImage,
                0f,
                0f,
            )
            imageRect.isEmpty -> imageRect.set((width - w) / 2f, (height - h) / 2f, 0f, 0f)
        }
        imageRect.right = imageRect.left + w
        imageRect.bottom = imageRect.top + h
        clampPan()

        // Image pixels per screen point (dp), fitted and at the current zoom.
        editor.scale = bitmap.width / (bitmap.width * fitViewPerImage / density)
        editor.touchScale = editor.scale / zoom
        host?.onEditorChanged()
    }

    /** Centres the image on an axis where it is smaller than the view, otherwise keeps the view covered. */
    private fun clampPan() {
        val w = imageRect.width()
        val h = imageRect.height()
        val left = if (w <= width) (width - w) / 2f else imageRect.left.coerceIn(width - w, 0f)
        val top = if (h <= height) (height - h) / 2f else imageRect.top.coerceIn(height - h, 0f)
        imageRect.set(left, top, left + w, top + h)
    }

    /** Zooms by factor, keeping the image point under (focusX, focusY) still. */
    fun zoomBy(factor: Float, focusX: Float = width / 2f, focusY: Float = height / 2f) {
        val bitmap = image ?: return
        val next = (zoom * factor).coerceIn(1f, MAX_ZOOM)
        if (next == zoom) return

        val anchor = toImage(focusX, focusY)
        zoom = next
        val left = focusX - anchor.x * viewPerImage
        val top = focusY - anchor.y * viewPerImage
        imageRect.set(left, top, left + bitmap.width * viewPerImage, top + bitmap.height * viewPerImage)
        clampPan()
        editor.touchScale = editor.scale / zoom
        changed()
    }

    fun resetZoom() {
        if (image == null || zoom == 1f) return
        zoom = 1f
        imageRect.setEmpty()
        updateLayout()
        invalidate()
    }

    private fun panBy(dx: Float, dy: Float) {
        imageRect.offset(dx, dy)
        clampPan()
        changed()
    }

    fun toImage(x: Float, y: Float) = Pt((x - imageRect.left) / viewPerImage, (y - imageRect.top) / viewPerImage)

    fun toView(p: Pt) = PointF(imageRect.left + p.x * viewPerImage, imageRect.top + p.y * viewPerImage)

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)

        val bitmap = image
        if (bitmap == null) {
            canvas.drawText("Loading image…", width / 2f, height / 2f, placeholderPaint)
            return
        }

        canvas.save()
        canvas.translate(imageRect.left, imageRect.top)
        canvas.scale(viewPerImage, viewPerImage)

        canvas.drawBitmap(bitmap, 0f, 0f, imagePaint)

        val shapes = editor.shapes
        val preview = editor.preview
        val hidden = editor.hiddenIndex
        shapes.forEachIndexed { i, shape ->
            if (i == hidden) return@forEachIndexed
            renderer.draw(canvas, if (preview?.first == i) preview.second else shape)
        }

        editor.draft?.let { renderer.draw(canvas, it) }

        editor.selectedIndex?.let { i ->
            if (i != hidden) {
                val shape = if (preview?.first == i) preview.second else shapes.getOrNull(i)
                shape?.let { renderer.drawOverlay(canvas, it, editor.touchScale) }
            }
        }

        canvas.restore()
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (image == null || !isEnabled) return false

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                lastX = event.x
                lastY = event.y
                if (host?.isEditingText() == true) {
                    host?.commitTextEditing()
                    mode = Mode.SWALLOW
                    return true
                }
                editor.touchDown(toImage(event.x, event.y))
                mode = if (editor.touchIsIdle && zoom > 1f) Mode.PAN else Mode.DRAW
                changed()
            }

            MotionEvent.ACTION_POINTER_DOWN -> {
                // A second finger never draws: drop whatever the first one started.
                if (mode == Mode.DRAW) editor.abortTouch()
                mode = Mode.ZOOM
                startPinch(event)
                changed()
            }

            MotionEvent.ACTION_MOVE -> when (mode) {
                Mode.DRAW -> {
                    for (h in 0 until event.historySize) {
                        editor.touchMove(toImage(event.getHistoricalX(0, h), event.getHistoricalY(0, h)))
                    }
                    editor.touchMove(toImage(event.x, event.y))
                    changed()
                }
                Mode.PAN -> {
                    panBy(event.x - lastX, event.y - lastY)
                    lastX = event.x
                    lastY = event.y
                }
                Mode.ZOOM -> if (event.pointerCount >= 2) {
                    val span = span(event)
                    val fx = (event.getX(0) + event.getX(1)) / 2f
                    val fy = (event.getY(0) + event.getY(1)) / 2f
                    panBy(fx - lastX, fy - lastY)
                    if (lastSpan > 0f && span > 0f) zoomBy(span / lastSpan, fx, fy)
                    lastSpan = span
                    lastX = fx
                    lastY = fy
                }
                else -> {}
            }

            MotionEvent.ACTION_POINTER_UP -> {
                if (mode == Mode.ZOOM && event.pointerCount > 2) {
                    // Carry on pinching with the fingers that are left.
                    startPinch(event, skip = event.actionIndex)
                } else {
                    mode = Mode.SWALLOW
                }
            }

            MotionEvent.ACTION_UP -> {
                if (mode == Mode.DRAW || mode == Mode.PAN) {
                    val session = editor.touchUp(toImage(event.x, event.y))
                    changed()
                    session?.let { host?.beginTextEditing(it) }
                }
                mode = Mode.NONE
            }

            MotionEvent.ACTION_CANCEL -> {
                if (mode == Mode.DRAW) editor.touchCancel() else if (mode == Mode.PAN) editor.abortTouch()
                mode = Mode.NONE
                changed()
            }
        }
        return true
    }

    private fun startPinch(event: MotionEvent, skip: Int = -1) {
        val indices = (0 until event.pointerCount).filter { it != skip }.take(2)
        if (indices.size < 2) return
        val (a, b) = indices
        lastSpan = hypot(event.getX(a) - event.getX(b), event.getY(a) - event.getY(b))
        lastX = (event.getX(a) + event.getX(b)) / 2f
        lastY = (event.getY(a) + event.getY(b)) / 2f
    }

    private fun span(event: MotionEvent) = hypot(event.getX(0) - event.getX(1), event.getY(0) - event.getY(1))

    private fun changed() {
        invalidate()
        host?.onEditorChanged()
    }

    companion object {
        const val MAX_ZOOM = 8f
        const val ZOOM_STEP = 1.5f
    }
}
