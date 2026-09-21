import UIKit

extension Pteal79Annotator {

    /// Draws shapes and the selection overlay into a context that is already
    /// in image pixel space. The same code draws the screen and the exported JPEG.
    enum Renderer {

        static func draw(_ shape: Shape, in ctx: CGContext) {
            switch shape {
            case .freehand(let s):
                guard s.points.count >= 2 else { return }
                ctx.beginPath()
                ctx.addLines(between: s.points)
                stroke(ctx, color: s.color, width: s.strokeWidth)
            case .line(let s):
                ctx.beginPath()
                ctx.move(to: CGPoint(x: s.x1, y: s.y1))
                ctx.addLine(to: CGPoint(x: s.x2, y: s.y2))
                stroke(ctx, color: s.color, width: s.strokeWidth)
            case .rect(let s):
                let rect = s.bounds().rect
                if s.fill {
                    ctx.setFillColor(color(s.fillColor).cgColor)
                    ctx.fill(rect)
                }
                ctx.beginPath()
                ctx.addRect(rect)
                stroke(ctx, color: s.color, width: s.strokeWidth)
            case .text(let s):
                drawText(s, in: ctx)
            }
        }

        private static func stroke(_ ctx: CGContext, color hex: String, width: CGFloat) {
            ctx.setStrokeColor(color(hex).cgColor)
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.strokePath()
        }

        private static func drawText(_ s: TextShape, in ctx: CGContext) {
            let font = Fonts.font(s.fontFamily, size: s.fontSize, bold: s.bold, italic: s.italic)
            let fill = color(s.color)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fill]
            let lineHeight = s.fontSize * Metrics.lineHeight
            let thickness = max(1, s.fontSize * Metrics.underlineThickness)

            UIGraphicsPushContext(ctx)
            defer { UIGraphicsPopContext() }

            for (i, line) in s.lines.enumerated() where !line.isEmpty {
                let top = s.y + CGFloat(i) * lineHeight
                // Baseline at top + ascender, matching Android's top - fontMetrics.ascent.
                let origin = CGPoint(x: s.x, y: top + font.ascender)
                drawLine(line, font: font, color: fill, baseline: origin, in: ctx)

                if s.underline {
                    let width = (line as NSString).size(withAttributes: attributes).width
                    let y = top + s.fontSize * Metrics.underlineOffset
                    ctx.setFillColor(fill.cgColor)
                    ctx.fill(CGRect(x: s.x, y: y - thickness / 2, width: width, height: thickness))
                }
            }
        }

        /// Draws one line with its baseline at the given point, in a y-down context.
        private static func drawLine(_ text: String, font: UIFont, color: UIColor, baseline: CGPoint, in ctx: CGContext) {
            let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            let line = CTLineCreateWithAttributedString(attributed)
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: baseline.x, y: baseline.y)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }

        static func measure(_ line: String, _ shape: TextShape) -> CGFloat {
            if line.isEmpty { return 0 }
            let font = Fonts.font(shape.fontFamily, size: shape.fontSize, bold: shape.bold, italic: shape.italic)
            return (line as NSString).size(withAttributes: [.font: font]).width
        }

        /// Dashed outline plus handles. Never drawn into the export.
        static func drawOverlay(_ shape: Shape, scale: CGFloat, in ctx: CGContext) {
            let overlay = color(Metrics.overlayColor).cgColor
            ctx.saveGState()
            defer { ctx.restoreGState() }

            ctx.setStrokeColor(overlay)
            ctx.setLineWidth(Metrics.overlayLine * scale)
            ctx.setLineCap(.butt)
            ctx.setLineJoin(.miter)
            ctx.setLineDash(phase: 0, lengths: [Metrics.overlayDash * scale, Metrics.overlayGap * scale])

            ctx.beginPath()
            switch shape {
            case .line(let s):
                ctx.move(to: CGPoint(x: s.x1, y: s.y1))
                ctx.addLine(to: CGPoint(x: s.x2, y: s.y2))
            case .rect(let s):
                ctx.addRect(s.bounds().rect)
            case .freehand(let s):
                ctx.addRect(s.bounds().expanded(by: Metrics.freehandPadding * scale).rect)
            case .text(let s):
                ctx.addRect(Geometry.textBounds(s, measure).expanded(by: Metrics.textPadding * scale).rect)
            }
            ctx.strokePath()

            ctx.setLineDash(phase: 0, lengths: [])
            let half = Metrics.handleSize * scale / 2
            for (_, c) in Geometry.handles(shape) {
                let rect = CGRect(x: c.x - half, y: c.y - half, width: half * 2, height: half * 2)
                ctx.setFillColor(UIColor.white.cgColor)
                ctx.fill(rect)
                ctx.stroke(rect)
            }
        }

        /// Renders the image and shapes at full resolution, without the overlay.
        static func export(image: UIImage, shapes: [Shape]) -> Data? {
            guard let cgImage = image.cgImage else { return nil }
            let size = CGSize(width: cgImage.width, height: cgImage.height)

            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true

            let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
                let ctx = context.cgContext
                ctx.setFillColor(UIColor.white.cgColor)
                ctx.fill(CGRect(origin: .zero, size: size))
                image.draw(in: CGRect(origin: .zero, size: size))
                for shape in shapes {
                    draw(shape, in: ctx)
                }
            }
            return rendered.jpegData(compressionQuality: 0.92)
        }

        private static let colorCache = NSCache<NSString, UIColor>()

        static func color(_ hex: String) -> UIColor {
            if let cached = colorCache.object(forKey: hex as NSString) { return cached }

            let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            let value = digits.count == 6 ? UInt64(digits, radix: 16) : nil
            let color = value.map { value in
                UIColor(
                    red: CGFloat((value >> 16) & 0xff) / 255,
                    green: CGFloat((value >> 8) & 0xff) / 255,
                    blue: CGFloat(value & 0xff) / 255,
                    alpha: 1
                )
            } ?? UIColor.red
            colorCache.setObject(color, forKey: hex as NSString)
            return color
        }
    }

    enum Fonts {
        private static let cache = NSCache<NSString, UIFont>()

        static func font(_ family: FontKey, size: CGFloat, bold: Bool, italic: Bool) -> UIFont {
            let key = "\(family.rawValue):\(size):\(bold):\(italic)" as NSString
            if let cached = cache.object(forKey: key) { return cached }

            let base: UIFont
            switch family {
            case .sans:
                base = .systemFont(ofSize: size)
            case .serif:
                if let descriptor = UIFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif) {
                    base = UIFont(descriptor: descriptor, size: size)
                } else {
                    base = UIFont(name: "TimesNewRomanPSMT", size: size) ?? .systemFont(ofSize: size)
                }
            case .mono:
                base = UIFont(name: "Menlo-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
            case .georgia:
                base = UIFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
            case .impact:
                // iOS does not ship Impact; a heavy condensed system face stands in.
                base = UIFont(name: "Impact", size: size) ?? .systemFont(ofSize: size, weight: .black, width: .condensed)
            }

            var traits = base.fontDescriptor.symbolicTraits
            if bold { traits.insert(.traitBold) }
            if italic { traits.insert(.traitItalic) }

            var font = base
            if traits != base.fontDescriptor.symbolicTraits,
               let descriptor = base.fontDescriptor.withSymbolicTraits(traits) {
                font = UIFont(descriptor: descriptor, size: size)
            }

            cache.setObject(font, forKey: key)
            return font
        }
    }
}
