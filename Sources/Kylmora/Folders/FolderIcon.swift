import AppKit

/// What a folder draws in its 28-point icon well.
///
/// Three cases rather than an optional emoji because the three have genuinely
/// different rendering: an emoji is glyph art the system already colours, a
/// symbol is a template tinted by the folder, and the automatic case is a drawn
/// squircle that must exist so a folder the user never decorated still reads as
/// a folder rather than as a gap.
enum FolderIcon: Equatable, Sendable {
    /// The drawn folder squircle, tinted by the folder's own colour.
    case automatic
    case emoji(String)
    /// An SF Symbol name. Unresolvable names fall back to `automatic` at draw
    /// time rather than at assignment, so a symbol that disappears in a future
    /// macOS degrades instead of being silently rewritten in the session file.
    case symbol(String)
}

extension FolderIcon {
    /// The folder icon is 28 points square with the glyph nudged up and left
    /// by a point; both numbers are reproduced here rather than being
    /// approximated by an image view's own centring.
    static let side: CGFloat = 28
    private static let glyphOffset = CGSize(width: -1, height: -1)

    /// The image for an icon well of `side` points.
    ///
    /// Drawn per call rather than cached: the colours are semantic and must be
    /// re-resolved whenever the appearance changes, and a folder header is
    /// configured once per sidebar rebuild, not per frame.
    @MainActor
    func image(tint: NSColor) -> NSImage {
        switch self {
        case .emoji(let text) where !text.isEmpty:
            return Self.glyphImage(text, font: .systemFont(ofSize: 17))
        case .symbol(let name):
            if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                return Self.templateImage(symbol, tint: tint)
            }
            return Self.squircle(tint: tint)
        case .emoji, .automatic:
            return Self.squircle(tint: tint)
        }
    }

    /// The plate behind the glyph layers a skewed "back" rectangle behind a
    /// "front" one so a folder reads as a folder at 28 points, where a
    /// literal manila-folder outline would just be mud.
    @MainActor
    private static func squircle(tint: NSColor) -> NSImage {
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size, flipped: false) { _ in
            let base = tint.usingColorSpace(.sRGB) ?? tint
            let back = base.blended(withFraction: 0.4, of: .gray) ?? base
            let front = base.blended(withFraction: 0.55, of: .white) ?? base

            let backRect = NSRect(x: 5, y: 8, width: side - 10, height: side - 15)
            back.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: backRect, xRadius: 3, yRadius: 3).fill()

            let frontRect = NSRect(x: 3, y: 5, width: side - 6, height: side - 13)
            front.setFill()
            NSBezierPath(roundedRect: frontRect, xRadius: 4, yRadius: 4).fill()

            base.withAlphaComponent(0.35).setStroke()
            let stroke = NSBezierPath(roundedRect: frontRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            stroke.lineWidth = 1
            stroke.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    @MainActor
    private static func templateImage(_ symbol: NSImage, tint: NSColor) -> NSImage {
        let configured = symbol.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        ) ?? symbol
        let size = NSSize(width: side, height: side)
        return NSImage(size: size, flipped: false) { _ in
            tint.setFill()
            let box = NSRect(
                x: (side - configured.size.width) / 2 + glyphOffset.width,
                y: (side - configured.size.height) / 2 + glyphOffset.height,
                width: configured.size.width,
                height: configured.size.height
            )
            configured.draw(in: box)
            box.fill(using: .sourceAtop)
            return true
        }
    }

    @MainActor
    private static func glyphImage(_ text: String, font: NSFont) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let measured = (text as NSString).size(withAttributes: attributes)
        let size = NSSize(width: side, height: side)
        return NSImage(size: size, flipped: false) { _ in
            let origin = NSPoint(
                x: (side - measured.width) / 2 + glyphOffset.width,
                y: (side - measured.height) / 2 + glyphOffset.height
            )
            (text as NSString).draw(at: origin, withAttributes: attributes)
            return true
        }
    }
}
