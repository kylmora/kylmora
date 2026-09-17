import AppKit

/// The settings window's search box.
///
/// An `NSSearchField` was doing this job, and it was the one piece of stock
/// AppKit chrome left in the window. That is why it looked wrong rather than
/// merely plain: its bezel is drawn by the system at a radius and a grey of the
/// system's choosing, so it sat in a column of custom pills answering to none
/// of their measurements -- a rounded rectangle among rounded rectangles, all
/// of them slightly different.
///
/// This is the same plate every other field in the app draws (`AddressField`
/// draws it too), sized from the numbers the pane list below it already uses:
/// the same height and corner as a row's pill, the same inset from the column's
/// edge, and a glyph that sits exactly where the rows' coloured marks sit. The
/// result is that the placeholder and the pane names below it start on the same
/// vertical line, which is the thing the eye actually reads as tidy.
@MainActor
final class SettingsSearchField: NSView, NSTextFieldDelegate {

    /// Which set of measurements the field borrows.
    ///
    /// The field's whole job is to belong to whatever it is standing next to,
    /// and it stands next to two different things. The colours are the same
    /// either way -- a control plate's fill *is* the field fill -- so what
    /// changes is the shape and where the glyph sits.
    enum Skin {
        /// At the top of the pane list: a row pill's height and corner, with
        /// the glyph where the rows' coloured marks are.
        case spine
        /// In a page's header, in a row with the other controls: a
        /// `SettingsControlPlate`'s corner and its padding, because a search
        /// box a point rounder than the pop-up button beside it is exactly the
        /// sort of thing that reads as wrong without being nameable.
        case control
    }

    /// What was typed, on every keystroke.
    var onChange: ((String) -> Void)?

    /// What is in the field.
    ///
    /// Setting it reports the change, because every other way the text can
    /// change reports it too: a caller that sets a query and a user who types
    /// one should leave the list filtered the same way, and a setter that
    /// stayed quiet would leave the list showing the previous query's results
    /// under the new query's text.
    var text: String {
        get { field.stringValue }
        set {
            guard newValue != field.stringValue else { return }
            field.stringValue = newValue
            syncClearButton()
            onChange?(newValue)
        }
    }

    private let field = NSTextField()
    private let glyph = NSImageView()
    private let clearButton: IconButton

    private var highlight: RowHighlight?
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { if isHovered != oldValue { updateHighlight() } }
    }
    private var isEditing = false {
        didSet { if isEditing != oldValue { updateHighlight() } }
    }

    private let skin: Skin

    /// The corner it draws. A pill's next to the pane list, a control plate's
    /// next to the controls.
    private var cornerRadius: CGFloat {
        switch skin {
        case .spine: Style.SettingsUI.spineRowRadius
        case .control: Self.controlCornerRadius
        }
    }

    /// `SettingsControlPlate` rounds its corner by this, and a search box in a
    /// row with those plates has to round its own by the same.
    private static let controlCornerRadius: CGFloat = 8
    /// And it insets its control by this much, which is where the glyph goes.
    private static let controlInset: CGFloat = 9
    /// How far inside a row's pill that row's coloured mark sits, which is the
    /// same distance inside this field that its glyph sits.
    private static let markInset: CGFloat = 7
    /// The shortest a control plate is allowed to be. The field is pinned to
    /// its neighbours rather than to a number of its own, so this is only a
    /// floor for a field standing on its own.
    private static let controlMinimumHeight: CGFloat = 28

    init(skin: Skin = .spine, placeholder: String = "Search settings") {
        self.skin = skin
        // A small button: the clear cross is an affordance on a field, not a
        // control competing with it.
        clearButton = IconButton(symbolName: "xmark.circle.fill", label: "Clear Search", side: 20)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        if let layer { highlight = RowHighlight(in: layer, depth: .flat) }

        glyph.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        glyph.contentTintColor = Style.Colors.secondaryText
        glyph.imageScaling = .scaleProportionallyDown
        glyph.setAccessibilityElement(false)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)

        field.translatesAutoresizingMaskIntoConstraints = false
        field.delegate = self
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Style.Fonts.settingsRow
        field.textColor = Style.Colors.primaryText
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        addSubview(field)

        clearButton.setClickHandler { [weak self] in self?.clear() }
        clearButton.isHidden = true
        addSubview(clearButton)

        // Beside the pane list the glyph is centred in a slot the width of a
        // row's coloured mark and starts where that mark starts, so the text
        // after it lands on the same line as the pane names below. A row spans
        // the whole column and insets its pill by `railInset`, then puts its
        // mark seven points inside that pill; this field *is* inset by
        // `railInset`, so its leading edge and a pill's are the same line and
        // the seven points carry over directly.
        //
        // Beside the controls there are no marks to line up with, so the glyph
        // simply takes the padding a control plate gives whatever it holds.
        let slot = skin == .spine ? Style.SettingsUI.spineTileSide : 16
        let leadingInset = skin == .spine ? Self.markInset : Self.controlInset
        let glyphToText = skin == .spine ? Style.SettingsUI.spineTileGapToLabel : 6

        let heightRule = skin == .spine
            ? heightAnchor.constraint(equalToConstant: Style.SettingsUI.spineRowHeight)
            // Only a floor: a field in a header is pinned to the height of the
            // controls it sits with, and that constraint has to be free to win.
            : heightAnchor.constraint(greaterThanOrEqualToConstant: Self.controlMinimumHeight)

        NSLayoutConstraint.activate([
            heightRule,

            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            glyph.widthAnchor.constraint(equalToConstant: slot),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),

            field.leadingAnchor.constraint(
                equalTo: glyph.trailingAnchor,
                constant: glyphToText
            ),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -2),

            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("SettingsSearchField is created in code only") }

    /// Puts the keyboard in the field.
    func focus() { window?.makeFirstResponder(field) }

    /// Empties the field and says so, which is what the cross does and what
    /// Escape does.
    func clear() { text = "" }

    // MARK: - The plate

    /// The resting plate, under the highlight. Drawn rather than layered so the
    /// field has a shape before anything hovers or types in it -- the same
    /// reasoning, and the same two colours, as `AddressField`.
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: Style.Metrics.hairline / 2, dy: Style.Metrics.hairline / 2),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        Style.Colors.fieldFill.setFill()
        shape.fill()
        shape.lineWidth = Style.Metrics.hairline
        Style.Colors.fieldStroke.setStroke()
        shape.stroke()
    }

    override func layout() {
        super.layout()
        highlight?.layout(
            bounds, in: bounds.height, flipped: isFlipped,
            radius: cornerRadius, scale: highlightScale
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        highlight?.refresh(appearance: effectiveAppearance)
        glyph.contentTintColor = Style.Colors.secondaryText
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea = installHoverTracking(replacing: trackingArea)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// A click anywhere on the plate puts the caret in the text, rather than
    /// only a click that happens to land on the few points the text occupies.
    override func mouseDown(with event: NSEvent) { focus() }

    /// Typing outranks hover: a field being typed into stays lit even when the
    /// pointer has wandered off it.
    private func updateHighlight() {
        highlight?.apply(
            isEditing ? .selected : (isHovered ? .hover : .rest),
            appearance: effectiveAppearance
        )
    }

    private func syncClearButton() {
        clearButton.isHidden = field.stringValue.isEmpty
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidBeginEditing(_ obj: Notification) { isEditing = true }

    func controlTextDidEndEditing(_ obj: Notification) { isEditing = false }

    func controlTextDidChange(_ obj: Notification) {
        syncClearButton()
        onChange?(field.stringValue)
    }

    /// Escape empties the field rather than giving up first responder, which is
    /// what a search field does everywhere else and what the stock one did.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if field.stringValue.isEmpty { return false }
        clear()
        return true
    }
}
