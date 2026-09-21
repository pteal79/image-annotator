import UIKit

protocol AnnotatorCanvasViewHost: AnyObject {
    /// True while the inline text editor is open.
    func canvasIsEditingText() -> Bool
    /// A touch landed outside the text editor: commit it.
    func canvasCommitTextEditing()
    func canvasBeginTextEditing(_ session: Pteal79Annotator.TextEditSession)
    func canvasEditorChanged()
}

/// Shows the image with its annotations and turns touches into editor calls.
/// The image sits in an image view; the shapes view draws the annotations in
/// draw(_:) through one image-to-view transform.
///
/// One finger draws, selects or edits. Two fingers pinch-zoom and pan; the
/// second finger drops any gesture in progress and never starts a shape. In
/// Select mode, one finger on empty space pans while zoomed in.
final class AnnotatorCanvasView: UIView {
    typealias Editor = Pteal79Annotator.Editor

    static let maxZoom: CGFloat = 8
    static let zoomStep: CGFloat = 1.5

    private enum Mode { case none, draw, pan, zoom, swallow }

    weak var host: AnnotatorCanvasViewHost?

    private let editor: Editor
    private let imageView = UIImageView()
    private let shapesView: AnnotatorShapesView
    private let placeholder = UILabel()

    var image: UIImage? {
        didSet {
            imageView.image = image
            placeholder.isHidden = image != nil
            zoom = 1
            imageRect = .zero
            setNeedsLayout()
            layoutIfNeeded()
            shapesView.setNeedsDisplay()
        }
    }

    /// Where the image sits in this view, in points.
    private(set) var imageRect: CGRect = .zero

    /// 1 when the image is fitted, up to maxZoom.
    private(set) var zoom: CGFloat = 1

    var canZoomIn: Bool { image != nil && zoom < Self.maxZoom - 0.001 }
    var canZoomOut: Bool { image != nil && zoom > 1.001 }

    /// View points per image pixel with the image fitted.
    private var fitViewPerImage: CGFloat = 1
    private var viewPerImage: CGFloat { fitViewPerImage * zoom }
    private var lastSize: CGSize = .zero

    private var mode = Mode.none
    /// Touches in the order they came down, so the pinch pair stays stable.
    private var touches: [UITouch] = []
    private var lastPoint: CGPoint = .zero
    private var lastSpan: CGFloat = 0

    init(editor: Editor) {
        self.editor = editor
        self.shapesView = AnnotatorShapesView(editor: editor)
        super.init(frame: .zero)

        backgroundColor = UIColor(red: 15 / 255, green: 15 / 255, blue: 15 / 255, alpha: 1)
        isMultipleTouchEnabled = true
        clipsToBounds = true

        imageView.contentMode = .scaleToFill
        addSubview(imageView)

        shapesView.backgroundColor = .clear
        shapesView.isOpaque = false
        shapesView.isUserInteractionEnabled = false
        shapesView.contentMode = .redraw
        addSubview(shapesView)

        placeholder.text = "Loading image\u{2026}"
        placeholder.textColor = UIColor(white: 0.62, alpha: 1)
        placeholder.font = .systemFont(ofSize: 15)
        placeholder.textAlignment = .center
        addSubview(placeholder)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Fits the image, applies zoom and pan, and recomputes the editor's scales. Shapes never change.
    override func layoutSubviews() {
        super.layoutSubviews()
        placeholder.frame = bounds
        shapesView.frame = bounds

        guard let cgImage = image?.cgImage, bounds.width > 0, bounds.height > 0 else { return }
        let pixelWidth = CGFloat(cgImage.width)
        let pixelHeight = CGFloat(cgImage.height)

        // Keep the image point at the centre of the old size in the centre.
        var centre: CGPoint?
        if imageRect != .zero, lastSize != bounds.size, lastSize.width > 0 {
            centre = toImage(CGPoint(x: lastSize.width / 2, y: lastSize.height / 2))
        }
        let resized = lastSize != bounds.size
        lastSize = bounds.size

        fitViewPerImage = min(bounds.width / pixelWidth, bounds.height / pixelHeight)
        let size = CGSize(width: pixelWidth * viewPerImage, height: pixelHeight * viewPerImage)

        var origin = imageRect.origin
        if let centre {
            origin = CGPoint(x: bounds.width / 2 - centre.x * viewPerImage, y: bounds.height / 2 - centre.y * viewPerImage)
        } else if imageRect == .zero {
            origin = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        }
        let before = imageRect
        imageRect = clamped(CGRect(origin: origin, size: size))

        // Image pixels per screen point, fitted and at the current zoom.
        editor.scale = pixelWidth / (pixelWidth * fitViewPerImage)
        editor.touchScale = editor.scale / zoom
        applyImageRect()
        if resized || imageRect != before { host?.canvasEditorChanged() }
    }

    /// Centres the image on an axis where it is smaller than the view, otherwise keeps the view covered.
    private func clamped(_ rect: CGRect) -> CGRect {
        var r = rect
        r.origin.x = r.width <= bounds.width ? (bounds.width - r.width) / 2 : min(max(r.minX, bounds.width - r.width), 0)
        r.origin.y = r.height <= bounds.height ? (bounds.height - r.height) / 2 : min(max(r.minY, bounds.height - r.height), 0)
        return r
    }

    private func applyImageRect() {
        imageView.frame = imageRect
        shapesView.imageRect = imageRect
        shapesView.setNeedsDisplay()
    }

    /// Zooms by factor, keeping the image point under focus still.
    func zoom(by factor: CGFloat, focus: CGPoint? = nil) {
        guard let cgImage = image?.cgImage else { return }
        let next = min(max(zoom * factor, 1), Self.maxZoom)
        if next == zoom { return }

        let f = focus ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let anchor = toImage(f)
        zoom = next
        let size = CGSize(width: CGFloat(cgImage.width) * viewPerImage, height: CGFloat(cgImage.height) * viewPerImage)
        imageRect = clamped(CGRect(x: f.x - anchor.x * viewPerImage, y: f.y - anchor.y * viewPerImage, width: size.width, height: size.height))
        editor.touchScale = editor.scale / zoom
        applyImageRect()
        host?.canvasEditorChanged()
    }

    func resetZoom() {
        guard image != nil, zoom != 1 else { return }
        zoom = 1
        imageRect = .zero
        setNeedsLayout()
        layoutIfNeeded()
        host?.canvasEditorChanged()
    }

    private func pan(by dx: CGFloat, _ dy: CGFloat) {
        imageRect = clamped(imageRect.offsetBy(dx: dx, dy: dy))
        applyImageRect()
        host?.canvasEditorChanged()
    }

    func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - imageRect.minX) / viewPerImage, y: (p.y - imageRect.minY) / viewPerImage)
    }

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + p.x * viewPerImage, y: imageRect.minY + p.y * viewPerImage)
    }

    func redraw() {
        shapesView.setNeedsDisplay()
    }

    // MARK: Touches

    override func touchesBegan(_ began: Set<UITouch>, with event: UIEvent?) {
        guard image != nil, isUserInteractionEnabled else { return }
        let wasEmpty = touches.isEmpty
        touches.append(contentsOf: began)

        if wasEmpty, let touch = touches.first {
            lastPoint = touch.location(in: self)
            if host?.canvasIsEditingText() == true {
                host?.canvasCommitTextEditing()
                mode = .swallow
            } else {
                editor.touchDown(toImage(lastPoint))
                mode = editor.touchIsIdle && zoom > 1 ? .pan : .draw
                changed()
            }
        }

        if touches.count >= 2 && mode != .zoom {
            // A second finger never draws: drop whatever the first one started.
            if mode == .draw { editor.abortTouch() }
            mode = .zoom
            startPinch()
            changed()
        }
    }

    override func touchesMoved(_ moved: Set<UITouch>, with event: UIEvent?) {
        guard image != nil, let first = touches.first else { return }

        switch mode {
        case .draw:
            let samples = event?.coalescedTouches(for: first) ?? [first]
            for sample in samples {
                editor.touchMove(toImage(sample.location(in: self)))
            }
            changed()
        case .pan:
            let p = first.location(in: self)
            pan(by: p.x - lastPoint.x, p.y - lastPoint.y)
            lastPoint = p
        case .zoom:
            guard touches.count >= 2 else { return }
            let (focus, span) = pinch()
            pan(by: focus.x - lastPoint.x, focus.y - lastPoint.y)
            if lastSpan > 0, span > 0 { zoom(by: span / lastSpan, focus: focus) }
            lastSpan = span
            lastPoint = focus
        case .none, .swallow:
            break
        }
    }

    override func touchesEnded(_ ended: Set<UITouch>, with event: UIEvent?) {
        guard image != nil else { return }
        let first = touches.first
        touches.removeAll { ended.contains($0) }

        if touches.isEmpty {
            if (mode == .draw || mode == .pan), let first {
                let session = editor.touchUp(toImage(first.location(in: self)))
                changed()
                if let session { host?.canvasBeginTextEditing(session) }
            }
            mode = .none
        } else if mode == .zoom {
            // Carry on pinching with the fingers that are left, or wait for them to lift.
            if touches.count >= 2 { startPinch() } else { mode = .swallow }
        }
    }

    override func touchesCancelled(_ cancelled: Set<UITouch>, with event: UIEvent?) {
        guard image != nil else { return }
        touches.removeAll { cancelled.contains($0) }
        guard touches.isEmpty else { return }

        if mode == .draw { editor.touchCancel() } else if mode == .pan { editor.abortTouch() }
        mode = .none
        changed()
    }

    private func startPinch() {
        let (focus, span) = pinch()
        lastPoint = focus
        lastSpan = span
    }

    private func pinch() -> (focus: CGPoint, span: CGFloat) {
        let a = touches[0].location(in: self)
        let b = touches[1].location(in: self)
        return (CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), hypot(a.x - b.x, a.y - b.y))
    }

    private func changed() {
        shapesView.setNeedsDisplay()
        host?.canvasEditorChanged()
    }
}

/// Draws the annotations over the image view, in image pixels.
private final class AnnotatorShapesView: UIView {
    private let editor: Pteal79Annotator.Editor
    var imageRect: CGRect = .zero

    init(editor: Pteal79Annotator.Editor) {
        self.editor = editor
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), imageRect.width > 0 else { return }

        // touchScale is image pixels per point at the current zoom.
        ctx.saveGState()
        ctx.translateBy(x: imageRect.minX, y: imageRect.minY)
        ctx.scaleBy(x: 1 / editor.touchScale, y: 1 / editor.touchScale)

        let shapes = editor.shapes
        let preview = editor.preview
        let hidden = editor.hiddenIndex
        for (i, shape) in shapes.enumerated() where i != hidden {
            let drawn = preview?.index == i ? preview!.shape : shape
            Pteal79Annotator.Renderer.draw(drawn, in: ctx)
        }

        if let draft = editor.draft {
            Pteal79Annotator.Renderer.draw(draft, in: ctx)
        }

        if let i = editor.selectedIndex, i != hidden, shapes.indices.contains(i) {
            let shape = preview?.index == i ? preview!.shape : shapes[i]
            Pteal79Annotator.Renderer.drawOverlay(shape, scale: editor.touchScale, in: ctx)
        }

        ctx.restoreGState()
    }
}
