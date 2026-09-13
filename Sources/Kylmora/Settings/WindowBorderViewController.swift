import AppKit

/// The sheet behind "Customize…" on a space's window border: Orion's
/// Window Borders sheet, with the same four styles, two sliders and grid
/// of colour runs, edited live on the window and taken back on Cancel.
@MainActor
final class WindowBorderViewController: NSViewController {
    private let session: BrowserSession
    private let space: Space
    private let original: WindowBorder

    private let style = NSSegmentedControl(
        labels: WindowBorder.Style.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil
    )
    private let thickness = SettingsStopSlider(stops: WindowBorder.Thickness.allCases.map(\.title), width: 340)
    private let animation = SettingsStopSlider(stops: ["symbol:snowflake", "symbol:tortoise", "symbol:hare"], width: 340)
    private let palette = WindowBorderPalettePicker()

    init(session: BrowserSession, space: Space) {
        self.session = session
        self.space = space
        self.original = space.border
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("WindowBorderViewController is created in code only")
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root

        let title = NSTextField(labelWithString: "Window Border")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "For the space \u{201c}\(space.name)\u{201d}")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 2

        let rule = NSBox()
        rule.boxType = .separator

        style.target = self
        style.action = #selector(changed)
        style.segmentStyle = .capsule
        style.segmentDistribution = .fillEqually
        style.setAccessibilityLabel("Window border")
        style.translatesAutoresizingMaskIntoConstraints = false

        thickness.slider.setAccessibilityLabel("Border thickness")
        thickness.onChange = { [weak self] _ in self?.changed() }
        animation.slider.setAccessibilityLabel("Border animation")
        animation.onChange = { [weak self] _ in self?.changed() }
        palette.onSelect = { [weak self] _ in self?.changed() }

        let form = NSGridView(views: [
            [Self.label("Border Thickness"), thickness],
            [Self.label("Border Animation"), animation]
        ])
        form.rowSpacing = 18
        form.columnSpacing = 16
        form.rowAlignment = .none
        form.yPlacement = .center
        form.column(at: 0).xPlacement = .leading
        form.column(at: 0).width = 150
        form.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let done = NSButton(title: "Done", target: self, action: #selector(finish))
        done.keyEquivalent = "\r"
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.addView(cancel, in: .trailing)
        buttons.addView(done, in: .trailing)
        buttons.translatesAutoresizingMaskIntoConstraints = false

        // The grid is narrower than the sheet; it sits in the middle of it.
        let paletteRow = NSView()
        paletteRow.translatesAutoresizingMaskIntoConstraints = false
        paletteRow.addSubview(palette)

        let column = NSStackView(views: [heading, rule, style, form, paletteRow, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 22
        column.setCustomSpacing(14, after: heading)
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            rule.widthAnchor.constraint(equalTo: column.widthAnchor),
            style.widthAnchor.constraint(equalTo: column.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: column.widthAnchor),
            paletteRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            palette.centerXAnchor.constraint(equalTo: paletteRow.centerXAnchor),
            palette.topAnchor.constraint(equalTo: paletteRow.topAnchor),
            palette.bottomAnchor.constraint(equalTo: paletteRow.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 520)
        ])

        show(original)
    }

    private static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14)
        return label
    }

    private func show(_ border: WindowBorder) {
        style.selectedSegment = WindowBorder.Style.allCases.firstIndex(of: border.style) ?? 0
        thickness.stop = WindowBorder.Thickness.allCases.firstIndex(of: border.thickness) ?? 0
        animation.stop = WindowBorder.Animation.allCases.firstIndex(of: border.animation) ?? 0
        palette.show(border.palette)
        thickness.isEnabled = border.isVisible
        animation.isEnabled = border.style == .gradient
        palette.isEnabled = border.style == .solid || border.style == .gradient
        palette.showSolid(border.style == .solid)
    }

    private var edited: WindowBorder {
        let styles = WindowBorder.Style.allCases
        let thicknesses = WindowBorder.Thickness.allCases
        let animations = WindowBorder.Animation.allCases
        return WindowBorder(
            style: styles[min(max(style.selectedSegment, 0), styles.count - 1)],
            thickness: thicknesses[min(max(thickness.stop, 0), thicknesses.count - 1)],
            animation: animations[min(max(animation.stop, 0), animations.count - 1)],
            palette: palette.selected
        )
    }

    /// Every change goes straight to the window, so the sheet is a preview
    /// of what Done will keep.
    @objc private func changed() {
        let border = edited
        session.setBorder(border, for: space)
        show(border)
    }

    @objc private func cancel() {
        session.setBorder(original, for: space)
        dismiss(nil)
    }

    @objc private func finish() {
        dismiss(nil)
    }
}
