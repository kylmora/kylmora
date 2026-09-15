import AppKit

/// Visual match indicator tick marks along the vertical scrollbar rail.
///
/// Each match found in the page is mapped to a normalized vertical position
/// (0.0 at page top, 1.0 at page bottom) and rendered as a crisp tick mark.
/// Clicking anywhere on the ruler jumps directly to the nearest match.
final class FindScrollbarMarksView: NSView {
    var onSelectRatio: ((Double) -> Void)?

    private(set) var positions: [Double] = []
    private(set) var activeIndex: Int = 0 // 1-based

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.ruler)
        setAccessibilityLabel("Search match highlights in scrollbar")
    }

    required init?(coder: NSCoder) {
        fatalError("FindScrollbarMarksView is created in code only")
    }

    func update(positions: [Double], activeIndex: Int) {
        self.positions = positions
        self.activeIndex = activeIndex
        self.isHidden = positions.isEmpty
        self.needsDisplay = true
    }

    func clear() {
        self.positions = []
        self.activeIndex = 0
        self.isHidden = true
        self.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !positions.isEmpty else { return }

        let h = bounds.height
        let w = bounds.width

        // Draw rail background indicator when active matches exist
        let railRect = NSRect(x: w - 4, y: 0, width: 3, height: h)
        let railPath = NSBezierPath(roundedRect: railRect, xRadius: 1.5, yRadius: 1.5)
        NSColor.separatorColor.withAlphaComponent(0.3).setFill()
        railPath.fill()

        for (i, pos) in positions.enumerated() {
            let isActive = (i + 1) == activeIndex
            // AppKit coordinates origin is bottom-left; pos is 0.0 (top) to 1.0 (bottom)
            let y = h * CGFloat(1.0 - pos)
            let markHeight: CGFloat = isActive ? 5 : 3
            let markWidth: CGFloat = isActive ? max(6, w - 2) : max(4, w - 4)
            let x: CGFloat = isActive ? 1 : 2
            let markRect = NSRect(
                x: x,
                y: max(1, min(h - markHeight - 1, y - markHeight / 2)),
                width: markWidth,
                height: markHeight
            )

            let path = NSBezierPath(roundedRect: markRect, xRadius: 1.5, yRadius: 1.5)
            if isActive {
                NSColor.systemOrange.setFill()
                path.fill()
                NSColor.white.withAlphaComponent(0.85).setStroke()
                path.lineWidth = 0.75
                path.stroke()
            } else {
                NSColor.systemYellow.withAlphaComponent(0.85).setFill()
                path.fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !positions.isEmpty, bounds.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let ratio = Double(1.0 - (point.y / bounds.height))
        onSelectRatio?(max(0.0, min(1.0, ratio)))
    }
}
