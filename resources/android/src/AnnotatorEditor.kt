package com.pteal79.plugins.imageannotator

// Editor state and interaction logic. Plain Kotlin with no Android UI types,
// kept in step with AnnotatorEditor.swift. The view turns touches into image
// pixel points, calls touchDown/touchMove/touchUp, and redraws.

/**
 * An open inline text editor. Its format fields change while the user edits;
 * commitText() turns it into a shape.
 */
class TextEditSession(
    /** Top-left of the first line, in image pixels. */
    val anchor: Pt,
    val initialText: String,
    /** Index of the text shape being re-edited, or null for new text. */
    val editingIndex: Int?,
    /** The re-edited shape's stored font size, kept when its size preset is unchanged. */
    private val originalFontSize: Float?,
    private val originalSize: SizePreset?,
    var color: String,
    var fontFamily: FontKey,
    var bold: Boolean,
    var italic: Boolean,
    var underline: Boolean,
    var size: SizePreset,
) {
    fun fontSize(scale: Float): Float {
        if (originalFontSize != null && size == originalSize) return originalFontSize
        return size.font * scale
    }
}

class AnnotatorEditor(private val measurer: TextMeasurer) {
    private enum class DragKind { MOVE, RESIZE }

    private class Drag(
        val kind: DragKind,
        val index: Int,
        val start: Pt,
        val original: Shape,
        val handle: Handle? = null,
        val anchor: Pt? = null,
    ) {
        var moved = false
        var current: Shape = original
    }

    private val history = History()

    val shapes: List<Shape> get() = history.shapes

    /**
     * Image pixels per screen point with the image fitted (zoom 1). Set by the
     * view on every layout. Stroke widths and font sizes use this, so zooming
     * never changes the size a new shape gets.
     */
    var scale: Float = 1f

    /**
     * Image pixels per screen point at the current zoom (scale / zoom). Touch
     * tolerances and the selection overlay use this so they stay the same
     * size on screen at any zoom.
     */
    var touchScale: Float = 1f

    var tool: Tool = Tool.SELECT
        private set
    var color: String = Palette.DEFAULT_STROKE
        private set
    var size: SizePreset = SizePreset.M
        private set
    var fill: Boolean = false
        private set
    var fillColor: String = Palette.DEFAULT_FILL
        private set

    /** Format used for the next new text. Updated from each committed text. */
    private var fontFamily: FontKey = FontKey.SANS
    private var bold = false
    private var italic = false
    private var underline = false

    var selectedIndex: Int? = null
        private set
    var reverted: Boolean = false
        private set

    /** The shape being drawn with a drawing tool. */
    var draft: Shape? = null
        private set

    var textSession: TextEditSession? = null
        private set

    private var drag: Drag? = null
    private var pendingTextTap: Pt? = null

    /** Points of the freehand draft, appended in place while drawing. */
    private val draftPoints = ArrayList<Pt>()

    val canUndo: Boolean get() = history.canUndo
    val canRedo: Boolean get() = history.canRedo
    val hasUnsavedChanges: Boolean get() = history.canUndo || reverted

    val selectedShape: Shape? get() = selectedIndex?.let { shapes.getOrNull(it) }

    /** Index of a text shape hidden while it is re-edited. */
    val hiddenIndex: Int? get() = textSession?.editingIndex

    /** The dragged copy of a shape, drawn in place of shapes[index]. */
    val preview: Pair<Int, Shape>?
        get() = drag?.takeIf { it.moved }?.let { it.index to it.current }

    val canBringForward: Boolean get() = selectedIndex?.let { it < shapes.lastIndex } ?: false
    val canSendBackward: Boolean get() = selectedIndex?.let { it > 0 } ?: false

    val showsFillControls: Boolean get() = tool == Tool.RECT || selectedShape is RectShape

    /** True after touchDown when the touch grabbed nothing, so the view may pan instead. */
    val touchIsIdle: Boolean get() = tool == Tool.SELECT && drag == null

    // Tools and styles

    fun setTool(next: Tool) {
        tool = next
        drag = null
        draft = null
        pendingTextTap = null
        if (next != Tool.SELECT) deselect()
    }

    fun setColor(next: String) {
        color = next
        textSession?.let {
            it.color = next
            return
        }
        restyleSelected { it.withColor(next) }
    }

    fun setSize(next: SizePreset) {
        size = next
        textSession?.let {
            it.size = next
            return
        }
        restyleSelected { shape ->
            when (shape) {
                is FreehandShape -> shape.copy(strokeWidth = next.stroke * scale)
                is LineShape -> shape.copy(strokeWidth = next.stroke * scale)
                is RectShape -> shape.copy(strokeWidth = next.stroke * scale)
                is TextShape -> shape.copy(fontSize = next.font * scale)
            }
        }
    }

    fun setFill(next: Boolean) {
        fill = next
        restyleSelected { (it as? RectShape)?.copy(fill = next) ?: it }
    }

    fun setFillColor(next: String) {
        fillColor = next
        restyleSelected { (it as? RectShape)?.copy(fillColor = next) ?: it }
    }

    private fun restyleSelected(transform: (Shape) -> Shape) {
        if (tool != Tool.SELECT) return
        val index = selectedIndex ?: return
        val shape = shapes.getOrNull(index) ?: return
        val updated = transform(shape)
        if (updated != shape) replace(index, updated)
    }

    // Selection

    fun select(index: Int) {
        selectedIndex = index
        val shape = shapes.getOrNull(index) ?: return
        color = shape.color
        when (shape) {
            is FreehandShape -> size = SizePreset.fromStroke(shape.strokeWidth / scale)
            is LineShape -> size = SizePreset.fromStroke(shape.strokeWidth / scale)
            is RectShape -> {
                size = SizePreset.fromStroke(shape.strokeWidth / scale)
                fill = shape.fill
                fillColor = shape.fillColor
            }
            is TextShape -> size = SizePreset.fromFont(shape.fontSize / scale)
        }
    }

    fun deselect() {
        selectedIndex = null
    }

    // Touches, in image pixels

    fun touchDown(p: Pt) {
        drag = null
        draft = null
        pendingTextTap = null

        when (tool) {
            Tool.FREEHAND -> {
                draftPoints.clear()
                draftPoints.add(p)
                draft = FreehandShape(draftPoints, color, size.stroke * scale)
            }
            Tool.LINE -> draft = LineShape(p.x, p.y, p.x, p.y, color, size.stroke * scale)
            Tool.RECT -> draft = RectShape(p.x, p.y, 0f, 0f, color, size.stroke * scale, fill, fillColor)
            Tool.TEXT -> pendingTextTap = p
            Tool.SELECT -> beginSelectTouch(p)
        }
    }

    private fun beginSelectTouch(p: Pt) {
        Geometry.hitText(shapes, p, touchScale, measurer)?.let { index ->
            select(index)
            drag = Drag(DragKind.MOVE, index, p, shapes[index])
            return
        }

        val selected = selectedIndex?.let { index -> shapes.getOrNull(index)?.let { index to it } }
        if (selected != null) {
            val (index, shape) = selected
            val handle = Geometry.hitHandle(shape, p, touchScale)
            if (handle != null) {
                val anchor = (shape as? RectShape)?.let { Geometry.anchor(handle, it.bounds()) }
                drag = Drag(DragKind.RESIZE, index, p, shape, handle, anchor)
                return
            }
        }

        Geometry.hitBody(shapes, p, touchScale)?.let { index ->
            select(index)
            drag = Drag(DragKind.MOVE, index, p, shapes[index])
            return
        }

        deselect()
    }

    fun touchMove(p: Pt) {
        when (val current = draft) {
            is FreehandShape -> if (draftPoints.last() != p) draftPoints.add(p)
            is LineShape -> draft = current.copy(x2 = p.x, y2 = p.y)
            is RectShape -> draft = current.copy(w = p.x - current.x, h = p.y - current.y)
            else -> {}
        }

        val d = drag ?: return
        if (!d.moved && Geometry.distance(d.start, p) <= Metrics.MOVE_THRESHOLD * touchScale) return
        d.moved = true

        d.current = when (d.kind) {
            DragKind.MOVE -> d.original.moved(p.x - d.start.x, p.y - d.start.y)
            DragKind.RESIZE -> when (val shape = d.original) {
                is LineShape -> Geometry.resizeLine(shape, d.handle!!, p)
                is RectShape -> Geometry.resizeRect(shape, d.handle!!, d.anchor!!, p)
                else -> shape
            }
        }
    }

    /** Returns a text session when the touch opened the text editor. */
    fun touchUp(p: Pt): TextEditSession? {
        touchMove(p)

        commitDraft()

        pendingTextTap?.let { tap ->
            pendingTextTap = null
            return beginNewText(tap)
        }

        val d = drag ?: return null
        drag = null

        if (d.moved) {
            replace(d.index, d.current)
            selectedIndex = d.index
            return null
        }

        val text = d.original as? TextShape ?: return null
        return beginEditText(d.index, text)
    }

    /** A second finger came down: drop the gesture without adding or changing anything. */
    fun abortTouch() {
        draft = null
        drag = null
        pendingTextTap = null
    }

    fun touchCancel() {
        commitDraft()
        pendingTextTap = null
        drag = null
    }

    private fun commitDraft() {
        var shape = draft ?: return
        draft = null
        if (shape is FreehandShape) shape = shape.copy(points = draftPoints.toList())
        if (isVisible(shape)) add(shape)
    }

    /** Zero-size shapes (a tap with a drawing tool) are not added. */
    private fun isVisible(shape: Shape): Boolean = when (shape) {
        is FreehandShape -> shape.points.size >= 2
        is LineShape -> shape.x1 != shape.x2 || shape.y1 != shape.y2
        is RectShape -> shape.w != 0f && shape.h != 0f
        is TextShape -> shape.text.isNotEmpty()
    }

    // Text

    private fun beginNewText(anchor: Pt): TextEditSession {
        val session = TextEditSession(
            anchor = anchor,
            initialText = "",
            editingIndex = null,
            originalFontSize = null,
            originalSize = null,
            color = color,
            fontFamily = fontFamily,
            bold = bold,
            italic = italic,
            underline = underline,
            size = size,
        )
        textSession = session
        return session
    }

    private fun beginEditText(index: Int, shape: TextShape): TextEditSession {
        val preset = SizePreset.fromFont(shape.fontSize / scale)
        val session = TextEditSession(
            anchor = Pt(shape.x, shape.y),
            initialText = shape.text,
            editingIndex = index,
            originalFontSize = shape.fontSize,
            originalSize = preset,
            color = shape.color,
            fontFamily = shape.fontFamily,
            bold = shape.bold,
            italic = shape.italic,
            underline = shape.underline,
            size = preset,
        )
        textSession = session
        return session
    }

    /** Commits the open text editor. Empty text adds nothing and leaves a re-edited shape unchanged. */
    fun commitText(raw: String) {
        val session = textSession ?: return
        textSession = null

        fontFamily = session.fontFamily
        bold = session.bold
        italic = session.italic
        underline = session.underline

        val text = raw.trim()
        if (text.isEmpty()) return

        val shape = TextShape(
            x = session.anchor.x,
            y = session.anchor.y,
            text = text,
            color = session.color,
            fontSize = session.fontSize(scale),
            fontFamily = session.fontFamily,
            bold = session.bold,
            italic = session.italic,
            underline = session.underline,
        )

        val index = session.editingIndex
        if (index == null) {
            add(shape)
        } else if (index in shapes.indices) {
            if (shapes[index] != shape) replace(index, shape)
            selectedIndex = index
        }
    }

    fun cancelText() {
        textSession = null
    }

    // Document actions

    fun deleteSelected() {
        val index = selectedIndex ?: return
        if (index !in shapes.indices) return
        history.apply(shapes.toMutableList().apply { removeAt(index) })
        deselect()
    }

    fun moveLayer(move: LayerMove) {
        val index = selectedIndex ?: return
        if (index !in shapes.indices) return
        val target = when (move) {
            LayerMove.FRONT -> shapes.lastIndex
            LayerMove.FORWARD -> minOf(index + 1, shapes.lastIndex)
            LayerMove.BACKWARD -> maxOf(index - 1, 0)
            LayerMove.BACK -> 0
        }
        if (target == index) return

        val list = shapes.toMutableList()
        val shape = list.removeAt(index)
        list.add(target, shape)
        history.apply(list)
        selectedIndex = target
    }

    /** Returns false when there was nothing to clear. */
    fun clearAll(): Boolean {
        if (shapes.isEmpty()) return false
        history.apply(emptyList())
        deselect()
        return true
    }

    fun undo() {
        drag = null
        draft = null
        if (history.undo()) dropStaleSelection()
    }

    fun redo() {
        drag = null
        draft = null
        if (history.redo()) dropStaleSelection()
    }

    private fun dropStaleSelection() {
        if (selectedIndex?.let { it !in shapes.indices } == true) deselect()
    }

    /** Clears everything for the original image. Cannot be undone. */
    fun revert() {
        history.reset()
        drag = null
        draft = null
        textSession = null
        pendingTextTap = null
        deselect()
        reverted = true
    }

    /** Ends any gesture, text edit and selection before exporting. */
    fun prepareForSave() {
        touchCancel()
        deselect()
    }

    private fun add(shape: Shape) {
        history.apply(shapes + shape)
    }

    private fun replace(index: Int, shape: Shape) {
        history.apply(shapes.toMutableList().apply { set(index, shape) })
    }
}
