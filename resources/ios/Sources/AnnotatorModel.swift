import CoreGraphics
import Foundation

// Shape model, geometry, hit testing and history for the annotator.
// Plain Swift with no UIKit types, kept in step with AnnotatorModel.kt.
// Every coordinate and size here is in image pixels unless a name says "points".
// Types are nested in Pteal79Annotator because all plugin sources share one module.

enum Pteal79Annotator {}

extension Pteal79Annotator {

    enum Tool {
        case select, freehand, line, rect, text
    }

    /// Stroke widths and font sizes in screen points. Stored values are these times the scale.
    enum SizePreset: CaseIterable {
        case s, m, l, xl

        var label: String {
            switch self {
            case .s: return "S"
            case .m: return "M"
            case .l: return "L"
            case .xl: return "XL"
            }
        }

        var stroke: CGFloat {
            switch self {
            case .s: return 2
            case .m: return 4
            case .l: return 8
            case .xl: return 16
            }
        }

        var font: CGFloat {
            switch self {
            case .s: return 28
            case .m: return 44
            case .l: return 64
            case .xl: return 88
            }
        }

        static func fromStroke(_ points: CGFloat) -> SizePreset {
            if points <= 3 { return .s }
            if points <= 6 { return .m }
            if points <= 12 { return .l }
            return .xl
        }

        static func fromFont(_ points: CGFloat) -> SizePreset {
            if points <= 36 { return .s }
            if points <= 54 { return .m }
            if points <= 76 { return .l }
            return .xl
        }
    }

    enum FontKey: String, CaseIterable {
        case sans, serif, mono, georgia, impact

        var label: String {
            switch self {
            case .sans: return "Sans"
            case .serif: return "Serif"
            case .mono: return "Mono"
            case .georgia: return "Georgia"
            case .impact: return "Impact"
            }
        }
    }

    enum Handle {
        case p1, p2, nw, n, ne, e, se, s, sw, w
    }

    enum LayerMove {
        case front, forward, backward, back
    }

    enum Palette {
        static let defaultStroke = "#ef4444"
        static let defaultFill = "#ffffff"
        static let white = "#ffffff"

        static let colors = ["#ef4444", "#f97316", "#eab308", "#22c55e", "#3b82f6", "#000000", "#ffffff"]
    }

    /// Sizes in screen points for the overlay and hit testing. Multiply by the scale before use.
    enum Metrics {
        static let lineHeight: CGFloat = 1.2
        static let underlineOffset: CGFloat = 1.05
        static let underlineThickness: CGFloat = 0.06

        static let overlayColor = "#38bdf8"
        static let overlayLine: CGFloat = 1.5
        static let overlayDash: CGFloat = 5
        static let overlayGap: CGFloat = 3
        static let freehandPadding: CGFloat = 8
        static let textPadding: CGFloat = 4
        static let handleSize: CGFloat = 10

        static let handleHit: CGFloat = 5 * 1.5
        static let textHitPadding: CGFloat = 8
        static let bodyTolerance: CGFloat = 6
        static let bodyMinTolerance: CGFloat = 8
        static let moveThreshold: CGFloat = 3
    }

    /// A normalised box in image pixels.
    struct Bounds: Equatable {
        var minX: CGFloat
        var minY: CGFloat
        var maxX: CGFloat
        var maxY: CGFloat

        var midX: CGFloat { (minX + maxX) / 2 }
        var midY: CGFloat { (minY + maxY) / 2 }
        var rect: CGRect { CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) }

        func expanded(by d: CGFloat) -> Bounds {
            Bounds(minX: minX - d, minY: minY - d, maxX: maxX + d, maxY: maxY + d)
        }

        func contains(_ p: CGPoint) -> Bool {
            p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
        }
    }

    struct FreehandShape: Equatable {
        var points: [CGPoint]
        var color: String
        var strokeWidth: CGFloat

        func bounds() -> Bounds {
            guard let first = points.first else { return Bounds(minX: 0, minY: 0, maxX: 0, maxY: 0) }
            var b = Bounds(minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)
            for p in points {
                b.minX = min(b.minX, p.x)
                b.minY = min(b.minY, p.y)
                b.maxX = max(b.maxX, p.x)
                b.maxY = max(b.maxY, p.y)
            }
            return b
        }
    }

    struct LineShape: Equatable {
        var x1: CGFloat
        var y1: CGFloat
        var x2: CGFloat
        var y2: CGFloat
        var color: String
        var strokeWidth: CGFloat
    }

    /// w and h may be negative while drawing. Use bounds() for anything spatial.
    struct RectShape: Equatable {
        var x: CGFloat
        var y: CGFloat
        var w: CGFloat
        var h: CGFloat
        var color: String
        var strokeWidth: CGFloat
        var fill: Bool
        var fillColor: String

        func bounds() -> Bounds {
            Bounds(minX: min(x, x + w), minY: min(y, y + h), maxX: max(x, x + w), maxY: max(y, y + h))
        }
    }

    /// (x, y) is the top-left of the first line.
    struct TextShape: Equatable {
        var x: CGFloat
        var y: CGFloat
        var text: String
        var color: String
        var fontSize: CGFloat
        var fontFamily: FontKey
        var bold: Bool
        var italic: Bool
        var underline: Bool

        var lines: [String] { text.components(separatedBy: "\n") }
    }

    enum Shape: Equatable {
        case freehand(FreehandShape)
        case line(LineShape)
        case rect(RectShape)
        case text(TextShape)

        var color: String {
            switch self {
            case .freehand(let s): return s.color
            case .line(let s): return s.color
            case .rect(let s): return s.color
            case .text(let s): return s.color
            }
        }

        func moved(dx: CGFloat, dy: CGFloat) -> Shape {
            switch self {
            case .freehand(var s):
                s.points = s.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
                return .freehand(s)
            case .line(var s):
                s.x1 += dx; s.y1 += dy; s.x2 += dx; s.y2 += dy
                return .line(s)
            case .rect(var s):
                s.x += dx; s.y += dy
                return .rect(s)
            case .text(var s):
                s.x += dx; s.y += dy
                return .text(s)
            }
        }

        func withColor(_ color: String) -> Shape {
            switch self {
            case .freehand(var s): s.color = color; return .freehand(s)
            case .line(var s): s.color = color; return .line(s)
            case .rect(var s): s.color = color; return .rect(s)
            case .text(var s): s.color = color; return .text(s)
            }
        }
    }

    /// Measures one line of text in image pixels, using the shape's font, size and style.
    typealias TextMeasurer = (_ line: String, _ shape: TextShape) -> CGFloat

    enum Geometry {
        static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            hypot(a.x - b.x, a.y - b.y)
        }

        static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x
            let dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            if lengthSquared == 0 { return distance(p, a) }

            let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
            return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
        }

        static func textBounds(_ shape: TextShape, _ measure: TextMeasurer) -> Bounds {
            let lines = shape.lines
            let widest = lines.map { measure($0, shape) }.max() ?? 0
            let width = max(widest, shape.fontSize)
            let height = CGFloat(lines.count) * shape.fontSize * Metrics.lineHeight
            return Bounds(minX: shape.x, minY: shape.y, maxX: shape.x + width, maxY: shape.y + height)
        }

        /// Resize handles for lines and rects. Freehand and text have none.
        static func handles(_ shape: Shape) -> [(Handle, CGPoint)] {
            switch shape {
            case .line(let s):
                return [(.p1, CGPoint(x: s.x1, y: s.y1)), (.p2, CGPoint(x: s.x2, y: s.y2))]
            case .rect(let s):
                let b = s.bounds()
                return [
                    (.nw, CGPoint(x: b.minX, y: b.minY)),
                    (.n, CGPoint(x: b.midX, y: b.minY)),
                    (.ne, CGPoint(x: b.maxX, y: b.minY)),
                    (.e, CGPoint(x: b.maxX, y: b.midY)),
                    (.se, CGPoint(x: b.maxX, y: b.maxY)),
                    (.s, CGPoint(x: b.midX, y: b.maxY)),
                    (.sw, CGPoint(x: b.minX, y: b.maxY)),
                    (.w, CGPoint(x: b.minX, y: b.midY)),
                ]
            default:
                return []
            }
        }

        /// The fixed opposite corner or edge for a rect handle.
        static func anchor(_ handle: Handle, _ b: Bounds) -> CGPoint {
            switch handle {
            case .nw: return CGPoint(x: b.maxX, y: b.maxY)
            case .n: return CGPoint(x: b.midX, y: b.maxY)
            case .ne: return CGPoint(x: b.minX, y: b.maxY)
            case .e: return CGPoint(x: b.minX, y: b.midY)
            case .se: return CGPoint(x: b.minX, y: b.minY)
            case .s: return CGPoint(x: b.midX, y: b.minY)
            case .sw: return CGPoint(x: b.maxX, y: b.minY)
            case .w: return CGPoint(x: b.maxX, y: b.midY)
            case .p1, .p2: return CGPoint(x: b.minX, y: b.minY)
            }
        }

        static func resizeLine(_ line: LineShape, _ handle: Handle, _ f: CGPoint) -> LineShape {
            var s = line
            switch handle {
            case .p1: s.x1 = f.x; s.y1 = f.y
            case .p2: s.x2 = f.x; s.y2 = f.y
            default: break
            }
            return s
        }

        /// original is the rect as it was on touch-down.
        static func resizeRect(_ original: RectShape, _ handle: Handle, _ anchor: CGPoint, _ f: CGPoint) -> RectShape {
            let b = original.bounds()
            var s = original
            switch handle {
            case .nw, .ne, .se, .sw:
                s.x = min(anchor.x, f.x)
                s.y = min(anchor.y, f.y)
                s.w = abs(f.x - anchor.x)
                s.h = abs(f.y - anchor.y)
            case .n, .s:
                s.x = b.minX
                s.w = b.maxX - b.minX
                s.y = min(anchor.y, f.y)
                s.h = abs(f.y - anchor.y)
            case .e, .w:
                s.y = b.minY
                s.h = b.maxY - b.minY
                s.x = min(anchor.x, f.x)
                s.w = abs(f.x - anchor.x)
            case .p1, .p2:
                break
            }
            return s
        }

        /// Top-most text shape under p, or nil.
        static func hitText(_ shapes: [Shape], _ p: CGPoint, scale: CGFloat, measure: TextMeasurer) -> Int? {
            let padding = Metrics.textHitPadding * scale
            for i in shapes.indices.reversed() {
                guard case .text(let s) = shapes[i] else { continue }
                if textBounds(s, measure).expanded(by: padding).contains(p) { return i }
            }
            return nil
        }

        /// The handle of a line or rect under p, or nil.
        static func hitHandle(_ shape: Shape, _ p: CGPoint, scale: CGFloat) -> Handle? {
            let radius = Metrics.handleHit * scale
            return handles(shape).first { distance(p, $0.1) <= radius }?.0
        }

        /// Top-most line, rect or freehand under p, or nil.
        static func hitBody(_ shapes: [Shape], _ p: CGPoint, scale: CGFloat) -> Int? {
            func tolerance(_ strokeWidth: CGFloat) -> CGFloat {
                max(strokeWidth / 2 + Metrics.bodyTolerance * scale, Metrics.bodyMinTolerance * scale)
            }

            for i in shapes.indices.reversed() {
                let hit: Bool
                switch shapes[i] {
                case .line(let s):
                    hit = distanceToSegment(p, CGPoint(x: s.x1, y: s.y1), CGPoint(x: s.x2, y: s.y2)) <= tolerance(s.strokeWidth)
                case .rect(let s):
                    hit = s.bounds().expanded(by: tolerance(s.strokeWidth)).contains(p)
                case .freehand(let s):
                    let t = tolerance(s.strokeWidth)
                    if s.points.count == 1 {
                        hit = distance(p, s.points[0]) <= t
                    } else {
                        hit = zip(s.points, s.points.dropFirst()).contains { distanceToSegment(p, $0, $1) <= t }
                    }
                case .text:
                    hit = false
                }
                if hit { return i }
            }
            return nil
        }
    }

    /// Full snapshots of the shape list. apply() is called for every change.
    final class History {
        private(set) var shapes: [Shape] = []
        private var past: [[Shape]] = []
        private var future: [[Shape]] = []

        var canUndo: Bool { !past.isEmpty }
        var canRedo: Bool { !future.isEmpty }

        func apply(_ next: [Shape]) {
            past.append(shapes)
            future.removeAll()
            shapes = next
        }

        @discardableResult
        func undo() -> Bool {
            guard let previous = past.popLast() else { return false }
            future.insert(shapes, at: 0)
            shapes = previous
            return true
        }

        @discardableResult
        func redo() -> Bool {
            guard !future.isEmpty else { return false }
            past.append(shapes)
            shapes = future.removeFirst()
            return true
        }

        func reset() {
            past.removeAll()
            future.removeAll()
            shapes = []
        }
    }
}
