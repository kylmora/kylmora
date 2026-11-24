import AppKit

/// Arc-style horizontal divider between the Pinned / Favorites section and
/// Today's unpinned tabs, with hover-revealed Tidy and Clear actions.
@MainActor
final class SidebarSpaceDividerView: NSView {
    var onClear: (() -> Void)?
    var onTidy: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "TODAY")
    private let rule = NSView()
    private let tidyButton = NSButton()
    private let clearButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private var clearableCount = 0
    private var isHovered = false

    static let height: CGFloat = 22

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        titleLabel.textColor = .tertiaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(titleLabel)

        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.wantsLayer = true
        addSubview(rule)

        tidyButton.translatesAutoresizingMaskIntoConstraints = false
        tidyButton.isBordered = false
        tidyButton.bezelStyle = .inline
        tidyButton.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Tidy Tabs")
        tidyButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .medium)
        tidyButton.contentTintColor = .secondaryLabelColor
        tidyButton.toolTip = "Tidy Today tabs into folders"
        tidyButton.target = self
        tidyButton.action = #selector(tidyClicked)
        tidyButton.isHidden = true
        addSubview(tidyButton)

        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.isBordered = false
        clearButton.bezelStyle = .inline
        clearButton.title = "Clear"
        clearButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.toolTip = "Clear unpinned Today tabs to Archive"
        clearButton.target = self
        clearButton.action = #selector(clearClicked)
        clearButton.isHidden = true
        addSubview(clearButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            rule.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            rule.trailingAnchor.constraint(equalTo: tidyButton.leadingAnchor, constant: -6),
            rule.centerYAnchor.constraint(equalTo: centerYAnchor),
            rule.heightAnchor.constraint(equalToConstant: Style.Metrics.hairline),

            tidyButton.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -4),
            tidyButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("SidebarSpaceDividerView is created in code only")
    }

    func update(spaceName: String, clearableCount: Int) {
        self.clearableCount = clearableCount
        let trimmed = spaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        titleLabel.stringValue = trimmed.isEmpty ? "TODAY" : trimmed.uppercased()
        updateButtonVisibility()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateButtonVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateButtonVisibility()
    }

    private func updateButtonVisibility() {
        clearButton.isHidden = !(clearableCount > 0 && isHovered)
        tidyButton.isHidden = !(clearableCount >= 4 && isHovered)
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            rule.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        }
    }

    @objc private func clearClicked() { onClear?() }
    @objc private func tidyClicked() { onTidy?() }
}
