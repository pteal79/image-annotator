import CoreGraphics
import Foundation

// Editor state and interaction logic. Plain Swift with no UIKit types, kept in
// step with AnnotatorEditor.kt. The view turns touches into image pixel points,
// calls touchDown/touchMove/touchUp, and redraws.

extension Pteal79Annotator {

    /// An open inline text editor. Its format fields change while the user
    /// edits; commitText() turns it into a shape.
    final class TextEditSession {
        /// Top-left of the first line, in image pixels.
        let anchor: CGPoint
        let initialText: String
        /// Index of the text shape being re-edited, or nil for new text.
        let editingIndex: Int?
        /// The re-edited shape's stored font size, kept when its size preset is unchanged.
        private let originalFontSize: CGFloat?
        private let originalSize: SizePreset?

        var color: String
        var fontFamily: FontKey
        var bold: Bool
        var italic: Bool
        var underline: Bool
        var size: SizePreset

        init(anchor: CGPoint, initialText: String, editingIndex: Int?, originalFontSize: CGFloat?, originalSize: SizePreset?,
             color: String, fontFamily: FontKey, bold: Bool, italic: Bool, underline: Bool, size: SizePreset) {
            self.anchor = anchor
            self.initialText = initialText
            self.editingIndex = editingIndex
            self.originalFontSize = originalFontSize
            self.originalSize = originalSize
            self.color = color
            self.fontFamily = fontFamily
            self.bold = bold
            self.italic = italic
            self.underline = underline
            self.size = size
        }

        func fontSize(scale: CGFloat) -> CGFloat {
            if let originalFontSize, size == originalSize { return originalFontSize }
            return size.font * scale
        }
    }

    final class Editor {
        private enum DragKind { case move, resize }

        private struct Drag {
            let kind: DragKind
            let index: Int
            let start: CGPoint
            let original: Shape
            var handle: Handle?
            var anchor: CGPoint?
            var moved = false
            var current: Shape
        }

        private let history = History()
        private let measure: TextMeasurer

        var shapes: [Shape] { history.shapes }

        /// Image pixels per screen point with the image fitted (zoom 1). Set by
        /// the view on every layout. Stroke widths and font sizes use this, so
        /// zooming never changes the size a new shape gets.
        var scale: CGFloat = 1

        /// Image pixels per screen point at the current zoom (scale / zoom).
        /// Touch tolerances and the selection overlay use this so they stay the
        /// same size on screen at any zoom.
        var touchScale: CGFloat = 1

        private(set) var tool: Tool = .select
        private(set) var color: String = Palette.defaultStroke
        private(set) var size: SizePreset = .m
        private(set) var fill = false
        private(set) var fillColor: String = Palette.defaultFill

        /// Format used for the next new text. Updated from each committed text.
        private var fontFamily: FontKey = .sans
        private var bold = false
        private var italic = false
        private var underline = false

        private(set) var selectedIndex: Int?
        private(set) var reverted = false

        /// The shape being drawn with a drawing tool.
        private(set) var draft: Shape?

        private(set) var textSession: TextEditSession?

        private var drag: Drag?
        private var pendingTextTap: CGPoint?

        init(measure: @escaping TextMeasurer) {
            self.measure = measure
        }

        var canUndo: Bool { history.canUndo }
        var canRedo: Bool { history.canRedo }
        var hasUnsavedChanges: Bool { history.canUndo || reverted }

        var selectedShape: Shape? {
            guard let i = selectedIndex, shapes.indices.contains(i) else { return nil }
            return shapes[i]
        }

        /// Index of a text shape hidden while it is re-edited.
        var hiddenIndex: Int? { textSession?.editingIndex }

        /// The dragged copy of a shape, drawn in place of shapes[index].
        var preview: (index: Int, shape: Shape)? {
            guard let drag, drag.moved else { return nil }
            return (drag.index, drag.current)
        }

        var canBringForward: Bool { selectedIndex.map { $0 < shapes.count - 1 } ?? false }
        var canSendBackward: Bool { selectedIndex.map { $0 > 0 } ?? false }

        var showsFillControls: Bool {
            if tool == .rect { return true }
            if case .rect = selectedShape { return true }
            return false
        }

        /// True after touchDown when the touch grabbed nothing, so the view may pan instead.
        var touchIsIdle: Bool { tool == .select && drag == nil }

        // MARK: Tools and styles

        func setTool(_ next: Tool) {
            tool = next
            drag = nil
            draft = nil
            pendingTextTap = nil
            if next != .select { deselect() }
        }

        func setColor(_ next: String) {
            color = next
            if let textSession {
                textSession.color = next
                return
            }
            restyleSelected { $0.withColor(next) }
        }

        func setSize(_ next: SizePreset) {
            size = next
            if let textSession {
                textSession.size = next
                return
            }
            let scale = self.scale
            restyleSelected { shape in
                switch shape {
                case .freehand(var s): s.strokeWidth = next.stroke * scale; return .freehand(s)
                case .line(var s): s.strokeWidth = next.stroke * scale; return .line(s)
                case .rect(var s): s.strokeWidth = next.stroke * scale; return .rect(s)
                case .text(var s): s.fontSize = next.font * scale; return .text(s)
                }
            }
        }

        func setFill(_ next: Bool) {
            fill = next
            restyleSelected { shape in
                guard case .rect(var s) = shape else { return shape }
                s.fill = next
                return .rect(s)
            }
        }

        func setFillColor(_ next: String) {
            fillColor = next
            restyleSelected { shape in
                guard case .rect(var s) = shape else { return shape }
                s.fillColor = next
                return .rect(s)
            }
        }

        private func restyleSelected(_ transform: (Shape) -> Shape) {
            guard tool == .select, let index = selectedIndex, shapes.indices.contains(index) else { return }
            let shape = shapes[index]
            let updated = transform(shape)
            if updated != shape { replace(index, updated) }
        }

        // MARK: Selection

        func select(_ index: Int) {
            selectedIndex = index
            guard shapes.indices.contains(index) else { return }
            let shape = shapes[index]
            color = shape.color
            switch shape {
            case .freehand(let s): size = .fromStroke(s.strokeWidth / scale)
            case .line(let s): size = .fromStroke(s.strokeWidth / scale)
            case .rect(let s):
                size = .fromStroke(s.strokeWidth / scale)
                fill = s.fill
                fillColor = s.fillColor
            case .text(let s): size = .fromFont(s.fontSize / scale)
            }
        }

        func deselect() {
            selectedIndex = nil
        }

        // MARK: Touches, in image pixels

        func touchDown(_ p: CGPoint) {
            drag = nil
            draft = nil
            pendingTextTap = nil

            switch tool {
            case .freehand:
                draft = .freehand(FreehandShape(points: [p], color: color, strokeWidth: size.stroke * scale))
            case .line:
                draft = .line(LineShape(x1: p.x, y1: p.y, x2: p.x, y2: p.y, color: color, strokeWidth: size.stroke * scale))
            case .rect:
                draft = .rect(RectShape(x: p.x, y: p.y, w: 0, h: 0, color: color, strokeWidth: size.stroke * scale, fill: fill, fillColor: fillColor))
            case .text:
                pendingTextTap = p
            case .select:
                beginSelectTouch(p)
            }
        }

        private func beginSelectTouch(_ p: CGPoint) {
            if let index = Geometry.hitText(shapes, p, scale: touchScale, measure: measure) {
                select(index)
                drag = Drag(kind: .move, index: index, start: p, original: shapes[index], current: shapes[index])
                return
            }

            if let index = selectedIndex, shapes.indices.contains(index) {
                let shape = shapes[index]
                if let handle = Geometry.hitHandle(shape, p, scale: touchScale) {
                    var anchor: CGPoint?
                    if case .rect(let r) = shape { anchor = Geometry.anchor(handle, r.bounds()) }
                    drag = Drag(kind: .resize, index: index, start: p, original: shape, handle: handle, anchor: anchor, current: shape)
                    return
                }
            }

            if let index = Geometry.hitBody(shapes, p, scale: touchScale) {
                select(index)
                drag = Drag(kind: .move, index: index, start: p, original: shapes[index], current: shapes[index])
                return
            }

            deselect()
        }

        func touchMove(_ p: CGPoint) {
            switch draft {
            case .freehand(var s):
                guard s.points.last != p else { break }
                // Clear the enum first so the points array is appended in place.
                draft = nil
                s.points.append(p)
                draft = .freehand(s)
            case .line(var s):
                s.x2 = p.x; s.y2 = p.y
                draft = .line(s)
            case .rect(var s):
                s.w = p.x - s.x; s.h = p.y - s.y
                draft = .rect(s)
            default:
                break
            }

            guard var d = drag else { return }
            if !d.moved && Geometry.distance(d.start, p) <= Metrics.moveThreshold * touchScale { return }
            d.moved = true

            switch d.kind {
            case .move:
                d.current = d.original.moved(dx: p.x - d.start.x, dy: p.y - d.start.y)
            case .resize:
                switch d.original {
                case .line(let s):
                    if let handle = d.handle { d.current = .line(Geometry.resizeLine(s, handle, p)) }
                case .rect(let s):
                    if let handle = d.handle, let anchor = d.anchor { d.current = .rect(Geometry.resizeRect(s, handle, anchor, p)) }
                default:
                    break
                }
            }
            drag = d
        }

        /// Returns a text session when the touch opened the text editor.
        func touchUp(_ p: CGPoint) -> TextEditSession? {
            touchMove(p)

            commitDraft()

            if let tap = pendingTextTap {
                pendingTextTap = nil
                return beginNewText(tap)
            }

            guard let d = drag else { return nil }
            drag = nil

            if d.moved {
                replace(d.index, d.current)
                selectedIndex = d.index
                return nil
            }

            guard case .text(let text) = d.original else { return nil }
            return beginEditText(d.index, text)
        }

        /// A second finger came down: drop the gesture without adding or changing anything.
        func abortTouch() {
            draft = nil
            drag = nil
            pendingTextTap = nil
        }

        func touchCancel() {
            commitDraft()
            pendingTextTap = nil
            drag = nil
        }

        private func commitDraft() {
            guard let shape = draft else { return }
            draft = nil
            if isVisible(shape) { add(shape) }
        }

        /// Zero-size shapes (a tap with a drawing tool) are not added.
        private func isVisible(_ shape: Shape) -> Bool {
            switch shape {
            case .freehand(let s): return s.points.count >= 2
            case .line(let s): return s.x1 != s.x2 || s.y1 != s.y2
            case .rect(let s): return s.w != 0 && s.h != 0
            case .text(let s): return !s.text.isEmpty
            }
        }

        // MARK: Text

        private func beginNewText(_ anchor: CGPoint) -> TextEditSession {
            let session = TextEditSession(
                anchor: anchor, initialText: "", editingIndex: nil, originalFontSize: nil, originalSize: nil,
                color: color, fontFamily: fontFamily, bold: bold, italic: italic, underline: underline, size: size
            )
            textSession = session
            return session
        }

        private func beginEditText(_ index: Int, _ shape: TextShape) -> TextEditSession {
            let preset = SizePreset.fromFont(shape.fontSize / scale)
            let session = TextEditSession(
                anchor: CGPoint(x: shape.x, y: shape.y), initialText: shape.text, editingIndex: index,
                originalFontSize: shape.fontSize, originalSize: preset,
                color: shape.color, fontFamily: shape.fontFamily, bold: shape.bold, italic: shape.italic,
                underline: shape.underline, size: preset
            )
            textSession = session
            return session
        }

        /// Commits the open text editor. Empty text adds nothing and leaves a re-edited shape unchanged.
        func commitText(_ raw: String) {
            guard let session = textSession else { return }
            textSession = nil

            fontFamily = session.fontFamily
            bold = session.bold
            italic = session.italic
            underline = session.underline

            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return }

            let shape = Shape.text(TextShape(
                x: session.anchor.x, y: session.anchor.y, text: text, color: session.color,
                fontSize: session.fontSize(scale: scale), fontFamily: session.fontFamily,
                bold: session.bold, italic: session.italic, underline: session.underline
            ))

            if let index = session.editingIndex {
                guard shapes.indices.contains(index) else { return }
                if shapes[index] != shape { replace(index, shape) }
                selectedIndex = index
            } else {
                add(shape)
            }
        }

        func cancelText() {
            textSession = nil
        }

        // MARK: Document actions

        func deleteSelected() {
            guard let index = selectedIndex, shapes.indices.contains(index) else { return }
            var list = shapes
            list.remove(at: index)
            history.apply(list)
            deselect()
        }

        func moveLayer(_ move: LayerMove) {
            guard let index = selectedIndex, shapes.indices.contains(index) else { return }
            let last = shapes.count - 1
            let target: Int
            switch move {
            case .front: target = last
            case .forward: target = min(index + 1, last)
            case .backward: target = max(index - 1, 0)
            case .back: target = 0
            }
            if target == index { return }

            var list = shapes
            let shape = list.remove(at: index)
            list.insert(shape, at: target)
            history.apply(list)
            selectedIndex = target
        }

        /// Returns false when there was nothing to clear.
        @discardableResult
        func clearAll() -> Bool {
            if shapes.isEmpty { return false }
            history.apply([])
            deselect()
            return true
        }

        func undo() {
            drag = nil
            draft = nil
            if history.undo() { dropStaleSelection() }
        }

        func redo() {
            drag = nil
            draft = nil
            if history.redo() { dropStaleSelection() }
        }

        private func dropStaleSelection() {
            if let index = selectedIndex, !shapes.indices.contains(index) { deselect() }
        }

        /// Clears everything for the original image. Cannot be undone.
        func revert() {
            history.reset()
            drag = nil
            draft = nil
            textSession = nil
            pendingTextTap = nil
            deselect()
            reverted = true
        }

        /// Ends any gesture, text edit and selection before exporting.
        func prepareForSave() {
            touchCancel()
            deselect()
        }

        private func add(_ shape: Shape) {
            history.apply(shapes + [shape])
        }

        private func replace(_ index: Int, _ shape: Shape) {
            var list = shapes
            list[index] = shape
            history.apply(list)
        }
    }
}
