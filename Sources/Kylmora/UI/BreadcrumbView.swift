import AppKit

/// The title control that stands where a browser normally puts its address
/// bar: `Site Name / Page Title`.
///
/// This shows what the page *is*, not where it lives, and Kylmora already has
/// a deliberate position on that trade-off: a chrome element that hides the
/// URL is a phishing surface unless the real address stays one action away.
/// So this control is a button, not a label --
/// activating it is what the integrator wires to the omnibox -- and the full
/// URL is always in its tooltip and its accessibility value.
@MainActor
final class BreadcrumbView: NSView {
    /// Clicking the breadcrumb; the caller reveals the real address.
    var onActivate: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityElement(false)
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Style.Metrics.iconButtonSide)
        ])

        setAccessibilityRole(.button)
        setAccessibilityLabel("Page address")
        // The whole point of the control is that it is smaller than a URL bar;
        // it must be allowed to lose the argument with the action buttons.
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("BreadcrumbView is created in code only")
    }

    /// - Parameters:
    ///   - site: the human name of the site. Pass `nil` when nothing better
    ///     than the host is known; the separator disappears with it rather
    ///     than leaving a stray slash.
    ///   - title: the page title, or the host if the page has not given one.
    ///   - address: the real URL, shown on hover and read by VoiceOver. Passing
    ///     `nil` leaves the control with no address to disclose, which is the
    ///     honest state for an empty tab.
    func show(site: String?, title: String, address: String?) {
        let text = NSMutableAttributedString()
        let site = site?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let site, !site.isEmpty {
            text.append(NSAttributedString(string: site, attributes: [
                .font: Style.Fonts.body,
                .foregroundColor: Style.Colors.secondaryText
            ]))
            text.append(NSAttributedString(string: " / ", attributes: [
                .font: Style.Fonts.body,
                .foregroundColor: Style.Colors.tertiaryText
            ]))
        }
        text.append(NSAttributedString(string: title, attributes: [
            .font: Style.Fonts.body,
            .foregroundColor: Style.Colors.primaryText
        ]))

        label.attributedStringValue = text
        toolTip = address
        setAccessibilityValue(address ?? title)
        setAccessibilityLabel(accessibilityDescription(site: site, title: title))
        isEnabled = address != nil
    }

    /// Greyed out and click-through when there is no page to talk about.
    private(set) var isEnabled = true {
        didSet {
            label.alphaValue = isEnabled ? 1 : 0.5
            needsDisplay = true
        }
    }

    private func accessibilityDescription(site: String?, title: String) -> String {
        guard let site, !site.isEmpty else { return title }
        return "\(title), on \(site)"
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered && isEnabled else { return }
        Style.Colors.rowHoverFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
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

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onActivate?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onActivate?()
        return true
    }
}
