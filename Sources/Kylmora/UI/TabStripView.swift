import AppKit

/// A horizontal row of the active space's tabs above the page, for people who
/// want their tabs where every other browser puts them. The sidebar stays
/// the model; this is another view of the same list.
@MainActor
final class TabStripView: NSView {
    static let height: CGFloat = 34
    private static let cellWidth: CGFloat = 180
    private static let cellSpacing: CGFloat = 4
    private static let inset: CGFloat = 8

    var onSelect: ((Tab) -> Void)?
    var onClose: ((Tab) -> Void)?
    var onNewTab: (() -> Void)?
    /// A cell was dragged from one position to another. `to` is a
    /// pre-removal insertion index, the way a table drop reports one.
    var onReorder: ((Int, Int) -> Void)?

    /// The line drawn at the gap a dragged cell would land in.
    private let dropIndicator = NSView()

    private let scroll = NSScrollView()
    private let row = NSStackView()
    private let newTabButton = IconButton(symbolName: "plus", label: "New Tab")
    private(set) var cells: [TabStripCell] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Self.cellSpacing
        row.edgeInsets = NSEdgeInsets(top: 0, left: Self.inset, bottom: 0, right: Self.inset)
        row.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(row)
        scroll.documentView = document

        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        newTabButton.setClickHandler { [weak self] in self?.onNewTab?() }
        addSubview(newTabButton)

        dropIndicator.wantsLayer = true
        dropIndicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dropIndicator.layer?.cornerRadius = 1
        dropIndicator.isHidden = true
        addSubview(dropIndicator)

        let hairline = NSBox()
        hairline.boxType = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: newTabButton.leadingAnchor, constant: -4),
            newTabButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            newTabButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.topAnchor.constraint(equalTo: document.topAnchor),
            row.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.heightAnchor.constraint(equalTo: scroll.heightAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Tab bar")
    }

    required init?(coder: NSCoder) {
        fatalError("TabStripView is created in code only")
    }

    /// The tabs the strip is currently showing, so the next fill can tell an
    /// arrival from a redraw.
    private var shownIDs: Set<UUID> = []

    /// Rebuilds the cells. Tens of tabs, not thousands, so cheap enough on
    /// every change.
    func show(_ tabs: [Tab], activeID: UUID?, isPrivate: Bool) {
        // Which tabs are genuinely new, worked out before the cells are thrown
        // away. Every cell is rebuilt on every change, so without this a tab
        // that merely changed its title would spring in beside one that was
        // actually just opened, and the movement would stop meaning anything.
        //
        // Nothing arrives on a first fill, and nothing arrives when the strip
        // and its previous contents have no tab at all in common: that is a
        // different space's list rather than this one's list changing, and
        // animating it sends every cell across the strip at once. A space
        // switch has its own transition and does not want this one on top.
        let ids = Set(tabs.map(\.id))
        let arrived = ids.isDisjoint(with: shownIDs) ? [] : ids.subtracting(shownIDs)
        shownIDs = ids

        for cell in cells { cell.removeFromSuperview() }
        cells = tabs.map { tab in
            let cell = TabStripCell(tab: tab, isPrivate: isPrivate)
            cell.isActive = tab.id == activeID
            cell.onSelect = { [weak self] in self?.onSelect?(tab) }
            cell.onClose = { [weak self] in self?.onClose?(tab) }
            cell.onDrag = { [weak self, weak cell] point in
                guard let self, let cell else { return }
                self.showDropIndicator(at: self.dropIndex(forPointerX: self.convert(point, from: cell).x))
            }
            cell.onDrop = { [weak self, weak cell] point in
                guard let self, let cell else { return }
                self.dropIndicator.isHidden = true
                guard let from = self.cells.firstIndex(where: { $0 === cell }) else { return }
                let to = self.dropIndex(forPointerX: self.convert(point, from: cell).x)
                guard to != from, to != from + 1 else { return }
                self.onReorder?(from, to)
            }
            row.addArrangedSubview(cell)
            cell.widthAnchor.constraint(equalToConstant: Self.cellWidth).isActive = true
            cell.heightAnchor.constraint(equalToConstant: Self.height - 8).isActive = true
            if arrived.contains(tab.id) {
                // In from the leading edge, the same direction the sidebar's
                // rows arrive from, so the two lists agree about which way a
                // new tab comes from.
                SpringPresence.slideIn(
                    cell, from: CGVector(dx: -Style.Motion.entrySlide, dy: 0), fading: true
                )
            }
            return cell
        }
        if let active = cells.first(where: \.isActive) {
            DispatchQueue.main.async { [weak self] in self?.scrollToVisible(active) }
        }
    }

    private func scrollToVisible(_ cell: NSView) {
        guard let document = scroll.documentView else { return }
        document.layoutSubtreeIfNeeded()
        let frame = cell.convert(cell.bounds, to: document)
        document.scrollToVisible(frame.insetBy(dx: -Self.cellSpacing * 2, dy: 0))
    }

    /// Where a pointer at `x` (in the strip's coordinates) would drop: the
    /// number of cells whose midpoint lies to its left.
    func dropIndex(forPointerX x: CGFloat) -> Int {
        let midpoints = cells.map { cell -> CGFloat in
            let frame = convert(cell.bounds, from: cell)
            return frame.midX
        }
        return Self.dropIndex(pointerX: x, midpoints: midpoints)
    }

    static func dropIndex(pointerX x: CGFloat, midpoints: [CGFloat]) -> Int {
        midpoints.filter { $0 < x }.count
    }

    private func showDropIndicator(at index: Int) {
        guard !cells.isEmpty else { return }
        let x: CGFloat
        if index >= cells.count {
            x = convert(cells[cells.count - 1].bounds, from: cells[cells.count - 1]).maxX + Self.cellSpacing / 2
        } else {
            x = convert(cells[index].bounds, from: cells[index]).minX - Self.cellSpacing / 2
        }
        dropIndicator.frame = NSRect(x: x - 1, y: 5, width: 2, height: bounds.height - 10)
        dropIndicator.isHidden = false
    }

    /// Refreshes titles, favicons and state without rebuilding.
    func refresh(activeID: UUID?) {
        for cell in cells {
            cell.isActive = cell.tab.id == activeID
            cell.refresh()
        }
    }
}

/// One tab in the strip: favicon, title, and a close button that appears on
/// hover; a speaker when the tab is playing sound.
@MainActor
final class TabStripCell: NSView {
    let tab: Tab
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    /// The pointer moved while dragging the cell; the point is in the
    /// cell's coordinates.
    var onDrag: ((NSPoint) -> Void)?
    /// The drag ended at this point (cell coordinates).
    var onDrop: ((NSPoint) -> Void)?
    var isActive = false { didSet { updateLook() } }
    private var pressPoint: NSPoint?
    private var isDragging = false

    private let favicon = FaviconImageView()
    private let title = NSTextField(labelWithString: "")
    private let audio = NSImageView()
    private let emoji = NSTextField(labelWithString: "")
    private let close = IconButton(symbolName: "xmark", label: "Close Tab", side: 18)
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(tab: Tab, isPrivate: Bool) {
        self.tab = tab
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous

        favicon.translatesAutoresizingMaskIntoConstraints = false
        favicon.show(for: tab.displayURL, in: tab.currentWebView, isPrivate: isPrivate)
        emoji.font = .systemFont(ofSize: 13)
        emoji.alignment = .center
        emoji.translatesAutoresizingMaskIntoConstraints = false
        emoji.isHidden = true
        title.font = .systemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        audio.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Playing sound")
        audio.symbolConfiguration = .init(pointSize: 10, weight: .medium)
        audio.contentTintColor = .secondaryLabelColor
        audio.translatesAutoresizingMaskIntoConstraints = false
        close.translatesAutoresizingMaskIntoConstraints = false
        close.setClickHandler { [weak self] in self?.onClose?() }
        close.isHidden = true
        for view in [favicon, title, audio, close, emoji] { addSubview(view) }

        NSLayoutConstraint.activate([
            favicon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            favicon.centerYAnchor.constraint(equalTo: centerYAnchor),
            favicon.widthAnchor.constraint(equalToConstant: 16),
            favicon.heightAnchor.constraint(equalToConstant: 16),
            emoji.centerXAnchor.constraint(equalTo: favicon.centerXAnchor),
            emoji.centerYAnchor.constraint(equalTo: favicon.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: favicon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: audio.leadingAnchor, constant: -4),
            audio.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -2),
            audio.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            close.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        toolTip = tab.displayURL.absoluteString
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("TabStripCell is created in code only")
    }

    func refresh() {
        title.stringValue = tab.displayTitle
        emoji.stringValue = tab.emoji ?? ""
        emoji.isHidden = tab.emoji == nil
        favicon.isHidden = tab.emoji != nil
        audio.isHidden = !tab.isPlayingAudio
        setAccessibilityLabel(tab.displayTitle)
        updateLook()
    }

    private func updateLook() {
        let selected = NSColor.controlAccentColor.withAlphaComponent(0.16)
        let hover = NSColor.labelColor.withAlphaComponent(0.06)
        layer?.backgroundColor = isActive ? selected.cgColor : (hovering ? hover.cgColor : NSColor.clear.cgColor)
        title.textColor = isActive ? .labelColor : .secondaryLabelColor
        title.font = .systemFont(ofSize: 12, weight: isActive ? .medium : .regular)
        close.isHidden = !(hovering || isActive)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; updateLook() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateLook() }

    /// The squeeze the tab gives under a click. See `SpringPress`.
    private lazy var press = SpringPress(view: self)

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { return }
        pressPoint = convert(event.locationInWindow, from: nil)
        isDragging = false
        if acceptsSpringPress { press.down() }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let pressPoint else { return }
        if !isDragging, abs(point.x - pressPoint.x) < 4 { return }
        isDragging = true
        onDrag?(point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { pressPoint = nil; isDragging = false }
        guard pressPoint != nil else {
            press.cancel()
            return
        }
        if isDragging {
            // A tab that was dragged into a new position has not been clicked,
            // and springing would say it had.
            press.cancel()
            onDrop?(point)
        } else {
            press.up()
            onSelect?()
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        // Middle click closes, like everywhere else.
        if event.buttonNumber == 2 { onClose?() }
    }
}
