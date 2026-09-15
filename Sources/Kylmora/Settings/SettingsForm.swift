import AppKit

/// A settings pane: a column of grouped cards, each card a run of rows, each
/// row a label on the left and its control on the right.
///
/// This replaced a two-column `NSGridView` of right-aligned `Label:` text --
/// the shape a system preferences window has had for twenty years, and the one
/// the user asked to be rid of. The API is unchanged, deliberately: thirteen
/// panes and some six thousand lines were written against `addRow`, `addNote`
/// and `addSeparator`, and none of them should have to know what a row looks
/// like. `addSeparator` is the one whose meaning moved -- it used to draw a
/// hairline between groups, and now it ends a card and starts the next, which
/// is the same thought in the new vocabulary.
@MainActor
final class SettingsForm: NSView {
    /// Kept for the panes that size their own controls against it.
    static let labelWidth: CGFloat = 230
    static let controlWidth: CGFloat = Style.SettingsUI.controlWidth

    private let stack = NSStackView()
    /// The card rows are going into. Nil after a separator, until the next row
    /// asks for one.
    private var openCard: SettingsCardView?
    /// Whether the open card was opened by a group a pane handed over as one
    /// stack -- "Mouse Gestures" and its three switches. Notes and
    /// continuations belong to that group; the next row with a label of its
    /// own is a different subject and starts a card of its own.
    private var cardBelongsToGroup = false
    /// Every switch standing in for a checkbox, held so the observers can be
    /// let go when the window closes.
    private var adaptors: [SettingsSwitchAdaptor] = []
    private var cards: [SettingsCardView] = []

    /// The pane's hue, worn by the controls: the chosen pill, the switch that
    /// is on, a field's focus. Set by the window when the pane is shown, so a
    /// form built before anyone knew which pane it belonged to still ends up
    /// wearing the right colour. The cards themselves stay uncoloured -- a
    /// stripe down their edge only fenced the settings off from each other.
    var accent: NSColor? {
        didSet {
            guard accent != oldValue else { return }
            for adaptor in adaptors { adaptor.control.tint = accent }
            tintControls(in: self)
        }
    }

    /// The pane's colour, down to every pill and chevron on it.
    private func tintControls(in view: NSView) {
        for child in view.subviews {
            (child as? SettingsControlPlate)?.tint = accent
            (child as? SettingsChoiceControl)?.tint = accent
            (child as? SettingsSegments)?.tint = accent
            (child as? SettingsToggle)?.tint = accent
            tintControls(in: child)
        }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Style.SettingsUI.cardSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsForm is created in code only")
    }

    /// Top-down, so a form inside a scroll view starts at its top rather than
    /// scrolled to wherever a bottom-up origin lands.
    override var isFlipped: Bool { true }

    /// Lets the checkbox observers go. The window controller calls it when the
    /// window closes; a form that is never torn down never needs it.
    func stopObserving() {
        for adaptor in adaptors { adaptor.stop() }
        adaptors = []
    }

    /// How a row's label lines up with its control.
    enum RowAlignment {
        /// Side by side, unless they will not fit, in which case the row
        /// stacks on its own.
        case baseline
        /// The same. Kept because the panes name it for sliders and swatches,
        /// which the automatic stacking already handles.
        case center
        /// The control under the label, always: a paragraph, a list, a grid --
        /// anything that wants the full width whether it would fit or not.
        case top
    }

    // MARK: - Rows

    /// A heading over the next card.
    ///
    /// Set on the canvas rather than inside the card, the way a grouped list
    /// names its groups: the card underneath is then the whole of what the
    /// heading says, and the eye reads heading, group, heading, group down the
    /// page. Ends the card before it.
    @discardableResult
    func addSection(_ title: String) -> SettingsFormRow {
        openCard = nil
        cardBelongsToGroup = false
        radioGroup = nil
        let row = SettingsFormRow(header: title)
        // More air above a heading than between two cards, and less between
        // the heading and its own card: the heading belongs to what is under
        // it, not to what is above.
        if let last = stack.arrangedSubviews.last {
            stack.setCustomSpacing(Style.SettingsUI.sectionGap, after: last)
        }
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(Style.SettingsUI.sectionHeaderGap, after: row)
        return row
    }

    /// Rows a pane built itself, onto the open card -- or a new one.
    ///
    /// For the pane that draws its own rows, such as the content blocker's
    /// three tiles: they land on the same plate as the rows around them rather
    /// than on a plate of their own inside it.
    func addRows(_ rows: [NSView]) {
        for row in rows { add(row) }
    }

    /// A label and one control.
    @discardableResult
    func addRow(_ label: String, _ control: NSView, alignment: RowAlignment = .baseline) -> SettingsFormRow {
        // A row with a name of its own is a new subject, so it leaves a group's
        // card rather than joining it under a heading it has nothing to do
        // with.
        if cardBelongsToGroup, !label.isEmpty {
            openCard = nil
            cardBelongsToGroup = false
        }
        // A checkbox arrives carrying its own title, which is the real label
        // for the row; a switch has nowhere to put text. Where the caller gave
        // a label too, both are kept -- the label names the setting and the
        // checkbox's own words explain it underneath.
        if let checkbox = control as? NSButton, checkbox.isCheckboxLike {
            let adaptor = adaptor(for: checkbox)
            return add(SettingsFormRow(
                label: label.isEmpty ? adaptor.title : label,
                note: label.isEmpty ? nil : adaptor.title,
                control: adaptor.control,
                style: .control,
                stacking: .never
            ))
        }
        // A radio is a row too, with its mark where every other row keeps its
        // control. Choosing is done on the whole row.
        if let radio = control as? NSButton, radio.isRadioLike {
            return add(SettingsFormRow(
                label: label.isEmpty ? radio.title : label,
                note: label.isEmpty ? nil : radio.title,
                control: SettingsInlineRadio(radio: radio, showsTitle: false),
                style: .control,
                stacking: .never
            ))
        }
        // A checkbox with company -- "Minimum font size" and the field that
        // sets it -- is still one setting: the checkbox names the row and the
        // rest sits with the switch at the trailing edge.
        if let group = control as? NSStackView, group.orientation == .horizontal,
           let checkbox = group.arrangedSubviews.first as? NSButton, checkbox.isCheckboxLike {
            let (title, trailing) = ledBySwitch(group, checkbox: checkbox)
            return add(SettingsFormRow(
                label: label.isEmpty ? title : label,
                note: label.isEmpty ? nil : title,
                control: trailing,
                style: .control,
                stacking: .whenTight
            ))
        }
        // A pane's own stack of switches is a group: each one a row of its
        // own, under a heading, on a card of their own.
        if let group = control as? NSStackView, Self.isToggleGroup(group) {
            return explode(group, under: label)
        }
        let dressedControl = dressed(control)
        return add(SettingsFormRow(
            label: label,
            control: dressedControl,
            style: .control,
            stacking: Self.spansTheRow(dressedControl) || alignment == .top ? .always : .whenTight
        ))
    }

    /// Whether a control is one that takes the width of the card, with its
    /// label on the line above it.
    ///
    /// A single control that states one value -- a switch, a dropdown, a button
    /// -- pairs with its label on one line. Anything bigger is a block of its
    /// own: a field for a URL, a list, a group of switches, a proxy's worth of
    /// fields. Those were being squeezed into the control column at the right
    /// of the card with the label marooned at the left and a canyon of empty
    /// space between the two.
    private static func spansTheRow(_ control: NSView) -> Bool {
        if (control as? SettingsControlPlate)?.wantsFullWidth == true { return true }
        if control is SettingsCardView || control is NSScrollView || control is NSTableView {
            return true
        }
        if let stack = control as? NSStackView, stack.orientation == .vertical { return true }
        return false
    }

    /// A label and several controls side by side.
    @discardableResult
    func addRow(_ label: String, _ controls: [NSView]) -> SettingsFormRow {
        let row = NSStackView(views: controls)
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        // Filling, not packing: whichever control hugs least -- a field for a
        // link, a line of status -- takes the slack, instead of every control
        // sitting at its smallest and the row trailing off into empty card.
        row.distribution = .fill
        return addRow(label, row)
    }

    /// A row whose label is the pane's own field, so the pane can change what
    /// it says later: "161,655 active rules from 7 lists" beside the buttons
    /// that refresh them.
    @discardableResult
    func addRow(_ label: NSTextField, _ controls: [NSView]) -> SettingsFormRow {
        let row = NSStackView(views: controls)
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.distribution = .fill
        return add(SettingsFormRow(
            label: "",
            titleField: label,
            control: dressed(row),
            style: .control,
            stacking: .whenTight
        ))
    }

    /// A second control belonging to the row above it, which is why it carries
    /// no hairline: the two are one setting stated twice.
    @discardableResult
    func addContinuation(_ control: NSView) -> SettingsFormRow {
        if let checkbox = control as? NSButton, checkbox.isCheckboxLike {
            let adaptor = adaptor(for: checkbox)
            return add(SettingsFormRow(
                label: adaptor.title,
                control: adaptor.control,
                style: .attached,
                stacking: .never
            ))
        }
        if let radio = control as? NSButton, radio.isRadioLike {
            return add(SettingsFormRow(
                label: radio.title,
                control: SettingsInlineRadio(radio: radio, showsTitle: false),
                style: .attached,
                stacking: .never
            ))
        }
        if let group = control as? NSStackView, Self.isToggleGroup(group) {
            return explode(group, under: "")
        }
        let dressedControl = dressed(control)
        return add(SettingsFormRow(
            label: "",
            control: dressedControl,
            style: .attached,
            stacking: Self.spansTheRow(dressedControl) ? .always : .whenTight
        ))
    }

    // MARK: - Groups a pane built itself

    /// Whether a vertical stack a pane handed over is a group of settings --
    /// switches, radios, and whatever sits between them -- rather than a
    /// layout of its own.
    ///
    /// The panes were written against `NSStackView` and put their toggles in
    /// one, three or five at a time. Drawn as a stack they came out as a
    /// column of switches with the text trailing off to the right, no line
    /// between them and no edge shared with the rows above: two designs on one
    /// card. A list is not a group, and neither is a card.
    private static func isToggleGroup(_ stack: NSStackView) -> Bool {
        guard stack.orientation == .vertical, stack.arrangedSubviews.count > 1 else { return false }
        var hasToggle = false
        for child in stack.arrangedSubviews {
            if child is NSScrollView || child is NSTableView || child is SettingsCardView { return false }
            if let button = child as? NSButton, button.isCheckboxLike || button.isRadioLike {
                hasToggle = true
            }
            if let row = child as? NSStackView, row.orientation == .horizontal,
               let lead = row.arrangedSubviews.first as? NSButton, lead.isCheckboxLike {
                hasToggle = true
            }
        }
        return hasToggle
    }

    /// The group as rows: a heading, then one row per setting.
    private func explode(_ group: NSStackView, under label: String) -> SettingsFormRow {
        var first: SettingsFormRow?
        if !label.isEmpty { first = addSection(label) }
        let children = group.arrangedSubviews
        var index = 0
        while index < children.count {
            let child = children[index]
            let next = index + 1 < children.count ? children[index + 1] : nil
            // Out of the pane's stack before being dressed, for the reason
            // `skinContents` gives: the dressing adopts the control.
            group.removeArrangedSubview(child)
            child.removeFromSuperview()
            let row: SettingsFormRow
            if let caption = child as? NSTextField, !caption.isEditable, !Self.isParagraph(caption),
               let next, Self.isValue(next) {
                // "Bypass domains:" and the field under it are one setting.
                group.removeArrangedSubview(next)
                next.removeFromSuperview()
                let dressedNext = Self.fill(next)
                row = add(SettingsFormRow(
                    label: Self.heading(caption.stringValue),
                    control: dressedNext,
                    style: .control,
                    stacking: Self.spansTheRow(dressedNext) ? .always : .whenTight
                ))
                index += 1
            } else {
                row = groupRow(for: child)
            }
            if first == nil { first = row }
            index += 1
        }
        if !label.isEmpty { cardBelongsToGroup = true }
        return first ?? SettingsFormRow(spacer: ())
    }

    /// One member of a group, as a row.
    private func groupRow(for child: NSView) -> SettingsFormRow {
        if let checkbox = child as? NSButton, checkbox.isCheckboxLike {
            let adaptor = adaptor(for: checkbox)
            return add(SettingsFormRow(
                label: adaptor.title, control: adaptor.control, style: .control, stacking: .never
            ))
        }
        if let radio = child as? NSButton, radio.isRadioLike {
            return add(SettingsFormRow(
                label: radio.title,
                control: SettingsInlineRadio(radio: radio, showsTitle: false),
                style: .control,
                stacking: .never
            ))
        }
        if let row = child as? NSStackView, row.orientation == .horizontal {
            if let checkbox = row.arrangedSubviews.first as? NSButton, checkbox.isCheckboxLike {
                let (title, trailing) = ledBySwitch(row, checkbox: checkbox)
                return add(SettingsFormRow(
                    label: title, control: trailing, style: .control, stacking: .whenTight
                ))
            }
            // "Auto-lock:" and its pop-up: the caption names the row.
            if let caption = row.arrangedSubviews.first as? NSTextField, !caption.isEditable,
               row.arrangedSubviews.count > 1 {
                row.removeArrangedSubview(caption)
                caption.removeFromSuperview()
                skinContents(of: row)
                return add(SettingsFormRow(
                    label: Self.heading(caption.stringValue),
                    control: row,
                    style: .control,
                    stacking: .whenTight
                ))
            }
        }
        // A line of status -- "Last updated ..." -- is a note.
        if let caption = child as? NSTextField, !caption.isEditable {
            return addNote(caption)
        }
        // A field on its own takes the row; a button, a pop-up or a run of
        // them sits under the row above at its own size.
        if let field = child as? NSTextField, field.isEditable {
            return add(SettingsFormRow(
                label: "", control: Self.fill(field), style: .attached, stacking: .always
            ))
        }
        let dressedChild = dressed(child)
        return add(SettingsFormRow(
            label: "",
            control: dressedChild,
            style: .attached,
            stacking: Self.spansTheRow(dressedChild) ? .always : .whenTight
        ))
    }

    /// A row that a checkbox leads: its title, and everything after it with
    /// the switch at the end.
    private func ledBySwitch(_ row: NSStackView, checkbox: NSButton) -> (title: String, control: NSView) {
        let adaptor = adaptor(for: checkbox)
        let rest = row.arrangedSubviews.filter { $0 !== checkbox }
        for view in row.arrangedSubviews {
            row.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let extras = rest.map { Self.dressable($0) ? Self.dressed(inStack: $0) : $0 }
        let trailing = NSStackView(views: extras + [adaptor.control])
        trailing.orientation = .horizontal
        trailing.alignment = .centerY
        trailing.spacing = 8
        // A little more before the switch, so it reads as the row's control
        // and the rest as the value it governs.
        if let last = extras.last { trailing.setCustomSpacing(14, after: last) }
        return (adaptor.title, trailing)
    }

    /// Whether a view is something a caption can name: a field, a pop-up.
    private static func isValue(_ view: NSView) -> Bool {
        if view is NSPopUpButton { return true }
        if let field = view as? NSTextField { return field.isEditable }
        return false
    }

    private static func isParagraph(_ field: NSTextField) -> Bool {
        field.maximumNumberOfLines == 0 || field.lineBreakMode == .byWordWrapping
    }

    /// A caption without the colon a pane put on it for the old layout.
    private static func heading(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix(":") { trimmed.removeLast() }
        return trimmed
    }

    /// Small secondary text under a control.
    @discardableResult
    func addNote(_ text: String) -> SettingsFormRow {
        addNote(NSTextField(wrappingLabelWithString: text))
    }

    /// A pane's own label as a note, so it can change the text later.
    @discardableResult
    func addNote(_ note: NSTextField) -> SettingsFormRow {
        note.font = Style.Fonts.settingsNote
        note.textColor = Style.Colors.secondaryText
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0
        return addNoteRow(note)
    }

    /// A note explains the row above it. With no row above it there is nothing
    /// to explain and nothing to sit on: a card of its own is a plate bearing
    /// small print, which is what made the sync pane's closing line look like a
    /// broken box. It goes on the canvas instead, under the card it follows.
    private func addNoteRow(_ note: NSTextField) -> SettingsFormRow {
        guard openCard == nil else { return add(SettingsFormRow(note: note)) }
        let row = SettingsFormRow(note: note, onCanvas: true)
        if stack.arrangedSubviews.isEmpty { row.sitAtTheTop() }
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return row
    }

    /// A note with one link in it.
    @discardableResult
    func addLinkNote(_ before: String, linkText: String, _ after: String, url: URL) -> SettingsFormRow {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Style.Fonts.settingsNote, .foregroundColor: Style.Colors.secondaryText
        ]
        let text = NSMutableAttributedString(string: before, attributes: attributes)
        text.append(NSAttributedString(string: linkText, attributes: [
            .font: Style.Fonts.settingsNote, .link: url, .foregroundColor: NSColor.linkColor
        ]))
        text.append(NSAttributedString(string: after, attributes: attributes))
        let note = NSTextField(wrappingLabelWithString: "")
        note.attributedStringValue = text
        note.allowsEditingTextAttributes = true
        note.isSelectable = true
        note.maximumNumberOfLines = 0
        return addNoteRow(note)
    }

    /// One view across the full width, centred: an icon and a name above a
    /// form, the way About panes open. It stands on its own rather than in a
    /// card, because a card around a single centred mark reads as a frame
    /// somebody forgot to take off.
    @discardableResult
    func addHero(_ hero: NSView) -> SettingsFormRow {
        openCard = nil
        cardBelongsToGroup = false
        let row = SettingsFormRow(hero: hero)
        if stack.arrangedSubviews.isEmpty { row.sitAtTheTop() }
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return row
    }

    /// Ends the current card. The next row starts a new one.
    @discardableResult
    func addSeparator() -> SettingsFormRow {
        openCard = nil
        cardBelongsToGroup = false
        radioGroup = nil
        // Nothing is drawn any more -- the gap between two cards is the
        // separator now -- but the panes expect a row back, and Spaces hides
        // one to fold a whole group away.
        return SettingsFormRow(spacer: ())
    }

    /// Pop-up buttons and text fields settle at one width, so every control on
    /// every pane shares a right edge -- and are dressed in the window's own
    /// surface rather than in AppKit's bezel.
    static func fill(_ control: NSView) -> NSView {
        if control is NSScrollView || control is NSTableView { return control }
        // A card handed to `fill` was being wrapped in a plate and pinned to
        // the control column: a card inside a card, 280 points wide, with the
        // rest of the row empty beside it. It comes back as itself.
        if let card = control as? SettingsCardView {
            card.beGroup()
            return card
        }
        // A pane's own list of rows -- the installed extensions -- is a block
        // of its own, not a value to be plated: "No extensions installed" in
        // a box that looked like a field you could type into.
        if let stack = control as? NSStackView, stack.orientation == .vertical { return stack }
        if let segmented = control as? NSSegmentedControl { return SettingsSegments(segmented: segmented) }
        // A read-only label is not a control and must not be dressed as one: a
        // plate around a line of status text reads as a field you can type in.
        if let field = control as? NSTextField, !field.isEditable {
            return SettingsFilledBox(control)
        }
        if let choice = choice(for: control) { return choice }
        if let field = control as? NSTextField, field.isEditable {
            return SettingsControlPlate(control, width: nil, fullWidth: true)
        }
        return SettingsControlPlate(control, width: Style.SettingsUI.controlWidth)
    }

    /// Our own dropdown, wearing the window's surface and opening the pane's
    /// own menu. Any length of menu: the list that drops is AppKit's, so twenty
    /// options scroll the way twenty options always have.
    private static func choice(for control: NSView) -> SettingsChoiceControl? {
        // An empty menu counts. A pane is free to hand over a pop-up it fills
        // in later -- Websites builds one and only adds the options when a
        // category is chosen -- and refusing it left that row wearing a plate
        // with the system's own bezel inside it, two chevrons and all.
        guard let popUp = control as? NSPopUpButton else { return nil }
        // The control takes the pop-up over as its own: it is both the model,
        // holding the selection and the pane's target and action, and the
        // invisible surface that catches the click.
        return SettingsChoiceControl(popUp: popUp)
    }

    /// Whether this is a control the window dresses itself.
    private static func needsPlate(_ view: NSView) -> Bool {
        if view.enclosingControlPlate != nil { return false }
        // A list is not a control. Plating one puts a card inside a card and
        // squeezes it into the width of a control column, which is what the
        // Spaces list was doing: four spaces in a bezelled box 280 points wide,
        // with the rest of the card empty beside it.
        if view is NSScrollView || view is NSTableView || view is SettingsCardView { return false }
        if view is NSPopUpButton { return true }
        if let field = view as? NSTextField { return field.isEditable }
        // A checkbox is already becoming a toggle, and an image button is
        // somebody's own artwork.
        if let button = view as? NSButton { return !button.isCheckboxLike && button.image == nil }
        return false
    }

    /// Everything else a pane hands over: a push button, a colour well, a
    /// stack of its own making. Buttons get the plate at their natural width;
    /// anything else is left alone, because the form cannot know what it is.
    private func dressed(_ control: NSView) -> NSView {
        if let segmented = control as? NSSegmentedControl { return SettingsSegments(segmented: segmented) }
        if let choice = Self.choice(for: control) { return choice }
        if Self.needsPlate(control) {
            return SettingsControlPlate(control, width: nil)
        }
        // A pane is free to hand over a stack of its own -- "Default space" is a
        // pop-up and a button side by side -- and the controls inside it are as
        // stock as any other. They are swapped in place, keeping their position
        // in the stack, so the pane's own layout is untouched.
        skinContents(of: control)
        return control
    }

    /// Whether a view inside a pane's own stack is one we take over.
    private static func dressable(_ view: NSView) -> Bool {
        if view is NSSegmentedControl { return true }
        if let button = view as? NSButton, button.isCheckboxLike || button.isRadioLike { return true }
        return needsPlate(view)
    }

    /// The face we put on it.
    private static func dressed(inStack view: NSView) -> NSView {
        if let segmented = view as? NSSegmentedControl { return SettingsSegments(segmented: segmented) }
        if let button = view as? NSButton, button.isCheckboxLike {
            return SettingsInlineSwitch(checkbox: button)
        }
        if let button = view as? NSButton, button.isRadioLike {
            return SettingsInlineRadio(radio: button)
        }
        return choice(for: view) ?? SettingsControlPlate(view, width: nil)
    }

    private func skinContents(of view: NSView) {
        guard let stack = view as? NSStackView else {
            for child in view.subviews { skinContents(of: child) }
            return
        }
        for child in stack.arrangedSubviews {
            guard Self.dressable(child),
                  let index = stack.arrangedSubviews.firstIndex(of: child)
            else {
                skinContents(of: child)
                continue
            }
            // Out of the stack before the new clothes are made, not after. A
            // plate and a dropdown both adopt the control as a subview of their
            // own, so taking it out of the stack afterwards takes it out of the
            // thing that was meant to be holding it -- which is how "Set
            // Default" came to be an empty plate with nothing in it.
            stack.removeArrangedSubview(child)
            child.removeFromSuperview()
            let replacement = Self.dressed(inStack: child)
            stack.insertArrangedSubview(replacement, at: index)
        }
    }

    // MARK: - Cards

    private func adaptor(for checkbox: NSButton) -> SettingsSwitchAdaptor {
        let adaptor = SettingsSwitchAdaptor(checkbox: checkbox)
        adaptors.append(adaptor)
        return adaptor
    }

    /// The radios added one after another, which choose among themselves.
    ///
    /// AppKit turns a radio's siblings off for it only while they share a
    /// superview, and each one is on a row of its own now. The rows a pane
    /// adds in a run are one choice; anything else between them ends it.
    private var radioGroup: SettingsInlineRadio.Group?

    @discardableResult
    private func add(_ row: SettingsFormRow) -> SettingsFormRow {
        if let radio = row.radio {
            let group = radioGroup ?? SettingsInlineRadio.Group()
            radioGroup = group
            group.add(radio)
        } else if !row.isNote {
            radioGroup = nil
        }
        add(row as NSView)
        return row
    }

    /// Any row onto the open card, opening one if there is none.
    private func add(_ row: NSView) {
        if !(row is SettingsFormRow) { radioGroup = nil }
        let card = openCard ?? {
            let card = SettingsCardView()
            cards.append(card)
            openCard = card
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return card
        }()
        card.add(row)
    }
}

extension NSButton {
    /// A button that carries a state rather than performing an action: a
    /// checkbox, as opposed to "Set to Current Page".
    ///
    /// Inferred from the cell, because there is nothing better to ask.
    /// `buttonType` is write-only on `NSButton`; the cell's `type` only says
    /// whether it draws text or an image; and `accessibilityRole` answers
    /// `AXUnknown` until the button is in a window, which is long after the
    /// form has had to decide. What is left is the pair of properties
    /// `setButtonType(.switch)` actually sets: no bezel, and the state shown by
    /// the cell's own contents.
    ///
    /// Asked of the cell, which knows: `AXCheckBox` for a checkbox and
    /// `AXRadioButton` for a radio. The button's own role answers `AXUnknown`
    /// outside a window, which is why this used to be guessed from the cell's
    /// border and state mask -- a guess a radio passed too, and a radio drawn
    /// as a switch is a lie: a switch says "this is independent", and a radio's
    /// whole meaning is that its siblings turn off with it.
    var isCheckboxLike: Bool {
        guard let cell = cell as? NSButtonCell, !cell.isBordered else { return false }
        return cell.accessibilityRole() == .checkBox
    }

    /// One of a set where choosing this one unchooses the rest.
    var isRadioLike: Bool {
        guard let cell = cell as? NSButtonCell, !cell.isBordered else { return false }
        return cell.accessibilityRole() == .radioButton
    }
}

/// The rounded plate a run of rows sits on, with a hairline between them.
@MainActor
final class SettingsCardView: SettingsPlateView {
    private let stack = NSStackView()
    /// Each hairline and the row it introduces, so a hidden row takes its own
    /// divider down with it rather than leaving a line floating in the card.
    private var separators: [(rule: NSView, follower: NSView)] = []
    private var rows: [NSView] = []

    /// Stops being a plate of its own.
    ///
    /// A card inside another card reads as a box somebody forgot to take off.
    /// The rows keep their tiles and their hairlines, which is all the grouping
    /// they need -- the plate around them was doing nothing but drawing a
    /// second edge inside the first.
    func beGroup() {
        fill = nil
        stroke = nil
        cornerRadius = 0
        needsDisplay = true
    }

    /// An empty card. `SettingsForm` makes one and fills it as a pane declares
    /// its settings.
    init() {
        super.init(frame: .zero)
        fill = Style.Colors.settingsGlass
        stroke = Style.Colors.settingsCardStroke
        cornerRadius = Style.SettingsUI.cardRadius
        // Clipped to the plate, so nothing inside it squares off the corners.
        layer?.masksToBounds = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    /// A card built all at once from rows that draw themselves.
    ///
    /// The other way in. A form grows a card row by row as a pane declares its
    /// settings; a pane that builds its own rows -- a list of extensions, a
    /// blocker's three toggles -- hands them over finished. Both end up on the
    /// same plate with the same hairlines, which is the whole reason there is
    /// one card type rather than two.
    convenience init(rows: [NSView]) {
        self.init()
        for row in rows { add(row) }
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsCardView is created in code only")
    }

    override var isFlipped: Bool { true }

    func add(_ row: NSView) {
        row.translatesAutoresizingMaskIntoConstraints = false
        if !rows.isEmpty {
            let holder = NSView()
            holder.translatesAutoresizingMaskIntoConstraints = false
            let line = SettingsHairlineView()
            holder.addSubview(line)
            NSLayoutConstraint.activate([
                holder.heightAnchor.constraint(equalToConstant: 1),
                line.topAnchor.constraint(equalTo: holder.topAnchor),
                line.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
                // Indented to the label's own edge, so the line reads as a
                // division inside the card rather than the card cut in two.
                line.leadingAnchor.constraint(
                    equalTo: holder.leadingAnchor,
                    constant: Style.SettingsUI.cardPadding
                ),
                line.trailingAnchor.constraint(equalTo: holder.trailingAnchor)
            ])
            stack.addArrangedSubview(holder)
            holder.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            separators.append((holder, row))
        }
        rows.append(row)
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    override func layout() {
        refresh()
        super.layout()
    }

    /// Also before drawing, not only on layout.
    ///
    /// A pane folds rows away by setting `isHidden` on them -- Spaces hides
    /// nine at a time. That invalidates the stack's layout but does not always
    /// dirty this card's, and a divider left drawn across a card whose rows
    /// have gone is the kind of thing nobody notices until they see it.
    override func viewWillDraw() {
        refresh()
        super.viewWillDraw()
    }

    private func refresh() {
        for row in rows { (row as? SettingsFormRow)?.followEmptiness() }
        updateSeparators()
        // A card whose every row is hidden must not leave its plate behind.
        isHidden = !rows.isEmpty && rows.allSatisfy(\.isHidden)
    }

    private func updateSeparators() {
        var anyVisibleAbove = false
        var index = 0
        for row in rows {
            defer { if !row.isHidden { anyVisibleAbove = true } }
            guard index < separators.count, separators[index].follower === row else { continue }
            // A row attached to the one above it -- a note, a second control
            // for the same setting -- is not divided from it.
            separators[index].rule.isHidden = row.isHidden
                || !anyVisibleAbove
                || (row as? SettingsFormRow)?.style == .attached
            index += 1
        }
    }
}

/// One row of a card.
@MainActor
final class SettingsFormRow: NSView {
    /// Whether the row is divided from the one above it.
    ///
    /// Named `RowStyle` rather than `Style` because a nested type by that name
    /// would shadow the app's own `Style` inside this class, and every metric
    /// in the layout below is read from it.
    enum RowStyle {
        case control
        /// Belongs with the row above: a note, or a second control for the
        /// same setting.
        case attached
        case hero
        /// A heading on the canvas, over the card that follows it.
        case header
        /// What `addSeparator` returns. It is in no card and no stack, so
        /// hiding it does nothing -- which is right, there is nothing there.
        case spacer
    }

    /// When the control drops below the label instead of sitting beside it.
    enum Stacking {
        case never
        case whenTight
        case always
    }

    let style: RowStyle
    /// The radio this row is, if it is one.
    var radio: SettingsInlineRadio? { control as? SettingsInlineRadio }
    /// Small print under a control, which does not break a run of radios.
    var isNote: Bool { control == nil && titleLabel == nil && noteLabel != nil }
    private let stacking: Stacking
    private let body = NSStackView()
    private var titleLabel: NSTextField?
    private var noteLabel: NSTextField?
    private var control: NSView?
    private var isStacked: Bool?
    private var topPadding: NSLayoutConstraint?
    /// A row that is nothing but its control goes where the control goes: a
    /// pane hides "Reset" or the custom DNS field, and a blank row with a
    /// hairline under it is not what it meant.
    private var visibility: NSKeyValueObservation?

    /// Whether a control under its label should run the width of the card
    /// rather than sit at its own size.
    ///
    /// Putting a control under its label is how a pane says "this is a thing in
    /// its own right" -- a list, a paragraph, a field for a URL -- and a thing
    /// in its own right takes the width of the card it is on. The exceptions
    /// are the controls that state one value: a button, a dropdown, a switch.
    /// Stretching those across the card would be worse than leaving them.
    private static func fillsTheRow(_ control: NSView) -> Bool {
        if let plate = control as? SettingsControlPlate { return plate.wantsFullWidth }
        if control is SettingsChoiceControl || control is SettingsToggle { return false }
        return true
    }

    /// The control as a paragraph, if that is what it is.
    private static func wrappingText(_ control: NSView) -> NSTextField? {
        guard let field = control as? NSTextField,
              !field.isEditable,
              field.maximumNumberOfLines == 0
        else { return nil }
        return field
    }

    /// A label, an optional second line, and a control.
    ///
    /// - Parameter titleField: the pane's own field as the label, where the
    ///   pane will change its words later. Takes the place of `label`.
    init(
        label: String,
        note: String? = nil,
        titleField: NSTextField? = nil,
        control: NSView,
        style: RowStyle,
        stacking: Stacking
    ) {
        self.style = style
        self.stacking = stacking
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false

        if let titleField {
            titleField.font = Style.Fonts.settingsRow
            titleField.textColor = Style.Colors.primaryText
            titleField.lineBreakMode = .byWordWrapping
            titleField.maximumNumberOfLines = 0
            titleField.translatesAutoresizingMaskIntoConstraints = false
            titleLabel = titleField
            text.addArrangedSubview(titleField)
        } else if !label.isEmpty {
            let title = NSTextField(wrappingLabelWithString: label)
            title.font = Style.Fonts.settingsRow
            title.textColor = Style.Colors.primaryText
            title.maximumNumberOfLines = 0
            titleLabel = title
            text.addArrangedSubview(title)
        }
        if let note, !note.isEmpty {
            let second = NSTextField(wrappingLabelWithString: note)
            second.font = Style.Fonts.settingsNote
            second.textColor = Style.Colors.secondaryText
            second.maximumNumberOfLines = 0
            noteLabel = second
            text.addArrangedSubview(second)
        }

        self.control = control
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        // A stack computes its own hugging from what is in it and ignores the
        // priority set on the view, so a group of two or three controls was
        // being stretched across the row and its contents packed against the
        // left edge -- "Status | Synced 1 min ago | Sync Now" with two thirds
        // of the card empty after it. `setHuggingPriority` is the one a stack
        // actually honours.
        if let group = control as? NSStackView, stacking != .always {
            group.setHuggingPriority(.required, for: .horizontal)
        }

        body.orientation = .horizontal
        body.alignment = .centerY
        body.spacing = Style.SettingsUI.rowGap
        // `.fill`, not the default `.gravityAreas`. Under gravity areas the
        // stack packs everything against the leading edge at its natural size,
        // which is why the controls used to sit immediately after their labels
        // with the rest of the card empty to their right. Filling hands the
        // slack to whichever view hugs least -- the label -- so every control
        // on a pane lands on one right-hand edge.
        body.distribution = .fill
        body.translatesAutoresizingMaskIntoConstraints = false
        if titleLabel != nil || noteLabel != nil {
            body.addArrangedSubview(text)
            text.setContentHuggingPriority(.defaultLow, for: .horizontal)
            // The one a stack honours (see above). Without it the text and
            // the control tie, and which of the two takes the slack is the
            // solver's choice: in one build the radio marks sat at the
            // trailing edge, in the next they sat a gap after their labels.
            text.setHuggingPriority(.init(1), for: .horizontal)
        }
        body.addArrangedSubview(control)
        if titleLabel == nil && noteLabel == nil {
            // A second control belonging to the row above -- "Set to Current
            // Page" under the homepage field, "Manage Extensions..." under the
            // two switches -- sits at the left edge under the thing it belongs
            // to. It used to be pushed to the right-hand edge, which was right
            // when every control lived in a column over there and is wrong now
            // that a group runs the width of the card from the left.
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            body.addArrangedSubview(spacer)
        }
        // Settled here rather than left to the first `layout`, so a row that
        // was always going to stack never spends a pass laid out the other way
        // -- and so the full-width constraint below is never applied to a
        // horizontal stack, where it cannot be satisfied.
        if stacking == .always {
            isStacked = true
            stack(body, true)
        }
        if stacking == .always || (control as? SettingsControlPlate)?.wantsFullWidth == true,
           Self.fillsTheRow(control) {
            control.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        install(minHeight: Style.SettingsUI.rowMinHeight)
        if titleLabel == nil && noteLabel == nil {
            visibility = follows(control)
        }
    }

    /// A heading, on the canvas, over the card it names.
    init(header: String) {
        self.style = .header
        self.stacking = .always
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: header)
        title.font = Style.Fonts.settingsSection
        title.textColor = Style.Colors.primaryText
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        titleLabel = title
        body.orientation = .vertical
        body.alignment = .leading
        body.translatesAutoresizingMaskIntoConstraints = false
        body.addArrangedSubview(title)
        // No air of its own: the gap the form leaves above it is the air, and
        // a heading at the top of a pane sits exactly where a card would.
        install(minHeight: 0, topPadding: 0, bottomPadding: 0)
        setAccessibilityRole(.group)
        setAccessibilityLabel(header)
    }

    /// The whole row chooses, where the control is a radio: a sixteen-point
    /// ring at the far edge is not a target.
    override func mouseDown(with event: NSEvent) {
        if let radio = control as? SettingsInlineRadio {
            radio.choose()
        } else {
            super.mouseDown(with: event)
        }
    }

    /// A note on its own, spanning the row.
    ///
    /// - Parameter onCanvas: the note stands under a card rather than inside
    ///   one, and needs air above it of its own.
    init(note: NSTextField, onCanvas: Bool = false) {
        self.style = .attached
        self.stacking = .always
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        note.translatesAutoresizingMaskIntoConstraints = false
        noteLabel = note
        body.orientation = .vertical
        body.alignment = .leading
        body.translatesAutoresizingMaskIntoConstraints = false
        body.addArrangedSubview(note)
        // No minimum: a note is as tall as its words and no taller, and inside
        // a card it sits tight under the control it explains.
        install(minHeight: 0, topPadding: onCanvas ? Style.SettingsUI.rowVerticalPadding : 0)
    }

    /// A centred block across the whole width.
    init(hero: NSView) {
        self.style = .hero
        self.stacking = .always
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        hero.translatesAutoresizingMaskIntoConstraints = false
        body.orientation = .vertical
        body.alignment = .centerX
        body.translatesAutoresizingMaskIntoConstraints = false
        body.addArrangedSubview(hero)
        install(minHeight: 0, horizontalPadding: 0)
    }

    /// What `addSeparator` hands back: nothing at all.
    init(spacer: Void) {
        self.style = .spacer
        self.stacking = .never
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsFormRow is created in code only")
    }

    override var isFlipped: Bool { true }

    private func install(
        minHeight: CGFloat,
        topPadding: CGFloat = Style.SettingsUI.rowVerticalPadding,
        bottomPadding: CGFloat = Style.SettingsUI.rowVerticalPadding,
        horizontalPadding: CGFloat = Style.SettingsUI.cardPadding
    ) {
        addSubview(body)
        let top = body.topAnchor.constraint(equalTo: topAnchor, constant: topPadding)
        self.topPadding = top
        var constraints: [NSLayoutConstraint] = [
            top,
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalPadding),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomPadding)
        ]
        if minHeight > 0 {
            constraints.append(heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight))
        }
        NSLayoutConstraint.activate(constraints)
    }

    /// A note with nothing in it takes no room.
    ///
    /// A pane keeps a status line under a card and fills it in when there is
    /// something to say -- the Extensions pane's, most of the time, says
    /// nothing -- and an empty row at the foot of a card reads as a card that
    /// did not finish loading. Hidden by us is remembered, so a note the pane
    /// hid itself is left alone and one we hid comes back when it has words.
    private var hiddenForBeingEmpty = false
    func followEmptiness() {
        guard control == nil, titleLabel == nil, let note = noteLabel else { return }
        let empty = note.stringValue.isEmpty && note.attributedStringValue.length == 0
        if empty, !isHidden {
            isHidden = true
            hiddenForBeingEmpty = true
        } else if !empty, hiddenForBeingEmpty {
            isHidden = false
            hiddenForBeingEmpty = false
        }
    }

    /// Starts flush with the top of the pane.
    ///
    /// A card carries its own top edge, and every pane's first card lines up.
    /// A hero or a lone note has no plate under it, so its own ten points of
    /// air put it ten points lower than the cards on every other pane -- which
    /// is exactly the kind of near-miss that makes a window look untidy without
    /// anyone being able to say why.
    func sitAtTheTop() {
        topPadding?.constant = 0
    }

    /// Decides, at the width the row actually got, whether the label and the
    /// control still fit on one line.
    ///
    /// Measured rather than guessed. A pane is free to put a colour picker, a
    /// path or a paragraph in the control slot, and the only honest way to know
    /// whether the pair fits is to ask them both how wide they are once the
    /// window has settled on a width.
    override func layout() {
        applyStacking()
        let available = bounds.width - Style.SettingsUI.cardPadding * 2
        if let paragraph = control.flatMap(Self.wrappingText),
           available > 0,
           abs(paragraph.preferredMaxLayoutWidth - available) > 0.5 {
            paragraph.preferredMaxLayoutWidth = available
            paragraph.invalidateIntrinsicContentSize()
        }
        // Against the control's real width, not the control column's. A switch
        // is thirty-eight points wide, and a label held to what is left beside
        // a two-hundred-and-eighty-point column wrapped onto a second line
        // with half the row still empty.
        let controlWidth = control.map { $0.fittingSize.width } ?? 0
        for label in [titleLabel, noteLabel].compactMap({ $0 }) {
            let width = isStacked == false
                ? max(120, available - max(controlWidth, 1) - Style.SettingsUI.rowGap)
                : available
            if width > 0, abs(label.preferredMaxLayoutWidth - width) > 0.5 {
                label.preferredMaxLayoutWidth = width
                label.invalidateIntrinsicContentSize()
            }
        }
        super.layout()
    }

    private func applyStacking() {
        guard style != .spacer, let control else { return }
        let wanted: Bool
        switch stacking {
        case .never: wanted = false
        case .always: wanted = true
        case .whenTight:
            let labelWidth = titleLabel.map { $0.intrinsicContentSize.width } ?? 0
            let needed = labelWidth + control.fittingSize.width + Style.SettingsUI.rowGap
                + Style.SettingsUI.cardPadding * 2
            // Sticky in one direction: unstacking only once there is room to
            // spare, so a row does not flutter between the two at the boundary.
            wanted = isStacked == true ? needed > bounds.width - 20 : needed > bounds.width
        }
        guard wanted != isStacked else { return }
        isStacked = wanted
        stack(body, wanted)
    }

    private func stack(_ body: NSStackView, _ stacked: Bool) {
        body.orientation = stacked ? .vertical : .horizontal
        body.alignment = stacked ? .leading : .centerY
        // Stacked, the control sits under the label at its own width; filling
        // a vertical stack would stretch it down the row instead.
        body.distribution = stacked ? .gravityAreas : .fill
        body.spacing = stacked ? 8 : Style.SettingsUI.rowGap
    }
}

/// A pane that used to bring its own scroll view. The detail side scrolls now,
/// so this is a plain wrapper: two scroll views nested inside each other is how
/// a pane ends up with a scroller that moves nothing.
@MainActor
final class SettingsScrollingPane: NSView {
    let form: SettingsForm

    init(form: SettingsForm) {
        self.form = form
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        form.translatesAutoresizingMaskIntoConstraints = false
        addSubview(form)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: topAnchor),
            form.leadingAnchor.constraint(equalTo: leadingAnchor),
            form.trailingAnchor.constraint(equalTo: trailingAnchor),
            form.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsScrollingPane is created in code only")
    }

    override var isFlipped: Bool { true }
}

extension NSView {
    /// The card this view sits on, if any.
    var enclosingCard: SettingsCardView? {
        var view: NSView? = superview
        while let current = view {
            if let card = current as? SettingsCardView { return card }
            view = current.superview
        }
        return nil
    }

    /// The control plate this view sits on, if any.
    var enclosingControlPlate: SettingsControlPlate? {
        var view: NSView? = superview
        while let current = view {
            if let plate = current as? SettingsControlPlate { return plate }
            view = current.superview
        }
        return nil
    }
}
