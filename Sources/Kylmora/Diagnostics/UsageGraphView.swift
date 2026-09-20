import AppKit

/// A history drawn as a line, filled underneath.
///
/// Drawn rather than built from anything: sixty points at a two-second cadence
/// is a path and a gradient, and a charting framework for that would be more
/// code than the drawing is, in a window that is already asking the machine to
/// do work while it measures how much work the machine is doing.
@MainActor
final class UsageGraphView: NSView {
    /// The colour of the line, and -- faded -- of what is under it.
    var tint: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }

    /// What the top of the card means, so an idle graph does not scale its own
    /// noise to full height. See `UsageGraph.ceiling(forPeak:floor:)`.
    var floorCeiling: Double = 100

    private var history = UsageHistory()

    func show(_ history: UsageHistory) {
        self.history = history
        needsDisplay = true
    }

    /// The top of the graph as it is currently drawn, so the card above can
    /// label it. Taken from the same call the drawing uses, so the number and
    /// the line can never disagree.
    var ceiling: Double {
        UsageGraph.ceiling(forPeak: history.peak, floor: floorCeiling)
    }

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let plot = bounds.insetBy(dx: 0, dy: 1)
        guard plot.width > 0, plot.height > 0 else { return }

        // Three lines: the top, the middle and the floor. Enough to read a
        // height off the card without the graph turning into graph paper.
        Style.Colors.graphGrid.setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = Style.Metrics.hairline
        for fraction in [0.0, 0.5, 1.0] {
            let y = (plot.minY + plot.height * fraction).rounded() + 0.25
            grid.move(to: NSPoint(x: plot.minX, y: y))
            grid.line(to: NSPoint(x: plot.maxX, y: y))
        }
        grid.stroke()

        let points = UsageGraph.points(for: history.samples, in: plot, ceiling: ceiling)
        guard let first = points.first, let last = points.last else { return }

        // The fill is the line closed down to the baseline. Its gradient fades
        // out towards the bottom so two cards stacked in one window do not read
        // as two solid blocks of colour.
        let area = NSBezierPath()
        area.move(to: NSPoint(x: first.x, y: plot.minY))
        for point in points { area.line(to: point) }
        area.line(to: NSPoint(x: last.x, y: plot.minY))
        area.close()

        NSGraphicsContext.saveGraphicsState()
        area.addClip()
        NSGradient(
            colors: [tint.withAlphaComponent(0.34), tint.withAlphaComponent(0.02)]
        )?.draw(in: plot, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        let line = NSBezierPath()
        line.move(to: first)
        for point in points.dropFirst() { line.line(to: point) }
        line.lineWidth = 1.5
        line.lineJoinStyle = .round
        tint.setStroke()
        line.stroke()

        // A dot on the newest reading: with a two-second cadence the line's
        // leading edge is where the eye goes, and a bare end looks like the
        // graph stopped rather than like it is still being drawn.
        let dot = NSRect(x: last.x - 2, y: last.y - 2, width: 4, height: 4)
        tint.setFill()
        NSBezierPath(ovalIn: dot).fill()
    }
}

/// The same line, thumbnail-sized, for a row in the table.
///
/// No fill, no grid, no dot: at eighteen points tall those read as smudges. All
/// this has to say is whether a tab has been busy the whole time you have been
/// looking at it or just spiked once.
@MainActor
final class SparklineView: NSView {
    private var history = UsageHistory()
    private var ceiling: Double = 100
    private var tint: NSColor = .secondaryLabelColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("SparklineView is created in code only")
    }

    func show(_ history: UsageHistory, ceiling: Double, tint: NSColor) {
        self.history = history
        self.ceiling = ceiling
        self.tint = tint
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let plot = bounds.insetBy(dx: 1, dy: 3)
        let points = UsageGraph.points(for: history.samples, in: plot, ceiling: ceiling)
        guard let first = points.first else { return }
        let line = NSBezierPath()
        line.move(to: first)
        for point in points.dropFirst() { line.line(to: point) }
        line.lineWidth = 1
        line.lineJoinStyle = .round
        tint.setStroke()
        line.stroke()
    }
}
