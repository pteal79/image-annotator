package com.pteal79.plugins.imageannotator

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

// Shape model, geometry, hit testing and history for the annotator.
// Plain Kotlin with no Android UI types, kept in step with AnnotatorModel.swift.
// Every coordinate and size here is in image pixels unless a name says "points".

/** A point in image pixels. */
data class Pt(val x: Float, val y: Float) {
    fun offset(dx: Float, dy: Float) = Pt(x + dx, y + dy)
}

/** A normalised box in image pixels. */
data class Bounds(val minX: Float, val minY: Float, val maxX: Float, val maxY: Float) {
    val midX: Float get() = (minX + maxX) / 2f
    val midY: Float get() = (minY + maxY) / 2f

    fun expanded(by: Float) = Bounds(minX - by, minY - by, maxX + by, maxY + by)

    fun contains(p: Pt) = p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
}

enum class Tool { SELECT, FREEHAND, LINE, RECT, TEXT }

/** Stroke widths and font sizes in screen points. Stored values are these times the scale. */
enum class SizePreset(val label: String, val stroke: Float, val font: Float) {
    S("S", 2f, 28f),
    M("M", 4f, 44f),
    L("L", 8f, 64f),
    XL("XL", 16f, 88f);

    companion object {
        fun fromStroke(points: Float): SizePreset = when {
            points <= 3f -> S
            points <= 6f -> M
            points <= 12f -> L
            else -> XL
        }

        fun fromFont(points: Float): SizePreset = when {
            points <= 36f -> S
            points <= 54f -> M
            points <= 76f -> L
            else -> XL
        }
    }
}

enum class FontKey(val key: String, val label: String) {
    SANS("sans", "Sans"),
    SERIF("serif", "Serif"),
    MONO("mono", "Mono"),
    GEORGIA("georgia", "Georgia"),
    IMPACT("impact", "Impact");

    companion object {
        fun from(key: String?): FontKey = values().firstOrNull { it.key == key } ?: SANS
    }
}

enum class Handle { P1, P2, NW, N, NE, E, SE, S, SW, W }

enum class LayerMove { FRONT, FORWARD, BACKWARD, BACK }

object Palette {
    const val DEFAULT_STROKE = "#ef4444"
    const val DEFAULT_FILL = "#ffffff"
    const val WHITE = "#ffffff"

    val colors = listOf("#ef4444", "#f97316", "#eab308", "#22c55e", "#3b82f6", "#000000", "#ffffff")
}

/** Sizes in screen points for the overlay and hit testing. Multiply by the scale before use. */
object Metrics {
    const val LINE_HEIGHT = 1.2f
    const val UNDERLINE_OFFSET = 1.05f
    const val UNDERLINE_THICKNESS = 0.06f

    const val OVERLAY_COLOR = "#38bdf8"
    const val OVERLAY_LINE = 1.5f
    const val OVERLAY_DASH = 5f
    const val OVERLAY_GAP = 3f
    const val FREEHAND_PADDING = 8f
    const val TEXT_PADDING = 4f
    const val HANDLE_SIZE = 10f

    const val HANDLE_HIT = 5f * 1.5f
    const val TEXT_HIT_PADDING = 8f
    const val BODY_TOLERANCE = 6f
    const val BODY_MIN_TOLERANCE = 8f
    const val MOVE_THRESHOLD = 3f
}

sealed class Shape {
    abstract val color: String

    abstract fun moved(dx: Float, dy: Float): Shape

    abstract fun withColor(color: String): Shape
}

data class FreehandShape(
    val points: List<Pt>,
    override val color: String,
    val strokeWidth: Float,
) : Shape() {
    override fun moved(dx: Float, dy: Float) = copy(points = points.map { it.offset(dx, dy) })

    override fun withColor(color: String) = copy(color = color)

    fun bounds(): Bounds {
        var minX = Float.MAX_VALUE
        var minY = Float.MAX_VALUE
        var maxX = -Float.MAX_VALUE
        var maxY = -Float.MAX_VALUE
        for (p in points) {
            minX = min(minX, p.x)
            minY = min(minY, p.y)
            maxX = max(maxX, p.x)
            maxY = max(maxY, p.y)
        }
        return if (points.isEmpty()) Bounds(0f, 0f, 0f, 0f) else Bounds(minX, minY, maxX, maxY)
    }
}

data class LineShape(
    val x1: Float,
    val y1: Float,
    val x2: Float,
    val y2: Float,
    override val color: String,
    val strokeWidth: Float,
) : Shape() {
    override fun moved(dx: Float, dy: Float) = copy(x1 = x1 + dx, y1 = y1 + dy, x2 = x2 + dx, y2 = y2 + dy)

    override fun withColor(color: String) = copy(color = color)
}

/** w and h may be negative while drawing. Use bounds() for anything spatial. */
data class RectShape(
    val x: Float,
    val y: Float,
    val w: Float,
    val h: Float,
    override val color: String,
    val strokeWidth: Float,
    val fill: Boolean,
    val fillColor: String,
) : Shape() {
    override fun moved(dx: Float, dy: Float) = copy(x = x + dx, y = y + dy)

    override fun withColor(color: String) = copy(color = color)

    fun bounds() = Bounds(min(x, x + w), min(y, y + h), max(x, x + w), max(y, y + h))
}

/** (x, y) is the top-left of the first line. */
data class TextShape(
    val x: Float,
    val y: Float,
    val text: String,
    override val color: String,
    val fontSize: Float,
    val fontFamily: FontKey,
    val bold: Boolean,
    val italic: Boolean,
    val underline: Boolean,
) : Shape() {
    val lines: List<String> get() = text.split("\n")

    override fun moved(dx: Float, dy: Float) = copy(x = x + dx, y = y + dy)

    override fun withColor(color: String) = copy(color = color)
}

/** Measures one line of text in image pixels, using the shape's font, size and style. */
fun interface TextMeasurer {
    fun width(line: String, shape: TextShape): Float
}

object Geometry {
    fun distance(a: Pt, b: Pt): Float = hypot(a.x - b.x, a.y - b.y)

    fun distanceToSegment(p: Pt, a: Pt, b: Pt): Float {
        val dx = b.x - a.x
        val dy = b.y - a.y
        val lengthSquared = dx * dx + dy * dy
        if (lengthSquared == 0f) return distance(p, a)

        val t = (((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared).coerceIn(0f, 1f)
        return distance(p, Pt(a.x + t * dx, a.y + t * dy))
    }

    fun textBounds(shape: TextShape, measurer: TextMeasurer): Bounds {
        val lines = shape.lines
        val widest = lines.maxOfOrNull { measurer.width(it, shape) } ?: 0f
        val width = max(widest, shape.fontSize)
        val height = lines.size * shape.fontSize * Metrics.LINE_HEIGHT
        return Bounds(shape.x, shape.y, shape.x + width, shape.y + height)
    }

    /** Resize handles for lines and rects. Freehand and text have none. */
    fun handles(shape: Shape): List<Pair<Handle, Pt>> = when (shape) {
        is LineShape -> listOf(Handle.P1 to Pt(shape.x1, shape.y1), Handle.P2 to Pt(shape.x2, shape.y2))
        is RectShape -> {
            val b = shape.bounds()
            listOf(
                Handle.NW to Pt(b.minX, b.minY),
                Handle.N to Pt(b.midX, b.minY),
                Handle.NE to Pt(b.maxX, b.minY),
                Handle.E to Pt(b.maxX, b.midY),
                Handle.SE to Pt(b.maxX, b.maxY),
                Handle.S to Pt(b.midX, b.maxY),
                Handle.SW to Pt(b.minX, b.maxY),
                Handle.W to Pt(b.minX, b.midY),
            )
        }
        else -> emptyList()
    }

    /** The fixed opposite corner or edge for a rect handle. */
    fun anchor(handle: Handle, b: Bounds): Pt = when (handle) {
        Handle.NW -> Pt(b.maxX, b.maxY)
        Handle.N -> Pt(b.midX, b.maxY)
        Handle.NE -> Pt(b.minX, b.maxY)
        Handle.E -> Pt(b.minX, b.midY)
        Handle.SE -> Pt(b.minX, b.minY)
        Handle.S -> Pt(b.midX, b.minY)
        Handle.SW -> Pt(b.maxX, b.minY)
        Handle.W -> Pt(b.maxX, b.midY)
        Handle.P1, Handle.P2 -> Pt(b.minX, b.minY)
    }

    fun resizeLine(line: LineShape, handle: Handle, f: Pt): LineShape = when (handle) {
        Handle.P1 -> line.copy(x1 = f.x, y1 = f.y)
        Handle.P2 -> line.copy(x2 = f.x, y2 = f.y)
        else -> line
    }

    /** original is the rect as it was on touch-down, normalised by the caller's bounds. */
    fun resizeRect(original: RectShape, handle: Handle, anchor: Pt, f: Pt): RectShape {
        val b = original.bounds()
        return when (handle) {
            Handle.NW, Handle.NE, Handle.SE, Handle.SW -> original.copy(
                x = min(anchor.x, f.x),
                y = min(anchor.y, f.y),
                w = abs(f.x - anchor.x),
                h = abs(f.y - anchor.y),
            )
            Handle.N, Handle.S -> original.copy(
                x = b.minX,
                w = b.maxX - b.minX,
                y = min(anchor.y, f.y),
                h = abs(f.y - anchor.y),
            )
            Handle.E, Handle.W -> original.copy(
                y = b.minY,
                h = b.maxY - b.minY,
                x = min(anchor.x, f.x),
                w = abs(f.x - anchor.x),
            )
            Handle.P1, Handle.P2 -> original
        }
    }

    /** Top-most text shape under p, or null. */
    fun hitText(shapes: List<Shape>, p: Pt, scale: Float, measurer: TextMeasurer): Int? {
        val padding = Metrics.TEXT_HIT_PADDING * scale
        for (i in shapes.indices.reversed()) {
            val shape = shapes[i] as? TextShape ?: continue
            if (textBounds(shape, measurer).expanded(padding).contains(p)) return i
        }
        return null
    }

    /** The handle of a line or rect under p, or null. */
    fun hitHandle(shape: Shape, p: Pt, scale: Float): Handle? {
        val radius = Metrics.HANDLE_HIT * scale
        return handles(shape).firstOrNull { (_, c) -> distance(p, c) <= radius }?.first
    }

    /** Top-most line, rect or freehand under p, or null. */
    fun hitBody(shapes: List<Shape>, p: Pt, scale: Float): Int? {
        for (i in shapes.indices.reversed()) {
            val shape = shapes[i]
            val strokeWidth = when (shape) {
                is LineShape -> shape.strokeWidth
                is RectShape -> shape.strokeWidth
                is FreehandShape -> shape.strokeWidth
                is TextShape -> continue
            }
            val tolerance = max(strokeWidth / 2f + Metrics.BODY_TOLERANCE * scale, Metrics.BODY_MIN_TOLERANCE * scale)

            val hit = when (shape) {
                is LineShape -> distanceToSegment(p, Pt(shape.x1, shape.y1), Pt(shape.x2, shape.y2)) <= tolerance
                is RectShape -> shape.bounds().expanded(tolerance).contains(p)
                is FreehandShape -> when (shape.points.size) {
                    0 -> false
                    1 -> distance(p, shape.points[0]) <= tolerance
                    else -> shape.points.zipWithNext().any { (a, b) -> distanceToSegment(p, a, b) <= tolerance }
                }
                is TextShape -> false
            }
            if (hit) return i
        }
        return null
    }
}

/** Full snapshots of the shape list. apply() is called for every change. */
class History {
    var shapes: List<Shape> = emptyList()
        private set

    private val past = ArrayList<List<Shape>>()
    private val future = ArrayDeque<List<Shape>>()

    val canUndo: Boolean get() = past.isNotEmpty()
    val canRedo: Boolean get() = future.isNotEmpty()

    fun apply(next: List<Shape>) {
        past.add(shapes)
        future.clear()
        shapes = next
    }

    fun undo(): Boolean {
        if (past.isEmpty()) return false
        future.addFirst(shapes)
        shapes = past.removeAt(past.lastIndex)
        return true
    }

    fun redo(): Boolean {
        if (future.isEmpty()) return false
        past.add(shapes)
        shapes = future.removeFirst()
        return true
    }

    fun reset() {
        past.clear()
        future.clear()
        shapes = emptyList()
    }
}
