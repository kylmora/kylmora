import AppKit

/// A choice, drawn by us and opened by AppKit.
///
/// Everything you see is ours: the plate, the type, the hover, the marker at
/// the trailing edge in the pane's own colour. Nothing of the grey system bezel
/// survives -- and that bezel is the single most recognisably Apple thing on a
/// form.
///
/// What happens on the click is not ours at all. The `NSPopUpButton` the pane
/// built is still here, laid over the whole plate and made transparent: it
/// draws nothing, and it takes the click and puts up the real menu, with the
/// real keyboard handling, the real scrolling for a long list, and the pane's
/// own target and action on the other side of it. There is no menu code here to
/// get wrong, and no pane had to change for any of this.
@MainActor
final class SettingsChoiceControl: SettingsPlateView {
    static let height: CGFloat = 30

    /// The pane's hue, worn by the marker.
    var tint: NSColor? {
        didSet {
            guard tint != oldValue else { return }
            marker.fill = tint ?? .controlAccentColor
        }
    }

    private let popUp: NSPopUpButton
    private var visibility: NSKeyValueObservation?
    private let label = NSTextField(labelWithString: "")
    private let marker = SettingsPlateView()
    private let chevron = NSImageView()
    /// The selection as of the last sync, so a pane's `reload` is noticed
    /// without rebuilding anything on every pass.
    private var shownIndex = -1
    private var shownTitle: String?

    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            // Chosen on the event, never inside `updateLayer`: assigning a
            // colour while drawing marks the view dirty and schedules the next
            // draw, and the window pegs a core instead of appearing.
            fill = isHovered ? Style.Colors.settingsControlHover : Style.Colors.settingsControl
        }
    }
    private var trackingArea: NSTrackingArea?

    init(popUp: NSPopUpButton) {
        self.popUp = popUp
        super.init(frame: .zero)
        cornerRadius = 9
        fill = Style.Colors.settingsControl
        stroke = Style.Colors.settingsControlStroke

        label.font = Style.Fonts.settingsRow
        label.textColor = Style.Colors.primaryText
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        marker.cornerRadius = 6
        marker.fill = .controlAccentColor
        addSubview(marker)

        chevron.image = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: nil
        )
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        chevron.contentTintColor = .white
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.setAccessibilityElement(false)
        addSubview(chevron)

        // Over everything, drawing nothing. A transparent button still tracks
        // the mouse and still puts up its menu, which is the whole point: the
        // dropdown is AppKit's, the dropdown's clothes are ours.
        popUp.isTransparent = true
        popUp.translatesAutoresizingMaskIntoConstraints = false
        addSubview(popUp)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: marker.leadingAnchor, constant: -8),
            marker.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            marker.centerYAnchor.constraint(equalTo: centerYAnchor),
            marker.widthAnchor.constraint(equalToConstant: 20),
            marker.heightAnchor.constraint(equalToConstant: 20),
            chevron.centerXAnchor.constraint(equalTo: marker.centerXAnchor),
            chevron.centerYAnchor.constraint(equalTo: marker.centerYAnchor),
            popUp.leadingAnchor.constraint(equalTo: leadingAnchor),
            popUp.trailingAnchor.constraint(equalTo: trailingAnchor),
            popUp.topAnchor.constraint(equalTo: topAnchor),
            popUp.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(popUp.accessibilityLabel() ?? "")
        visibility = follows(popUp)
        sync()
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsChoiceControl is created in code only")
    }

    /// Follows the pop-up, which every pane sets directly in its `reload`.
    ///
    /// Polled rather than observed: `NSPopUpButton` is not KVO-compliant for
    /// its selection -- `selectItem(at:)` posts nothing -- so there is no
    /// notification to hang this on. It is a comparison per draw.
    private func sync() {
        let index = popUp.indexOfSelectedItem
        let title = popUp.titleOfSelectedItem
        guard index != shownIndex || title != shownTitle else { return }
        shownIndex = index
        shownTitle = title
        label.stringValue = title ?? ""
        setAccessibilityValue(title ?? "")
    }

    override func viewWillDraw() {
        sync()
        let enabled = popUp.isEnabled
        label.textColor = enabled ? Style.Colors.primaryText : Style.Colors.secondaryText
        marker.alphaValue = enabled ? 1 : 0.4
        super.viewWillDraw()
    }

    /// Wide enough for the longest option, so picking a different one never
    /// resizes the row or truncates what it says.
    override var intrinsicContentSize: NSSize {
        let font = Style.Fonts.settingsRow
        let widest = popUp.itemTitles.reduce(CGFloat(0)) { widest, title in
            max(widest, (title as NSString).size(withAttributes: [.font: font]).width)
        }
        return NSSize(width: ceil(widest) + 11 + 8 + 20 + 5, height: Self.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}


/// A run of choices shown at once, drawn by us over AppKit's segmented control.
///
/// Where a dropdown hides its options behind a click, a segmented control's
/// whole point is that you can see them, so this one keeps that and sheds the
/// system's pressed-metal look. The `NSSegmentedControl` the pane built stays
/// as the model -- it holds the selection and carries the pane's action -- and
/// nothing of it is drawn.
@MainActor
final class SettingsSegments: NSView {
    /// The pane's hue, which fills the chosen segment.
    var tint: NSColor? {
        didSet {
            guard tint != oldValue else { return }
            for pill in pills { pill.tint = tint }
        }
    }

    private let segmented: NSSegmentedControl
    private var visibility: NSKeyValueObservation?
    private var pills: [Pill] = []
    private var shown = -1

    init(segmented: NSSegmentedControl) {
        self.segmented = segmented
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        for index in 0..<segmented.segmentCount {
            let pill = Pill(title: segmented.label(forSegment: index) ?? "") { [weak self] in
                self?.choose(index)
            }
            pills.append(pill)
            row.addArrangedSubview(pill)
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // The model, kept alive and off screen -- without `isHidden`, which
        // stays the pane's own signal for whether this setting is showing.
        segmented.alphaValue = 0
        segmented.frame = .zero
        addSubview(segmented, positioned: .below, relativeTo: nil)
        visibility = follows(segmented)
        setAccessibilityRole(.radioGroup)
        sync()
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsSegments is created in code only")
    }

    private func choose(_ index: Int) {
        guard index != segmented.selectedSegment else { return }
        segmented.selectedSegment = index
        sync()
        // Sent by hand: the pane is listening to the segmented control, not us.
        if let action = segmented.action {
            NSApp.sendAction(action, to: segmented.target, from: segmented)
        }
    }

    /// Follows the model, which a pane sets directly in its `reload`. Polled
    /// for the same reason the dropdown polls: there is no notification.
    private func sync() {
        let index = segmented.selectedSegment
        let enabled = segmented.isEnabled
        guard index != shown || enabled != (pills.first?.isEnabled ?? enabled) else { return }
        shown = index
        for (position, pill) in pills.enumerated() {
            pill.isChosen = position == index
            pill.isEnabled = enabled
        }
    }

    override func viewWillDraw() {
        sync()
        super.viewWillDraw()
    }

    private final class Pill: NSView {
        static let height: CGFloat = 26

        var isChosen = false { didSet { if isChosen != oldValue { needsDisplay = true } } }
        var isEnabled = true { didSet { if isEnabled != oldValue { needsDisplay = true } } }
        var tint: NSColor? { didSet { if tint != oldValue { needsDisplay = true } } }

        private let title: String
        private let onClick: () -> Void
        private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
        private var trackingArea: NSTrackingArea?

        init(title: String, onClick: @escaping () -> Void) {
            self.title = title
            self.onClick = onClick
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            setAccessibilityRole(.radioButton)
            setAccessibilityLabel(title)
        }

        required init?(coder: NSCoder) {
            fatalError("Pill is created in code only")
        }

        private var font: NSFont { .systemFont(ofSize: 12, weight: isChosen ? .semibold : .regular) }

        override var intrinsicContentSize: NSSize {
            let bold = NSFont.systemFont(ofSize: 12, weight: .semibold)
            let width = (title as NSString).size(withAttributes: [.font: bold]).width
            return NSSize(width: ceil(width) + 22, height: Self.height)
        }

        override func draw(_ dirtyRect: NSRect) {
            let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rest = isDark
                ? NSColor(white: 1, alpha: isHovered ? 0.12 : 0.06)
                : NSColor(white: 0, alpha: isHovered ? 0.10 : 0.05)
            let fill = isChosen ? (tint ?? settingsAccent ?? .controlAccentColor) : rest
            (isEnabled ? fill : fill.withAlphaComponent(0.4)).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()

            let colour: NSColor = isChosen
                ? .white
                : (isDark ? NSColor(white: 1, alpha: 0.75) : NSColor(white: 0, alpha: 0.72))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: isEnabled ? colour : colour.withAlphaComponent(0.5)
            ]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(
                at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                withAttributes: attributes
            )
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) { isHovered = true }
        override func mouseExited(with event: NSEvent) { isHovered = false }

        override func mouseUp(with event: NSEvent) {
            guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            onClick()
        }

        override func accessibilityPerformPress() -> Bool {
            guard isEnabled else { return false }
            onClick()
            return true
        }
    }
}
