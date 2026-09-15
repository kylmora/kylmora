import AppKit

/// The colours the annotation tools offer.
enum AnnotationColor: String, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, black, white

    var nsColor: NSColor {
        switch self {
        case .red: return NSColor(srgbRed: 0.95, green: 0.23, blue: 0.19, alpha: 1)
        case .orange: return .systemOrange
        case .yellow: return NSColor(srgbRed: 1, green: 0.84, blue: 0.1, alpha: 1)
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .black: return .black
        case .white: return .white
        }
    }

    var title: String { rawValue.capitalized }
}

/// One mark on a screenshot, in image points with the origin at the bottom
/// left, the way AppKit draws.
enum Annotation: Equatable, Sendable {
    case arrow(from: CGPoint, to: CGPoint, color: AnnotationColor, width: CGFloat)
    case rectangle(CGRect, color: AnnotationColor, width: CGFloat)
    case ellipse(CGRect, color: AnnotationColor, width: CGFloat)
    case highlight(CGRect, color: AnnotationColor)
    case blur(CGRect)
    case text(String, at: CGPoint, color: AnnotationColor, size: CGFloat)
}

/// A screenshot with its marks and, optionally, a crop. `render()` is the
/// only way the marks become pixels, so what is saved, copied and shown on
/// the canvas is always the same picture.
struct AnnotatedScreenshot {
    let image: NSImage
    var annotations: [Annotation] = []
    var crop: CGRect?

    init(image: NSImage) {
        self.image = image
    }

    var size: NSSize { image.size }

    /// Draws the marks onto a copy of the image, then crops if asked.
    func render() -> NSImage {
        let full = NSImage(size: image.size)
        full.lockFocusFlipped(false)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        for annotation in annotations { draw(annotation) }
        full.unlockFocus()

        guard let crop, crop.width >= 1, crop.height >= 1 else { return full }
        let bounded = crop.intersection(NSRect(origin: .zero, size: image.size))
        guard !bounded.isEmpty else { return full }
        let cropped = NSImage(size: bounded.size)
        cropped.lockFocusFlipped(false)
        full.draw(in: NSRect(origin: .zero, size: bounded.size), from: bounded, operation: .copy, fraction: 1)
        cropped.unlockFocus()
        return cropped
    }

    private func draw(_ annotation: Annotation) {
        switch annotation {
        case .arrow(let from, let to, let color, let width):
            color.nsColor.setStroke()
            color.nsColor.setFill()
            let line = NSBezierPath()
            line.lineWidth = width
            line.lineCapStyle = .round
            line.move(to: from)
            line.line(to: to)
            line.stroke()
            // The head: two short strokes back from the tip.
            let angle = atan2(to.y - from.y, to.x - from.x)
            let headLength = max(12, width * 4)
            let head = NSBezierPath()
            head.move(to: to)
            head.line(to: CGPoint(x: to.x - headLength * cos(angle - .pi / 6), y: to.y - headLength * sin(angle - .pi / 6)))
            head.line(to: CGPoint(x: to.x - headLength * cos(angle + .pi / 6), y: to.y - headLength * sin(angle + .pi / 6)))
            head.close()
            head.fill()
        case .rectangle(let rect, let color, let width):
            color.nsColor.setStroke()
            let path = NSBezierPath(roundedRect: rect.standardized, xRadius: 2, yRadius: 2)
            path.lineWidth = width
            path.stroke()
        case .ellipse(let rect, let color, let width):
            color.nsColor.setStroke()
            let path = NSBezierPath(ovalIn: rect.standardized)
            path.lineWidth = width
            path.stroke()
        case .highlight(let rect, let color):
            color.nsColor.withAlphaComponent(0.35).setFill()
            rect.standardized.fill(using: .sourceOver)
        case .blur(let rect):
            pixelate(rect.standardized)
        case .text(let string, let point, let color, let size):
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: color.nsColor,
                .strokeColor: color == .white ? NSColor.black : NSColor.white,
                .strokeWidth: -3
            ]
            NSAttributedString(string: string, attributes: attributes).draw(at: point)
        }
    }

    /// Blur that cannot be undone by a viewer: the region is drawn at a
    /// twelfth of its size and back up with no smoothing, so the pixels that
    /// were there are gone from the output.
    private func pixelate(_ rect: CGRect) {
        let bounded = rect.intersection(NSRect(origin: .zero, size: image.size))
        guard bounded.width >= 2, bounded.height >= 2 else { return }
        let factor: CGFloat = 12
        let small = NSImage(size: NSSize(width: max(1, bounded.width / factor), height: max(1, bounded.height / factor)))
        small.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: small.size), from: bounded, operation: .copy, fraction: 1)
        small.unlockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        small.draw(in: bounded, from: NSRect(origin: .zero, size: small.size), operation: .sourceOver, fraction: 1)
        NSGraphicsContext.current?.imageInterpolation = .default
    }

    /// The colour of one pixel of the rendered picture, for tests.
    static func pixel(of image: NSImage, at point: CGPoint) -> NSColor? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        let scaleX = CGFloat(bitmap.pixelsWide) / image.size.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / image.size.height
        let x = Int(point.x * scaleX)
        let y = bitmap.pixelsHigh - 1 - Int(point.y * scaleY)
        guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh else { return nil }
        guard let color = bitmap.colorAt(x: x, y: y) else { return nil }
        // A wide-gamut backing store hands back colours sRGB cannot hold;
        // extended sRGB can, and is still comparable component by component.
        return color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.extendedSRGB) ?? color
    }
}
