import AppKit
import LocalAuthentication

/// Full-window blur overlay that blocks interaction and obscures web content while Kylmora is locked.
@MainActor
public final class LockOverlayView: NSVisualEffectView {
    public var onBiometricUnlockRequested: (() -> Void)?
    public var onPasswordUnlockRequested: ((String) -> Bool)?

    private let cardView = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Kylmora is Locked")
    private let subtitleLabel = NSTextField(labelWithString: "Authentication is required to view tabs and browsing data.")
    private let touchIDButton = NSButton(title: "Unlock with Touch ID", target: nil, action: nil)
    private let passwordField = NSSecureTextField()
    private let unlockButton = NSButton(title: "Unlock", target: nil, action: nil)
    private let errorLabel = NSTextField(labelWithString: "")
    private let quitButton = NSButton(title: "Quit Kylmora", target: nil, action: nil)

    public init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true

        setupViews()
        applyMethod(Settings.shared.browserLockMethod)
    }

    public required init?(coder: NSCoder) {
        fatalError("LockOverlayView is created programmatically")
    }

    private func setupViews() {
        // Scrim layer to guarantee full opacity over content
        let scrim = NSBox()
        scrim.boxType = .custom
        scrim.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.4)
        scrim.borderWidth = 0
        scrim.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrim)

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.wantsLayer = true
        addSubview(cardView)

        let lockConfig = NSImage.SymbolConfiguration(pointSize: 52, weight: .semibold)
        let lockImage = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: "Lock")?
            .withSymbolConfiguration(lockConfig)
        iconView.image = lockImage
        iconView.contentTintColor = .controlAccentColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        touchIDButton.bezelStyle = .rounded
        touchIDButton.controlSize = .large
        touchIDButton.font = .systemFont(ofSize: 14, weight: .medium)
        touchIDButton.keyEquivalent = "\r"
        touchIDButton.target = self
        touchIDButton.action = #selector(touchIDClicked)
        touchIDButton.translatesAutoresizingMaskIntoConstraints = false

        passwordField.placeholderString = "Enter Master Password"
        passwordField.font = .systemFont(ofSize: 14)
        passwordField.target = self
        passwordField.action = #selector(passwordEntered)
        passwordField.translatesAutoresizingMaskIntoConstraints = false

        unlockButton.bezelStyle = .rounded
        unlockButton.controlSize = .regular
        unlockButton.keyEquivalent = "\r"
        unlockButton.target = self
        unlockButton.action = #selector(passwordEntered)
        unlockButton.translatesAutoresizingMaskIntoConstraints = false

        errorLabel.font = .systemFont(ofSize: 12, weight: .medium)
        errorLabel.textColor = .systemRed
        errorLabel.alignment = .center
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        quitButton.bezelStyle = .inline
        quitButton.isBordered = false
        quitButton.font = .systemFont(ofSize: 12)
        quitButton.contentTintColor = .secondaryLabelColor
        quitButton.target = self
        quitButton.action = #selector(quitClicked)
        quitButton.translatesAutoresizingMaskIntoConstraints = false

        let passwordStack = NSStackView(views: [passwordField, unlockButton])
        passwordStack.orientation = .horizontal
        passwordStack.spacing = 8
        passwordStack.translatesAutoresizingMaskIntoConstraints = false

        cardView.addSubview(iconView)
        cardView.addSubview(titleLabel)
        cardView.addSubview(subtitleLabel)
        cardView.addSubview(touchIDButton)
        cardView.addSubview(passwordStack)
        cardView.addSubview(errorLabel)
        cardView.addSubview(quitButton)

        NSLayoutConstraint.activate([
            scrim.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrim.topAnchor.constraint(equalTo: topAnchor),
            scrim.bottomAnchor.constraint(equalTo: bottomAnchor),

            cardView.centerXAnchor.constraint(equalTo: centerXAnchor),
            cardView.centerYAnchor.constraint(equalTo: centerYAnchor),
            cardView.widthAnchor.constraint(equalToConstant: 380),

            iconView.topAnchor.constraint(equalTo: cardView.topAnchor),
            iconView.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20),
            subtitleLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20),

            touchIDButton.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 24),
            touchIDButton.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            touchIDButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            touchIDButton.heightAnchor.constraint(equalToConstant: 34),

            passwordStack.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 24),
            passwordStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 30),
            passwordStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -30),
            passwordField.heightAnchor.constraint(equalToConstant: 28),
            unlockButton.heightAnchor.constraint(equalToConstant: 28),

            errorLabel.topAnchor.constraint(equalTo: passwordStack.bottomAnchor, constant: 8),
            errorLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),

            quitButton.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 20),
            quitButton.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            quitButton.bottomAnchor.constraint(equalTo: cardView.bottomAnchor)
        ])
    }

    public func applyMethod(_ method: BrowserLockMethod) {
        switch method {
        case .touchIDOrPasscode:
            touchIDButton.isHidden = false
            passwordField.superview?.isHidden = true
            errorLabel.isHidden = true
        case .masterPassword:
            touchIDButton.isHidden = true
            passwordField.superview?.isHidden = false
            passwordField.stringValue = ""
            errorLabel.isHidden = true
            window?.makeFirstResponder(passwordField)
        }
    }

    public func focusInput() {
        if !passwordField.isHidden && passwordField.window != nil {
            window?.makeFirstResponder(passwordField)
        }
    }

    @objc private func touchIDClicked() {
        onBiometricUnlockRequested?()
    }

    @objc private func passwordEntered() {
        let text = passwordField.stringValue
        guard !text.isEmpty else { return }

        if let handler = onPasswordUnlockRequested {
            let success = handler(text)
            if success {
                errorLabel.isHidden = true
            } else {
                errorLabel.stringValue = "Incorrect master password. Try again."
                errorLabel.isHidden = false
                shakeCard()
                passwordField.selectText(nil)
            }
        }
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    private func shakeCard() {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.duration = 0.4
        animation.values = [-12, 12, -8, 8, -4, 4, 0]
        cardView.layer?.add(animation, forKey: "shake")
    }

    // MARK: - Event trapping

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // Ensure every touch is absorbed by the lock view or its children
        return hit ?? self
    }

    public override func mouseDown(with event: NSEvent) {}
    public override func mouseUp(with event: NSEvent) {}
    public override func rightMouseDown(with event: NSEvent) {}
    public override func otherMouseDown(with event: NSEvent) {}
    public override func scrollWheel(with event: NSEvent) {}
}
