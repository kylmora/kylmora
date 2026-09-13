import AppKit

/// The classic preferences form: a column of right-aligned labels ending in
/// a colon, and a column of controls, with notes under controls and hairlines
/// between groups. What Safari's and Orion's panes look like, and what the
/// user asked for by name.
///
/// A grid rather than stacks of rows, so every label in a pane shares one
/// right edge and every control one left edge, whatever the longest label
/// happens to be.
@MainActor
final class SettingsForm: NSView {
    /// Width of the label column. Fixed rather than fitted, so panes line up
    /// with each other as the toolbar switches between them.
    static let labelWidth: CGFloat = 230
    static let controlWidth: CGFloat = 420

    private let grid = NSGridView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 10
        grid.rowAlignment = .firstBaseline
        // Two empty columns to start with; rows fill them.
        grid.addColumn(with: [])
        grid.addColumn(with: [])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = Self.labelWidth
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 1).width = Self.controlWidth
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsForm is created in code only")
    }

    /// Top-down, so a form inside a scroll view starts at its top rather
    /// than scrolled to wherever a bottom-up origin lands.
    override var isFlipped: Bool { true }

    /// How a row's label lines up with its control.
    enum RowAlignment {
        /// The label's baseline on the control's first baseline: right for
        /// text fields, pop-ups, checkboxes and anything else with text.
        case baseline
        /// The label centred on the control: for a row of swatches or a
        /// slider, which have no baseline to speak of, and where a label
        /// on the baseline floats above the control.
        case center
        /// The label at the top: for a tall control such as a list or a
        /// grid, where the label belongs with the first row of it.
        case top
    }

    /// A label and one control.
    @discardableResult
    func addRow(_ label: String, _ control: NSView, alignment: RowAlignment = .baseline) -> NSGridRow {
        let text = NSTextField(labelWithString: label.isEmpty ? "" : "\(label):")
        text.alignment = .right
        text.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = grid.addRow(with: [text, control])
        var alignment = alignment
        if let stack = control as? NSStackView, stack.orientation == .vertical { alignment = .top }
        switch alignment {
        case .baseline:
            break
        case .center:
            row.rowAlignment = .none
            row.yPlacement = .center
        case .top:
            row.rowAlignment = .none
            row.yPlacement = .top
        }
        return row
    }

    /// A label and several controls side by side.
    @discardableResult
    func addRow(_ label: String, _ controls: [NSView]) -> NSGridRow {
        let stack = NSStackView(views: controls)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return addRow(label, stack)
    }

    /// A control with nothing in the label column, for a second control
    /// under the first.
    @discardableResult
    func addContinuation(_ control: NSView) -> NSGridRow {
        let row = grid.addRow(with: [NSGridCell.emptyContentView, control])
        row.topPadding = -4
        return row
    }

    /// Small secondary text under a control.
    @discardableResult
    func addNote(_ text: String) -> NSGridRow {
        addNote(NSTextField(wrappingLabelWithString: text))
    }

    /// A pane's own label as a note, so it can change the text later.
    @discardableResult
    func addNote(_ note: NSTextField) -> NSGridRow {
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = Self.controlWidth
        note.translatesAutoresizingMaskIntoConstraints = false
        note.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
        let row = grid.addRow(with: [NSGridCell.emptyContentView, note])
        row.topPadding = -6
        return row
    }

    /// A note with one link in it.
    @discardableResult
    func addLinkNote(_ before: String, linkText: String, _ after: String, url: URL) -> NSGridRow {
        let text = NSMutableAttributedString(string: before, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor
        ])
        text.append(NSAttributedString(string: linkText, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .link: url, .foregroundColor: NSColor.linkColor
        ]))
        text.append(NSAttributedString(string: after, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor
        ]))
        let note = NSTextField(labelWithAttributedString: text)
        note.allowsEditingTextAttributes = true
        note.isSelectable = true
        let row = grid.addRow(with: [NSGridCell.emptyContentView, note])
        row.topPadding = -6
        return row
    }

    /// One view across both columns, centred: an icon and a name above a
    /// form, the way About panes open.
    @discardableResult
    func addHero(_ hero: NSView) -> NSGridRow {
        hero.translatesAutoresizingMaskIntoConstraints = false
        let row = grid.addRow(with: [hero])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        row.rowAlignment = .none
        row.cell(at: 0).xPlacement = .center
        row.bottomPadding = 4
        return row
    }

    /// A hairline across both columns, with air around it.
    @discardableResult
    func addSeparator() -> NSGridRow {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        let row = grid.addRow(with: [line])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        row.topPadding = 8
        row.bottomPadding = 8
        row.rowAlignment = .none
        return row
    }

    /// Pop-up buttons and text fields fill the control column, the way the
    /// classic panes draw them.
    static func fill(_ control: NSView) -> NSView {
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true
        return control
    }
}

/// A pane too tall for the screen, in a scroll view that still reports the
/// form's own height, so the window sizes to the form where it fits and
/// scrolls where it does not.
@MainActor
final class SettingsScrollingPane: NSScrollView {
    let form: SettingsForm

    init(form: SettingsForm) {
        self.form = form
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        documentView = form
        form.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: contentView.topAnchor),
            form.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            form.widthAnchor.constraint(equalTo: contentView.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsScrollingPane is created in code only")
    }

    override var fittingSize: NSSize {
        form.layoutSubtreeIfNeeded()
        return form.fittingSize
    }
}
