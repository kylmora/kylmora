import AppKit

/// A visual card representing an open tab in the Safari-style Tab Overview grid.
@MainActor
final class TabCardView: NSView {
    let tab: Tab
    let space: Space?

    var onSelect: ((Tab, Space?) -> Void)?
    var onClose: ((Tab) -> Void)?

    var isActive: Bool = false {
        didSet { updateVisualState() }
    }

    var isHighlighted: Bool = false {
        didSet { updateVisualState() }
    }

    private let cardBackground = NSVisualEffectView()
    private let headerView = NSView()
    private let faviconView = FaviconImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeStack = NSStackView()
    private let activeBadge = NSTextField(labelWithString: "ACTIVE")
    private let spaceBadge = NSTextField(labelWithString: "")
    private let audioIndicator = NSImageView()
    private let pinIndicator = NSImageView()
    private let closeButton = NSButton()

    let thumbnailView = TabThumbnailView()
    private let footerLabel = NSTextField(labelWithString: "")

    private var trackingArea: NSTrackingArea?
    private var isHovered: Bool = false {
        didSet { updateVisualState() }
    }

    init(tab: Tab, space: Space? = nil, showSpaceBadge: Bool = false) {
        self.tab = tab
        self.space = space
        super.init(frame: .zero)
        setupViews(showSpaceBadge: showSpaceBadge)
        populateData(showSpaceBadge: showSpaceBadge)
    }

    required init?(coder: NSCoder) {
        fatalError("TabCardView is created in code only")
    }

    private func setupViews(showSpaceBadge: Bool) {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = false
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor

        // Visual effect background
        cardBackground.translatesAutoresizingMaskIntoConstraints = false
        cardBackground.material = .popover
        cardBackground.blendingMode = .withinWindow
        cardBackground.state = .active
        cardBackground.wantsLayer = true
        cardBackground.layer?.cornerRadius = 12
        cardBackground.layer?.masksToBounds = true
        addSubview(cardBackground)

        // Header view
        headerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerView)

        // Favicon
        headerView.addSubview(faviconView)

        // Title Label
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        headerView.addSubview(titleLabel)

        // Badge Stack
        badgeStack.translatesAutoresizingMaskIntoConstraints = false
        badgeStack.orientation = .horizontal
        badgeStack.spacing = 4
        badgeStack.alignment = .centerY
        headerView.addSubview(badgeStack)

        // Active Badge
        activeBadge.font = .systemFont(ofSize: 9, weight: .bold)
        activeBadge.textColor = .controlAccentColor
        activeBadge.wantsLayer = true
        activeBadge.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        activeBadge.layer?.cornerRadius = 3
        activeBadge.layer?.masksToBounds = true
        activeBadge.alignment = .center
        activeBadge.isHidden = true
        badgeStack.addArrangedSubview(activeBadge)

        // Space Badge
        if showSpaceBadge, let space {
            spaceBadge.stringValue = " \(space.name) "
            spaceBadge.font = .systemFont(ofSize: 9, weight: .semibold)
            spaceBadge.textColor = .secondaryLabelColor
            spaceBadge.wantsLayer = true
            spaceBadge.layer?.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.2).cgColor
            spaceBadge.layer?.cornerRadius = 3
            spaceBadge.layer?.masksToBounds = true
            badgeStack.addArrangedSubview(spaceBadge)
        }

        // Audio Indicator
        let audioConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        audioIndicator.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Playing Audio")?
            .withSymbolConfiguration(audioConfig)
        audioIndicator.contentTintColor = .systemYellow
        audioIndicator.isHidden = !tab.isPlayingAudio
        badgeStack.addArrangedSubview(audioIndicator)

        // Pin Indicator
        let pinConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        pinIndicator.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?
            .withSymbolConfiguration(pinConfig)
        pinIndicator.contentTintColor = .secondaryLabelColor
        pinIndicator.isHidden = true
        badgeStack.addArrangedSubview(pinIndicator)

        // Close Button
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.title = ""
        let xConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(xConfig)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 10
        closeButton.target = self
        closeButton.action = #selector(didClickClose(_:))
        closeButton.toolTip = "Close Tab (⌘W)"
        headerView.addSubview(closeButton)

        // Thumbnail View
        addSubview(thumbnailView)

        // Footer URL Label
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.font = .systemFont(ofSize: 10.5, weight: .regular)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.lineBreakMode = .byTruncatingTail
        addSubview(footerLabel)

        NSLayoutConstraint.activate([
            cardBackground.topAnchor.constraint(equalTo: topAnchor),
            cardBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardBackground.bottomAnchor.constraint(equalTo: bottomAnchor),

            headerView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            headerView.heightAnchor.constraint(equalToConstant: 28),

            faviconView.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            faviconView.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: faviconView.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeStack.leadingAnchor, constant: -6),

            badgeStack.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            badgeStack.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),

            closeButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),

            thumbnailView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 4),
            thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            thumbnailView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            thumbnailView.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -4),

            footerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            footerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            footerLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            footerLabel.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    func populateData(showSpaceBadge: Bool) {
        let title = tab.pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = (title?.isEmpty == false) ? title! : (tab.url.host ?? "Untitled")
        titleLabel.stringValue = displayTitle

        let host = tab.url.host ?? tab.url.absoluteString
        footerLabel.stringValue = host

        faviconView.show(for: tab.url, in: tab.currentWebView, isPrivate: tab.isPrivate)

        let cachedSnapshot = TabSnapshotStore.shared.snapshot(for: tab.id)
        thumbnailView.configure(snapshot: cachedSnapshot, title: displayTitle, domain: host)

        if cachedSnapshot == nil, let webView = tab.currentWebView, webView.bounds.width > 0 {
            Task { [weak self] in
                guard let self else { return }
                if let image = await TabSnapshotStore.shared.capture(tab: self.tab) {
                    self.thumbnailView.configure(snapshot: image, title: displayTitle, domain: host)
                }
            }
        }

        audioIndicator.isHidden = !tab.isPlayingAudio
    }

    private func updateVisualState() {
        if isHighlighted {
            layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
            layer?.borderWidth = 2.5
            shadow = makeSelectionShadow(color: .keyboardFocusIndicatorColor)
        } else if isActive {
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = 2.5
            activeBadge.isHidden = false
            shadow = makeSelectionShadow(color: .controlAccentColor)
        } else if isHovered {
            layer?.borderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.6).cgColor
            layer?.borderWidth = 1.8
            activeBadge.isHidden = true
            shadow = makeHoverShadow()
            closeButton.contentTintColor = .labelColor
        } else {
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
            layer?.borderWidth = 1.5
            activeBadge.isHidden = true
            shadow = nil
            closeButton.contentTintColor = .secondaryLabelColor
        }
    }

    private func makeSelectionShadow(color: NSColor) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = color.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        return shadow
    }

    private func makeHoverShadow() -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        return shadow
    }

    @objc private func didClickClose(_ sender: Any?) {
        onClose?(tab)
    }

    // MARK: - Event Handling

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSCursor.pointingHand.push()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        NSCursor.pop()
    }

    override func mouseDown(with event: NSEvent) {
        // Prevent click if close button was target
        let pointInClose = closeButton.convert(event.locationInWindow, from: nil)
        if closeButton.bounds.contains(pointInClose) {
            return
        }
        if acceptsSpringPress { press.flick() }
        onSelect?(tab, space)
    }

    /// The squeeze the card gives under a click. See `SpringPress`.
    private lazy var press = SpringPress(view: self)
}
