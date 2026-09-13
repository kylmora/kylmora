import AppKit

/// The zoom control in the top bar: minus, the live percentage, plus.
///
/// One grouped control rather than two loose buttons, because zooming means
/// little without seeing where it lands. Clicking the percentage snaps the page
/// back to 100%.
@MainActor
final class ZoomControl: NSView {
    let zoomOut = IconButton(symbolName: "minus.magnifyingglass", label: "Zoom Out")
    let zoomIn = IconButton(symbolName: "plus.magnifyingglass", label: "Zoom In")

    /// Clicking the percentage resets the page to 100%.
    var onReset: (() -> Void)?

    private let percentButton = NSButton(title: "100%", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        percentButton.isBordered = false
        percentButton.setButtonType(.momentaryChange)
        percentButton.target = self
        percentButton.action = #selector(reset)
        percentButton.setAccessibilityLabel("Zoom level")
        percentButton.toolTip = "Reset zoom to 100%"
        percentButton.translatesAutoresizingMaskIntoConstraints = false
        percentButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        setPercent(100)

        let stack = NSStackView(views: [zoomOut, percentButton, zoomIn])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("ZoomControl is created in code only") }

    /// The current zoom, as a whole-number percentage. Shown only when the page
    /// is actually zoomed: at 100% the readout hides and the buttons close up,
    /// so the default carries no clutter.
    func setPercent(_ percent: Int) {
        percentButton.isHidden = (percent == 100)
        percentButton.attributedTitle = NSAttributedString(string: "\(percent)%", attributes: [
            .foregroundColor: Style.Colors.secondaryText,
            .font: Style.Fonts.body
        ])
    }

    @objc private func reset() { onReset?() }
}
