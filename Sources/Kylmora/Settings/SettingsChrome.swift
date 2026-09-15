import AppKit

extension Style {
    /// Every measurement the Settings window uses.
    ///
    /// Separate from `Style.Metrics`, which is the browser chrome's own set:
    /// Settings is a document-like surface with its own rhythm, and forcing a
    /// 32-point tab row onto a form row would make both worse. What the two do
    /// share is the vocabulary -- continuous corners, translucent plates,
    /// semantic colours -- which is what makes the window read as part of
    /// Kylmora rather than as a system panel that wandered in.
    enum SettingsUI {
        /// The list of panes: a coloured mark and its name.
        ///
        /// It was tried at sixty-six points with the names dropped, on the
        /// theory that the colours would carry them. They do not: a colour you
        /// have not learned yet is not a label, and there is no way to learn it
        /// except by clicking every tile. So the names are back, and the column
        /// is still a hundred points narrower than the rail it replaced.
        static let spineWidth: CGFloat = 206
        static let spineRowHeight: CGFloat = 34
        static let spineRowRadius: CGFloat = 9
        static let spineTileSide: CGFloat = 24
        static let spineTileRadius: CGFloat = 7
        static let spineTileGap: CGFloat = 2
        /// Mark to name.
        static let spineTileGapToLabel: CGFloat = 10
        /// Air above a group of tiles, which is all that separates one group
        /// from the last now that the headings are gone.
        static let spineGroupGap: CGFloat = 18

        /// Kept: some panes still measure themselves against it.
        static let railWidth: CGFloat = 236
        /// The pill a rail row draws, and the air around it.
        static let railRowHeight: CGFloat = 34
        static let railRowRadius: CGFloat = 8
        static let railInset: CGFloat = 10
        /// Leading padding inside a rail pill, before the icon.
        static let railRowPadding: CGFloat = 10
        static let railIconSide: CGFloat = 17
        /// Icon to title.
        static let railIconGap: CGFloat = 9
        /// Air above a group heading in the rail, which is what separates one
        /// group of panes from the last.
        static let railGroupTopPadding: CGFloat = 16

        /// Clearance for the traffic lights, which float over the rail because
        /// the window has no titlebar of its own.
        static let titlebarHeight: CGFloat = 52

        /// The detail side's gutter, and the widest a form is allowed to get.
        /// Past about 660 points a row's label and its control drift so far
        /// apart that the eye loses the pairing.
        static let detailGutter: CGFloat = 28
        static let contentMaxWidth: CGFloat = 660

        /// The pane's name, set small and tracked out above the first card.
        /// It replaced a header band a hundred points tall that carried two
        /// lines of text; the name is worth about sixteen.
        static let eyebrowGap: CGFloat = 14
        /// Between the top of the scrolling page and the first thing on it.
        /// Every pane starts here, whether it opens on a card, a table or a
        /// hero: a pane that adds air of its own sits lower than its
        /// neighbours for no reason a reader can see.
        static let paneTopGap: CGFloat = 6

        /// The grouped plate a run of rows sits on. Rounder than a system box:
        /// the plates float on the space's wash rather than sitting in a frame.
        static let cardRadius: CGFloat = 18
        static let cardSpacing: CGFloat = 18
        /// Inside a card, before the label and after the control.
        static let cardPadding: CGFloat = 14
        /// Least a row may be. Most rows are this; one with a note under it
        /// grows.
        static let rowMinHeight: CGFloat = 46
        static let rowVerticalPadding: CGFloat = 10
        /// Label column to control column, when both are on one line.
        static let rowGap: CGFloat = 20
        /// Air above a heading, and between the heading and its card. More
        /// above than below, so the heading belongs to the card under it.
        static let sectionGap: CGFloat = 26
        static let sectionHeaderGap: CGFloat = 8
        /// Where a pop-up or a field settles. Wide enough for a path or a long
        /// choice, narrow enough that the label stays paired with it.
        static let controlWidth: CGFloat = 280

        /// The column the live miniature sits in, beside the form.
        static let previewColumnWidth: CGFloat = 320

        static let headerTitleSize: CGFloat = 22
    }
}

extension Style.Fonts {
    /// The pane's name at the top of the detail side.
    static var settingsTitle: NSFont {
        .systemFont(ofSize: Style.SettingsUI.headerTitleSize, weight: .bold)
    }
    /// A rail group's heading.
    static var settingsGroup: NSFont { .systemFont(ofSize: 11, weight: .semibold) }
    /// A row's label, and a rail row's title.
    static var settingsRow: NSFont { .systemFont(ofSize: 13) }
    /// A heading over a card.
    static var settingsSection: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
    /// The second line under a row's label.
    static var settingsNote: NSFont { .systemFont(ofSize: 11) }
}

extension Style.Colors {
    /// The ground the whole window is painted on, before the space's wash goes
    /// over it. Deliberately not `windowBackgroundColor`: this window is a
    /// canvas, not a form, and the system's form grey is the single thing that
    /// would make it look like a settings panel again.
    static var settingsCanvas: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)
                : NSColor(srgbRed: 0.925, green: 0.925, blue: 0.94, alpha: 1)
        }
    }

    /// A plate floating on the canvas. Translucent, so the space's wash comes
    /// through it and every card is quietly the colour of the space you are in.
    static var settingsGlass: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.07)
                : NSColor(white: 1, alpha: 0.96)
        }
    }

    /// An unselected tile in the spine.
    static var settingsSpineTile: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.07)
                : NSColor(white: 0, alpha: 0.05)
        }
    }

    /// The rail's ground. A shade off the detail side, which is what makes the
    /// two read as separate surfaces without a heavy divider between them.
    static var settingsRail: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.03)
                : NSColor(white: 0, alpha: 0.025)
        }
    }
    /// The detail side, and the window behind everything.
    static var settingsBackground: NSColor { .windowBackgroundColor }
    /// A card: lifted off the ground rather than outlined, so a page of eight
    /// of them does not turn into a grid of boxes.
    static var settingsCard: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.06)
                : NSColor(white: 1, alpha: 0.75)
        }
    }
    /// The card's edge. Barely there in light, where the card is nearly white
    /// on near-white and needs the help; almost absent in dark, where the fill
    /// alone already separates it.
    static var settingsCardStroke: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.06)
                : NSColor(white: 0, alpha: 0.12)
        }
    }
    /// Between two rows of one card. Lighter than a system separator, because
    /// it divides rows that belong together rather than sections that do not.
    static var settingsHairline: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.08)
                : NSColor(white: 0, alpha: 0.10)
        }
    }
    /// The selected pane in the rail.
    static var settingsRailSelected: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.13)
                : NSColor(white: 0, alpha: 0.10)
        }
    }
    static var settingsRailHover: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.06)
                : NSColor(white: 0, alpha: 0.035)
        }
    }
}

/// A layer-backed plate that repaints itself when the appearance changes.
///
/// Every rounded surface in this window is one of these. Painting in
/// `updateLayer` rather than `draw` keeps the whole window on the compositor,
/// and re-resolving the colour there is what makes a semantic `NSColor`
/// actually follow a switch to dark mode -- a `cgColor` captured once does not.
@MainActor
class SettingsPlateView: NSView {
    var fill: NSColor? { didSet { needsDisplay = true } }
    var stroke: NSColor? { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsPlateView is created in code only")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerCurve = .continuous
        layer.cornerRadius = cornerRadius
        // Resolved against this view's own appearance. Every colour here is a
        // dynamic one, and `cgColor` freezes whichever appearance is current at
        // the time. AppKit does make this view's appearance current around
        // `updateLayer`, so this is belt and braces rather than a fix for
        // anything observed -- but it is what makes the light and dark values
        // correct by construction rather than by AppKit's good manners.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = fill?.cgColor
            layer.borderWidth = stroke == nil ? 0 : 1
            layer.borderColor = stroke?.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

extension NSView {
    /// Keeps this view hidden exactly when the control it dresses is.
    ///
    /// A pane hides its own control -- Sync hides "Reset" while the location is
    /// the default one, About hides "Download" until there is something to
    /// download -- and it knows nothing about the plate we wrapped it in. Left
    /// to itself the plate stays behind as an empty rounded box with nothing
    /// in it.
    func follows(_ control: NSView) -> NSKeyValueObservation {
        isHidden = control.isHidden
        return control.observe(\.isHidden, options: [.initial, .new]) { control, _ in
            MainActor.assumeIsolated { [weak self] in self?.isHidden = control.isHidden }
        }
    }
}

/// A checkbox that a pane put inside a stack of its own, wearing our switch.
///
/// The form turns a checkbox handed to `addRow` into a switch with the label
/// beside it. A checkbox inside a stack the pane built never reached that, so
/// panes like Advanced and Spaces kept AppKit's blue tick next to our own
/// switches on the same page. This is the same trade in the same shape: the
/// checkbox stays as the model, carrying the state and the pane's action, and
/// what you see is ours.
@MainActor
final class SettingsInlineSwitch: NSView {
    let adaptor: SettingsSwitchAdaptor
    private var visibility: NSKeyValueObservation?

    init(checkbox: NSButton) {
        adaptor = SettingsSwitchAdaptor(checkbox: checkbox)
        super.init(frame: .zero)
        defer { visibility = follows(checkbox) }
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(wrappingLabelWithString: adaptor.title)
        label.font = Style.Fonts.settingsRow
        label.textColor = Style.Colors.primaryText
        label.maximumNumberOfLines = 2
        label.setAccessibilityElement(false)

        let row = NSStackView(views: [adaptor.control, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsInlineSwitch is created in code only")
    }
}

/// A radio button wearing our own mark.
///
/// The same trade as the switch: the `NSButton` stays as the model, holding the
/// state and carrying the pane's action, and what you see is a ring that fills
/// with the pane's colour. Taking the button out of its superview also takes
/// it out of AppKit's radio group -- the siblings that turned off when it
/// turned on -- so the form puts it in a `Group` of ours, which does the same.
@MainActor
final class SettingsInlineRadio: NSView {
    /// The radios that answer one question: choosing one unchooses the rest.
    /// Privacy's crash-report policy relied on AppKit doing this while the
    /// three sat in one stack; on three rows all three could be lit at once.
    @MainActor
    final class Group {
        private let members = NSHashTable<SettingsInlineRadio>.weakObjects()

        func add(_ radio: SettingsInlineRadio) {
            members.add(radio)
            radio.group = self
        }

        fileprivate func chose(_ chosen: SettingsInlineRadio) {
            for other in members.allObjects where other !== chosen {
                other.radio.state = .off
                other.sync()
            }
        }
    }

    private let radio: NSButton
    private let mark = MarkView()
    private var visibility: NSKeyValueObservation?
    fileprivate var group: Group?

    /// - Parameter showsTitle: false for the mark on its own, when the row it
    ///   is on already carries the title.
    init(radio: NSButton, showsTitle: Bool = true) {
        self.radio = radio
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        var views: [NSView] = [mark]
        if showsTitle {
            let label = NSTextField(wrappingLabelWithString: radio.title)
            label.font = Style.Fonts.settingsRow
            label.textColor = Style.Colors.primaryText
            label.maximumNumberOfLines = 2
            label.setAccessibilityElement(false)
            views.append(label)
        } else {
            setContentHuggingPriority(.required, for: .horizontal)
            setContentCompressionResistancePriority(.required, for: .horizontal)
            // Exactly the mark's width, so a row that hands this view the
            // slack cannot stretch it and leave the mark at its leading edge,
            // a gap after the label.
            widthAnchor.constraint(equalToConstant: 16).isActive = true
        }

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        // Kept off screen by having no size and no opacity rather than by
        // `isHidden`: hiding is the pane's signal, and this view follows it.
        radio.alphaValue = 0
        radio.frame = .zero
        addSubview(radio, positioned: .below, relativeTo: nil)
        visibility = follows(radio)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(radio.title)
        sync()
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsInlineRadio is created in code only")
    }

    /// Read on every draw rather than observed: a pane sets all of its radios
    /// at once in its `reload`, and one comparison a draw is cheaper than
    /// keeping observers alive across a window that comes and goes.
    override func viewWillDraw() {
        sync()
        super.viewWillDraw()
    }

    private func sync() {
        mark.isChosen = radio.state == .on
        mark.isEnabled = radio.isEnabled
        mark.tint = settingsAccent
        setAccessibilityValue(radio.state == .on ? "selected" : "")
    }

    override func mouseDown(with event: NSEvent) {
        choose()
    }

    override func accessibilityPerformPress() -> Bool {
        choose()
        return true
    }

    /// Chooses this one. The row it sits on calls it too, so the whole row
    /// is the target.
    func choose() {
        guard radio.isEnabled, radio.state != .on else { return }
        radio.state = .on
        group?.chose(self)
        // By hand, as the switch does: `performClick` would put the button
        // through its own toggling as well.
        if let action = radio.action {
            NSApp.sendAction(action, to: radio.target, from: radio)
        }
        sync()
    }

    /// The ring.
    private final class MarkView: NSView {
        var isChosen = false { didSet { if isChosen != oldValue { needsDisplay = true } } }
        var isEnabled = true { didSet { if isEnabled != oldValue { needsDisplay = true } } }
        var tint: NSColor? { didSet { if tint != oldValue { needsDisplay = true } } }

        override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }

        override func draw(_ dirtyRect: NSRect) {
            let circle = bounds.insetBy(dx: 1, dy: 1)
            let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let colour = tint ?? .controlAccentColor
            if isChosen {
                (isEnabled ? colour : colour.withAlphaComponent(0.4)).setFill()
                NSBezierPath(ovalIn: circle).fill()
                NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.5).setFill()
                NSBezierPath(ovalIn: circle.insetBy(dx: 4.5, dy: 4.5)).fill()
            } else {
                (isDark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.06)).setFill()
                NSBezierPath(ovalIn: circle).fill()
                (isDark ? NSColor(white: 1, alpha: 0.30) : NSColor(white: 0, alpha: 0.25)).setStroke()
                let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.5, dy: 0.5))
                ring.lineWidth = 1
                ring.stroke()
            }
        }
    }
}

/// A selected row in one of the window's lists.
///
/// AppKit's own selection is a grey slab from edge to edge, and it goes grey
/// again the moment the table loses focus, which reads as "nothing is selected
/// any more". This is a rounded plate in the pane's own hue, inset from the
/// edges the way the spine's rows are, and it stays that colour whether the
/// table has the keyboard or not.
@MainActor
final class SettingsTableRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let plate = bounds.insetBy(dx: 4, dy: 1)
        let accent = settingsAccent ?? .controlAccentColor
        accent.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: plate, xRadius: 8, yRadius: 8).fill()
    }

    /// Always emphasised: a selection that greys out when the list loses the
    /// keyboard tells you the wrong thing about what is selected.
    override var isEmphasized: Bool {
        get { true }
        set { }
    }

    /// The cells keep their ordinary text colour.
    ///
    /// AppKit hands a cell white text when its row says the selection is
    /// emphasised, which is right over a saturated system highlight and wrong
    /// over ours: in a light window "Page Zoom" came out white on a pale plate
    /// and vanished the moment you selected it.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

extension NSView {
    /// The hue of the pane this view is on, if it is on one.
    var settingsAccent: NSColor? {
        var view: NSView? = self
        while let current = view {
            if let form = current as? SettingsForm { return form.accent }
            if let canvas = current as? SettingsCanvasView { return canvas.accentHint }
            view = current.superview
        }
        return nil
    }
}

/// A pane that wants the whole width of the detail side.
///
/// Forms are held to a reading width: past about 660 points a label and its
/// control drift so far apart that the eye loses the pairing. A table is the
/// other case entirely -- it has columns to show, and holding it to a column
/// of its own only clips them.
@MainActor
protocol SettingsWidePane: NSViewController {}

/// One hairline.
@MainActor
final class SettingsHairlineView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsHairlineView is created in code only")
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Style.Colors.settingsHairline.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Drives a checkbox from a switch.
///
/// The panes were written against `NSButton` checkboxes and still are: the
/// checkbox stays the model, holding the state and carrying the target and
/// action the pane set on it. The switch is a face for it. That is what lets
/// every pane get the new control without a line of the pane changing, and it
/// means a pane that sets `state` directly -- which they all do, in `reload()`
/// -- still works, because the switch follows the checkbox through KVO rather
/// than holding a copy of its state.
@MainActor
final class SettingsSwitchAdaptor: NSObject {
    let checkbox: NSButton
    let control = SettingsToggle()
    /// The checkbox's own title, which becomes the row's label: a switch has
    /// no room for text of its own.
    var title: String { checkbox.title }

    init(checkbox: NSButton) {
        self.checkbox = checkbox
        super.init()
        control.translatesAutoresizingMaskIntoConstraints = false
        control.target = self
        control.action = #selector(flipped)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        control.setAccessibilityLabel(checkbox.title)
        sync()
        // String-keyed rather than key-path KVO: `NSButton.state` and
        // `isEnabled` are Cocoa-Bindings-compliant but not `@objc dynamic` in
        // the Swift overlay, so the typed form will not compile against them.
        for key in ["state", "enabled"] {
            checkbox.addObserver(self, forKeyPath: key, options: [.new], context: nil)
        }
    }

    /// Lets the observers go. `deinit` cannot: it is not actor-isolated and so
    /// may not touch the checkbox. The window calls this as it closes.
    func stop() {
        for key in ["state", "enabled"] {
            checkbox.removeObserver(self, forKeyPath: key)
        }
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        MainActor.assumeIsolated { sync() }
    }

    private func sync() {
        // Not animated: this is the pane telling us what the state already is,
        // not the user changing it, and a row of toggles sliding on as a pane
        // appears looks like the window doing it rather than reporting it.
        control.setOn(checkbox.state == .on, animated: false)
        control.isEnabled = checkbox.isEnabled
    }

    @objc private func flipped() {
        checkbox.state = control.isOn ? .on : .off
        // Sent by hand rather than through `performClick`, which would toggle
        // the checkbox a second time and land it back where it started.
        if let action = checkbox.action {
            NSApp.sendAction(action, to: checkbox.target, from: checkbox)
        }
    }
}

/// The wrapper `SettingsForm.fill` returns: a control pinned to the one width
/// every filled control on every pane shares.
@MainActor
final class SettingsFilledBox: NSView {
    init(_ control: NSView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        NSLayoutConstraint.activate([
            control.topAnchor.constraint(equalTo: topAnchor),
            control.leadingAnchor.constraint(equalTo: leadingAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Style.SettingsUI.controlWidth)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsFilledBox is created in code only")
    }
}

/// A card row that leads with a coloured tile: a mark, a name, and a switch.
///
/// The tile is what makes a list of toggles scannable. Three rows reading
/// "Block ads / Block cookie banners / Block trackers" are three identical
/// grey lines; a red shield, an orange biscuit and a yellow pair of glasses
/// are three things you can find again without reading. The shape is the
/// browser's own -- a continuous-corner square, the same curve as the page
/// card and the folder plate -- rather than a circle or a plain glyph.
@MainActor
final class SettingsSwitchRow: NSView {
    /// What goes in the tile.
    enum Tile {
        /// An SF Symbol, drawn white on the colour.
        case symbol(String, NSColor)
        /// An emoji, drawn at its own colours on the colour.
        case emoji(String, NSColor)
    }

    static let tileSide: CGFloat = 26

    /// The tile on its own, for the places that want the mark without the row:
    /// a table of website categories, a popover header.
    static func tileView(_ tile: Tile, side: CGFloat = SettingsSwitchRow.tileSide) -> NSView {
        let plate = SettingsPlateView()
        // A quarter of the side, which is close to the system's own app-icon
        // proportion and reads as a rounded square rather than a circle at
        // every size these are used at.
        plate.cornerRadius = side * 0.26
        let content: NSView
        switch tile {
        case let .symbol(name, colour):
            plate.fill = colour
            let image = NSImageView()
            image.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            image.symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: side * 0.52, weight: .semibold
            )
            // White rather than the label colour: the tile is a solid colour in
            // both appearances, so the glyph on it must not follow the theme.
            image.contentTintColor = .white
            image.imageScaling = .scaleProportionallyDown
            content = image
        case let .emoji(text, colour):
            // A tenth of the colour behind an emoji, not the full strength: an
            // emoji brings its own colours and a saturated plate under it
            // turns the pair to mud.
            plate.fill = colour.withAlphaComponent(0.18)
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: side * 0.55)
            label.alignment = .center
            content = label
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        content.setAccessibilityElement(false)
        plate.addSubview(content)
        NSLayoutConstraint.activate([
            plate.widthAnchor.constraint(equalToConstant: side),
            plate.heightAnchor.constraint(equalToConstant: side),
            content.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: plate.centerYAnchor)
        ])
        plate.setAccessibilityElement(false)
        return plate
    }

    /// - Parameter subtitle: a second line under the name. Omitted where the
    ///   name says the whole thing, which is most of the time.
    /// Kept alive for as long as the row is: it is the only owner of the
    /// observers watching the system switch it replaced.
    private var bridge: SettingsSwitchBridge?

    init(tile: Tile, title: String, subtitle: String? = nil, control: NSView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // A pane that was written against `NSSwitch` gets ours instead, so one
        // window does not show two kinds of toggle in two different colours.
        var control = control
        // Named before the swap as well as after: the switch a pane handed over
        // is still the thing its own code talks to, and a test or a script
        // asking that control its name should get an answer.
        control.setAccessibilityLabel(title)
        if let systemSwitch = control as? NSSwitch {
            let bridge = SettingsSwitchBridge(systemSwitch: systemSwitch)
            self.bridge = bridge
            control = bridge.control
        }

        let mark = Self.tileView(tile)
        addSubview(mark)

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: title)
        name.font = Style.Fonts.settingsRow
        name.textColor = Style.Colors.primaryText
        name.lineBreakMode = .byTruncatingTail
        name.setAccessibilityElement(false)
        text.addArrangedSubview(name)
        if let subtitle, !subtitle.isEmpty {
            let second = NSTextField(labelWithString: subtitle)
            second.font = Style.Fonts.settingsNote
            second.textColor = Style.Colors.secondaryText
            second.lineBreakMode = .byTruncatingTail
            second.setAccessibilityElement(false)
            text.addArrangedSubview(second)
        }
        addSubview(text)

        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.required, for: .horizontal)
        // The switch is the thing VoiceOver lands on and the thing it flips, so
        // it carries the name. The row around it is a group.
        control.setAccessibilityLabel(title)
        addSubview(control)

        let padding = Style.SettingsUI.cardPadding
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: Style.SettingsUI.rowMinHeight),
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 10),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -12),
            control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            control.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        // One element to VoiceOver, not four: the row is the control.
        setAccessibilityRole(.group)
        setAccessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsSwitchRow is created in code only")
    }
}

/// The ground the Settings window is painted on.
///
/// Not a flat window colour: a wash of the current pane's hue, strongest at the
/// top-left behind the spine and fading out across the page. It is the same
/// move the browser makes with a space's colour, and it is most of why this
/// window looks like Kylmora rather than like a settings panel -- the whole
/// surface quietly changes colour as you move down the spine.
@MainActor
final class SettingsCanvasView: NSView {
    /// The hue of the pane being shown. Changing it repaints the wash.
    var accentHint: NSColor? {
        didSet {
            guard accentHint != oldValue else { return }
            // A crossfade, because a wash that snaps from blue to orange reads
            // as a glitch. Slow enough to notice, short enough not to wait for.
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.35
            layer?.add(fade, forKey: "wash")
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsCanvasView is created in code only")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Style.Colors.settingsCanvas.setFill()
        bounds.fill()
        guard let accent = accentHint else { return }
        // Faint on purpose. The cards, the tiles and the text all have to stay
        // readable on top of it; this is a tint, not a background image.
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let strong = accent.withAlphaComponent(isDark ? 0.20 : 0.13)
        let gone = accent.withAlphaComponent(0)
        // Drawn into `bounds`, not into a rect sized as a fraction of it. A
        // gradient is clipped to the rect it is given, so the earlier version
        // -- 1.1 times the width, offset left -- simply stopped at ninety per
        // cent and left a vertical seam down the right of the window where the
        // wash ended and the flat canvas began.
        NSGradient(starting: strong, ending: gone)?.draw(
            in: bounds,
            relativeCenterPosition: NSPoint(x: -0.55, y: -0.55)
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The name of the spine tile under the pointer, floating beside it.
///
/// The spine drops the labels to win back a sixth of the window; this is the
/// half-second in which you get one back, for the tile you are actually
/// pointing at.
@MainActor
final class SettingsNameChip: NSView {
    private let plate = SettingsPlateView()
    private let dot = SettingsPlateView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        plate.fill = Style.Colors.settingsGlass
        plate.stroke = Style.Colors.settingsCardStroke
        plate.cornerRadius = 9
        addSubview(plate)

        dot.cornerRadius = 3
        addSubview(dot)

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = Style.Colors.primaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            plate.topAnchor.constraint(equalTo: topAnchor),
            plate.leadingAnchor.constraint(equalTo: leadingAnchor),
            plate.trailingAnchor.constraint(equalTo: trailingAnchor),
            plate.bottomAnchor.constraint(equalTo: bottomAnchor),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsNameChip is created in code only")
    }

    func show(_ name: String, accent: NSColor) {
        label.stringValue = name
        dot.fill = accent
    }

    /// The pointer must never be caught by the chip: it floats over the page
    /// and swallowing a click there would be a mystery.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The toggle, drawn rather than `NSSwitch`.
///
/// The system switch paints itself in the user's macOS accent colour, which is
/// how a window otherwise built out of the space's palette ends up with a
/// magenta control in the middle of it. This one takes its colour from the pane
/// it is on, so a toggle on Privacy is Privacy's red and a toggle on Spaces is
/// Spaces' green.
@MainActor
final class SettingsToggle: NSControl {
    static let size = NSSize(width: 38, height: 22)

    private(set) var isOn = false
    /// The pane's hue. Nil falls back to the system accent.
    var tint: NSColor? {
        didSet {
            guard tint != oldValue else { return }
            apply(animated: false)
        }
    }

    // Two layers rather than a `draw`: the knob has to slide and the track has
    // to change colour at the same time, and Core Animation already does both
    // for free. It also keeps the control off the main thread's drawing path.
    private let track = CALayer()
    private let knob = CALayer()
    private var isPressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(knob)
        knob.backgroundColor = NSColor.white.cgColor
        // Keeps the knob reading as a thing sitting on the track rather than a
        // hole cut out of it.
        knob.shadowColor = NSColor.black.cgColor
        knob.shadowOpacity = 0.28
        knob.shadowRadius = 2
        knob.shadowOffset = CGSize(width: 0, height: -1)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height)
        ])
        setAccessibilityRole(.checkBox)
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsToggle is created in code only")
    }

    /// - Parameter animated: false when a pane is telling us what the state
    ///   already is. A row of toggles sliding on as a pane appears looks like
    ///   the window doing it rather than reporting it.
    func setOn(_ on: Bool, animated: Bool) {
        isOn = on
        setAccessibilityValue(on)
        apply(animated: animated)
    }

    override var isEnabled: Bool {
        didSet { apply(animated: false) }
    }

    override func layout() {
        super.layout()
        apply(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply(animated: false)
    }

    private func apply(animated: Bool) {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let off = isDark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.12)
        let on = tint ?? .controlAccentColor
        let colour = isOn ? on : off

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.16)
        track.frame = bounds
        track.cornerCurve = .continuous
        track.cornerRadius = bounds.height / 2
        track.backgroundColor = (isEnabled ? colour : colour.withAlphaComponent(0.4)).cgColor

        let inset: CGFloat = 2.5
        let side = bounds.height - inset * 2
        let run = bounds.width - side - inset * 2
        knob.frame = CGRect(x: inset + (isOn ? run : 0), y: inset, width: side, height: side)
        knob.cornerRadius = side / 2
        knob.opacity = isEnabled ? 1 : 0.7
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, isPressed else { return }
        isPressed = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        flip()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        flip()
        return true
    }

    private func flip() {
        setOn(!isOn, animated: true)
        sendAction(action, to: target)
    }
}

/// Drives a system switch from ours.
///
/// The same trick as `SettingsSwitchAdaptor`, for the panes that were written
/// against `NSSwitch` rather than a checkbox. The system switch stays the model
/// -- it holds the state, and the pane sets its target and action, sometimes
/// after handing it over -- and never reaches the screen. Ours is what is seen,
/// and it takes the pane's colour rather than the user's macOS accent.
@MainActor
final class SettingsSwitchBridge: NSObject {
    let systemSwitch: NSSwitch
    let control = SettingsToggle()

    init(systemSwitch: NSSwitch) {
        self.systemSwitch = systemSwitch
        super.init()
        control.target = self
        control.action = #selector(flipped)
        control.setAccessibilityLabel(systemSwitch.accessibilityLabel())
        sync()
        for key in ["state", "enabled"] {
            systemSwitch.addObserver(self, forKeyPath: key, options: [.new], context: nil)
        }
    }

    func stop() {
        for key in ["state", "enabled"] {
            systemSwitch.removeObserver(self, forKeyPath: key)
        }
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        MainActor.assumeIsolated { sync() }
    }

    private func sync() {
        control.setOn(systemSwitch.state == .on, animated: false)
        control.isEnabled = systemSwitch.isEnabled
    }

    @objc private func flipped() {
        systemSwitch.state = control.isOn ? .on : .off
        if let action = systemSwitch.action {
            NSApp.sendAction(action, to: systemSwitch.target, from: systemSwitch)
        }
    }
}

/// The plate a pop-up, a field or a button is dressed in.
///
/// The panes hand over stock AppKit controls -- a bezelled `NSPopUpButton`, a
/// bordered `NSTextField`, a rounded push button -- and stock controls on a
/// dark translucent card look like three different decades stacked on one row.
/// So the control's own chrome is switched off and this draws the surface
/// instead: one radius, one fill, one border, for all three.
@MainActor
final class SettingsControlPlate: SettingsPlateView {
    /// The pane's hue, for the chevron and the focus ring.
    var tint: NSColor? {
        didSet { chevron?.contentTintColor = tint ?? Style.Colors.secondaryText }
    }

    /// Whether the row should give this plate the full width of the card with
    /// its label above it, rather than pairing the two on one line. A URL is
    /// longer than any control column, and half of one in a narrow box tells
    /// you nothing about the address you are looking at.
    private(set) var wantsFullWidth = false

    private var chevron: NSImageView?
    private var visibility: NSKeyValueObservation?
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            // The colour is chosen here, on the event, and never inside
            // `updateLayer`. `fill` marks the view as needing display, so
            // setting it while drawing schedules another draw, and the next
            // one does it again: the window pegs a core and never appears.
            fill = isHovered ? Style.Colors.settingsControlHover : Style.Colors.settingsControl
        }
    }
    private var trackingArea: NSTrackingArea?

    /// - Parameters:
    ///   - width: nil lets the control size itself, for a button.
    ///   - fullWidth: the plate takes the card's whole width instead.
    init(_ control: NSView, width: CGFloat?, fullWidth: Bool = false) {
        super.init(frame: .zero)
        wantsFullWidth = fullWidth
        cornerRadius = 8
        fill = Style.Colors.settingsControl
        stroke = Style.Colors.settingsControlStroke

        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        visibility = follows(control)

        var trailingInset: CGFloat = 10
        if let popUp = control as? NSPopUpButton {
            // The bezel goes, and with it the system's own arrow; ours is drawn
            // at the trailing edge in the pane's colour.
            popUp.isBordered = false
            popUp.font = Style.Fonts.settingsRow
            let mark = NSImageView()
            mark.image = NSImage(
                systemSymbolName: "chevron.up.chevron.down",
                accessibilityDescription: nil
            )
            mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            mark.contentTintColor = Style.Colors.secondaryText
            mark.translatesAutoresizingMaskIntoConstraints = false
            mark.setAccessibilityElement(false)
            addSubview(mark)
            chevron = mark
            NSLayoutConstraint.activate([
                mark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                mark.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
            trailingInset = 26
        } else if let field = control as? NSTextField {
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.font = Style.Fonts.settingsRow
        } else if let button = control as? NSButton {
            button.isBordered = false
            button.font = Style.Fonts.settingsRow
            button.contentTintColor = Style.Colors.primaryText
        }

        // A plate is as tall as its control and no taller. Without this it
        // stretches to whatever height a filling stack has going spare, which
        // on the Websites pane was the height of the whole card.
        setContentHuggingPriority(.defaultHigh, for: .vertical)

        var constraints: [NSLayoutConstraint] = [
            heightAnchor.constraint(greaterThanOrEqualToConstant: fullWidth ? 34 : 28),
            control.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailingInset),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
            control.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
            control.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4)
        ]
        if let width {
            constraints.append(widthAnchor.constraint(equalToConstant: width))
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsControlPlate is created in code only")
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

extension Style.Colors {
    /// The surface of a pop-up, a field or a button on a card.
    static var settingsControl: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.09)
                : NSColor(white: 0, alpha: 0.05)
        }
    }
    static var settingsControlHover: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.14)
                : NSColor(white: 1, alpha: 1)
        }
    }
    static var settingsControlStroke: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.10)
                : NSColor(white: 0, alpha: 0.14)
        }
    }
}
