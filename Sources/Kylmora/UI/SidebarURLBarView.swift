import AppKit

/// Arc-style clickable URL pill at the top of the sidebar.
///
/// Shows the active page's clean host/domain inside a subtle translucent pill.
/// Clicking the pill opens the Command Bar; hovering reveals a one-click Copy URL
/// button that copies the cleaned address and flashes a checkmark confirmation.
@MainActor
final class SidebarURLBarView: NSView {
    var onActivate: (() -> Void)?
    var onCopyURL: (() -> Void)?

    private let backgroundLayer = CALayer()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "Search or enter URL...")
    private let copyButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var hasURL = false
    private var copyResetTask: Task<Void, Never>?

    static let height: CGFloat = 30

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        backgroundLayer.cornerRadius = Style.Metrics.rowCornerRadius
        backgroundLayer.borderWidth = Style.Metrics.hairline
        layer?.addSublayer(backgroundLayer)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        addSubview(iconView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.textColor = .tertiaryLabelColor
        for v in [label, self] as [NSView] {
            v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            v.setContentHuggingPriority(.init(1), for: .horizontal)
        }
        addSubview(label)

        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.isBordered = false
        copyButton.bezelStyle = .inline
        copyButton.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Copy URL")
        copyButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        copyButton.contentTintColor = .secondaryLabelColor
        copyButton.toolTip = "Copy URL (⇧⌘C)"
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.isHidden = true
        addSubview(copyButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -4),

            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            copyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 22),
            copyButton.heightAnchor.constraint(equalToConstant: 22),
        ])

        setAccessibilityRole(.button)
        setAccessibilityLabel("Address bar")
        setAccessibilityElement(true)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("SidebarURLBarView is created in code only")
    }

    /// Formats a URL into Arc's clean sidebar pill text.
    static func displayText(for url: URL?) -> String {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var host = url.host(), !host.isEmpty else {
            return "Search or enter URL..."
        }
        if host.lowercased().hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }
        return host
    }

    func update(url: URL?) {
        let text = Self.displayText(for: url)
        let scheme = url?.scheme?.lowercased()
        hasURL = (scheme == "http" || scheme == "https") && !(url?.host()?.isEmpty ?? true)

        label.stringValue = text
        label.textColor = hasURL ? .labelColor : .tertiaryLabelColor

        let symbol: String
        if scheme == "https" {
            symbol = "lock.fill"
        } else if hasURL {
            symbol = "globe"
        } else {
            symbol = "magnifyingglass"
        }
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        copyButton.isHidden = !(hasURL && isHovered)
        toolTip = hasURL ? url?.absoluteString : "Search or enter URL (⌘L)"
        setAccessibilityValue(hasURL ? text : "Empty")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.frame = bounds
        CATransaction.commit()
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
        copyButton.isHidden = !hasURL
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        copyButton.isHidden = true
        updateAppearance()
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if !copyButton.isHidden, copyButton.frame.contains(point) { return }
        onActivate?()
    }

    @objc private func copyClicked() {
        onCopyURL?()
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        copyButton.contentTintColor = .systemGreen
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.copyButton.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Copy URL")
            self.copyButton.contentTintColor = .secondaryLabelColor
        }
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fillAlpha: CGFloat = isHovered ? 0.11 : 0.06
            let borderAlpha: CGFloat = isHovered ? 0.14 : 0.08
            backgroundLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(fillAlpha).cgColor
            backgroundLayer.borderColor = NSColor.labelColor.withAlphaComponent(borderAlpha).cgColor
        }
    }
}
