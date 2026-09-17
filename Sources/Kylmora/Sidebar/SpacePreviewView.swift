import AppKit

/// What the New Space sheet is about to make, drawn.
///
/// Everything the sheet can change, in the order the window applies it: the
/// appearance decides the material, the fill lays a wash of the space's colour
/// over it, and transparency decides how much of that wash survives.
struct SpacePreviewLook: Equatable {
    /// Light, dark, or whatever the General pane says.
    var appearance: AppearancePreference = .system
    /// The space's own colour, or nil for a space that has none: a plain
    /// window, or one that waits for a page to colour it.
    var wash: SpaceWashChoice?
    /// How much of that colour reaches the chrome, 0...1.
    var washOpacity: Double = 1
    /// The space defers to the page in front. There is no page yet, so the
    /// preview says so rather than inventing a colour for one.
    var followsPageColour = false
    var title = "New Space"
    var tab = "New Tab"
}

/// A miniature of the sidebar, in the space's own colours.
///
/// The sheet used to show `ThemePreview`, which is the tab group editor's card:
/// it draws a fill and nothing else, so choosing Light, Dark or Website changed
/// the whole window and not one pixel of the preview, and the transparency
/// slider moved nothing at all. A preview that does not answer the controls
/// beside it is worse than no preview: it is a picture of a different decision.
///
/// This draws the same three steps the window does, in the same order, so what
/// is on the card is what will be on screen.
@MainActor
final class SpacePreviewView: NSView {
    var look = SpacePreviewLook() {
        didSet { if look != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Preview")
    }

    required init?(coder: NSCoder) {
        fatalError("SpacePreviewView is created in code only")
    }

    /// The appearance this space will wear. Automatic, Customized and Website
    /// all follow the system, which here is whatever the sheet is wearing.
    private var drawingAppearance: NSAppearance {
        switch look.appearance {
        case .light: NSAppearance(named: .aqua) ?? effectiveAppearance
        case .dark: NSAppearance(named: .darkAqua) ?? effectiveAppearance
        case .system: effectiveAppearance
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Style.Metrics.folderPlateCornerRadius
        let plate = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

        // Drawn as the space's appearance, not as the sheet's: every colour
        // below is a dynamic one, and this is what makes Light draw light while
        // the sheet around it stays dark.
        drawingAppearance.performAsCurrentDrawingAppearance {
            let isDark = drawingAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

            // 1. The material. What a plain window is before a space tints it.
            (isDark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.96, alpha: 1)).setFill()
            path.fill()

            // 2. The wash, at the strength transparency left it.
            if let wash = look.wash {
                drawWash(wash, in: path, opacity: CGFloat(look.washOpacity), isDark: isDark)
            }

            // 3. The rows, in whatever reads against what is now underneath.
            let ink = textColour(isDark: isDark)
            drawRow(y: plate.minY + 20, text: look.title, filledDot: true, colour: ink, weight: .semibold)
            drawRow(
                y: plate.minY + 48, text: look.tab, filledDot: false,
                colour: ink.withAlphaComponent(0.7), weight: .regular
            )

            if look.followsPageColour {
                drawPageNote(in: plate, colour: ink.withAlphaComponent(0.55))
            }

            // A hairline, so the card has an edge of its own whatever it holds.
            (isDark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.10)).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// The space's colour over the material, exactly as `SpaceTheme.wash` and
    /// the window's tint view do it: a low alpha, a little stronger in dark.
    private func drawWash(
        _ wash: SpaceWashChoice, in path: NSBezierPath, opacity: CGFloat, isDark: Bool
    ) {
        let strength = (isDark ? 0.20 : 0.15) * max(0, min(1, opacity))
        switch wash {
        case .solid(let colour):
            colour.withAlphaComponent(strength).setFill()
            path.fill()
        case .gradient(let gradient):
            let start = NSColor(hexString: gradient.startHex) ?? .controlAccentColor
            let end = NSColor(hexString: gradient.endHex) ?? start
            NSGradient(
                starting: start.withAlphaComponent(strength),
                ending: end.withAlphaComponent(strength)
            )?.draw(in: path, angle: gradient.direction.angle)
        }
    }

    /// White or near-black, whichever reads over what has been drawn so far.
    ///
    /// Taken from the material rather than from the wash: the wash is a veil at
    /// fifteen or twenty per cent, so what decides legibility is what is under
    /// it.
    private func textColour(isDark: Bool) -> NSColor {
        isDark ? NSColor(white: 1, alpha: 0.95) : NSColor(white: 0.1, alpha: 0.9)
    }

    private func drawRow(
        y: CGFloat, text: String, filledDot: Bool, colour: NSColor, weight: NSFont.Weight
    ) {
        let x: CGFloat = 18
        let dot = NSRect(x: x, y: y - 5, width: 10, height: 10)
        colour.setFill()
        if filledDot {
            NSBezierPath(ovalIn: dot).fill()
        } else {
            let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            colour.setStroke()
            ring.stroke()
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let drawn = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: weight),
            .foregroundColor: colour,
            .paragraphStyle: paragraph
        ])
        let height = drawn.size().height
        drawn.draw(in: NSRect(
            x: x + 18, y: y - height / 2,
            width: max(0, bounds.width - (x + 18) - 18), height: height
        ))
    }

    /// Website has no colour of its own: it borrows whichever page is in front,
    /// and there is no page yet. Said in words rather than guessed at with a
    /// colour the space may never wear.
    private func drawPageNote(in plate: NSRect, colour: NSColor) {
        let note = NSAttributedString(string: "Takes the colour of the page in front", attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: colour
        ])
        note.draw(at: NSPoint(x: 18, y: plate.maxY - 24))
    }
}
