import AppKit

/// Shown in place of a page that failed to load.
///
/// A native view rather than injected HTML: a page cannot draw over it, its
/// text cannot be mistaken for site content, and it needs no `data:` URL that
/// would end up in history and the address bar.
final class ErrorPageView: NSView {
    var onRetry: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let addressLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Try Again", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        iconView.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 30, weight: .regular)
        iconView.contentTintColor = .secondaryLabelColor

        // Wrapping, not truncating: a long host name is exactly the case where
        // the reader most needs to see the whole address.
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.preferredMaxLayoutWidth = 380

        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.preferredMaxLayoutWidth = 380

        addressLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        addressLabel.textColor = .tertiaryLabelColor
        addressLabel.lineBreakMode = .byTruncatingMiddle

        retryButton.target = self
        retryButton.action = #selector(retry)
        retryButton.keyEquivalent = "\r"

        let stack = NSStackView(views: [iconView, titleLabel, messageLabel, addressLabel, retryButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(18, after: addressLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("ErrorPageView is created in code only")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyBackground()
    }

    private func applyBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    func configure(with failure: NavigationFailure, url: URL?) {
        titleLabel.stringValue = failure.title
        messageLabel.stringValue = failure.message
        addressLabel.stringValue = url.map(AddressFormatter.display) ?? ""
        addressLabel.isHidden = url == nil
        retryButton.isHidden = !failure.isRetryable

        setAccessibilityLabel("\(failure.title). \(failure.message)")
    }

    @objc private func retry() {
        onRetry?()
    }
}
