import AppKit

/// Displays either a rendered page snapshot or an elegant macOS-style fallback
/// document placeholder when no snapshot is available.
@MainActor
final class TabThumbnailView: NSView {
    private let imageView = NSImageView()
    private let placeholderView = NSView()
    private let wireframeHeader = NSView()
    private let miniSearchPill = NSView()
    private let centerStack = NSStackView()
    private let iconImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let domainLabel = NSTextField(labelWithString: "")
    private let skeletonStack = NSStackView()

    init() {
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("TabThumbnailView is created in code only")
    }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        // Snapshot Image View
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignTop
        imageView.wantsLayer = true
        imageView.layer?.masksToBounds = true
        addSubview(imageView)

        // Placeholder View
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        placeholderView.wantsLayer = true
        placeholderView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.65).cgColor
        addSubview(placeholderView)

        // Mini wireframe header
        wireframeHeader.translatesAutoresizingMaskIntoConstraints = false
        wireframeHeader.wantsLayer = true
        wireframeHeader.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.15).cgColor
        placeholderView.addSubview(wireframeHeader)

        // Traffic dots mock
        let dotsStack = NSStackView()
        dotsStack.orientation = .horizontal
        dotsStack.spacing = 4
        dotsStack.translatesAutoresizingMaskIntoConstraints = false
        wireframeHeader.addSubview(dotsStack)

        for _ in 0..<3 {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.4).cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6)
            ])
            dotsStack.addArrangedSubview(dot)
        }

        // Mini search capsule
        miniSearchPill.translatesAutoresizingMaskIntoConstraints = false
        miniSearchPill.wantsLayer = true
        miniSearchPill.layer?.cornerRadius = 4
        miniSearchPill.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor
        wireframeHeader.addSubview(miniSearchPill)

        // Center Stack (Icon + Title + Domain)
        centerStack.orientation = .vertical
        centerStack.alignment = .centerX
        centerStack.spacing = 6
        centerStack.translatesAutoresizingMaskIntoConstraints = false
        placeholderView.addSubview(centerStack)

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        iconImageView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
        iconImageView.contentTintColor = .tertiaryLabelColor
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        centerStack.addArrangedSubview(iconImageView)

        domainLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        domainLabel.textColor = .secondaryLabelColor
        domainLabel.alignment = .center
        domainLabel.lineBreakMode = .byTruncatingTail
        centerStack.addArrangedSubview(domainLabel)

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        centerStack.addArrangedSubview(titleLabel)

        // Skeleton content lines at bottom
        skeletonStack.orientation = .vertical
        skeletonStack.spacing = 6
        skeletonStack.alignment = .centerX
        skeletonStack.translatesAutoresizingMaskIntoConstraints = false
        placeholderView.addSubview(skeletonStack)

        let widths: [CGFloat] = [0.8, 0.65, 0.5]
        for wFraction in widths {
            let line = NSView()
            line.wantsLayer = true
            line.layer?.cornerRadius = 2
            line.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.12).cgColor
            line.translatesAutoresizingMaskIntoConstraints = false
            skeletonStack.addArrangedSubview(line)
            NSLayoutConstraint.activate([
                line.heightAnchor.constraint(equalToConstant: 4),
                line.widthAnchor.constraint(equalTo: placeholderView.widthAnchor, multiplier: wFraction)
            ])
        }

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),

            placeholderView.topAnchor.constraint(equalTo: topAnchor),
            placeholderView.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholderView.trailingAnchor.constraint(equalTo: trailingAnchor),
            placeholderView.bottomAnchor.constraint(equalTo: bottomAnchor),

            wireframeHeader.topAnchor.constraint(equalTo: placeholderView.topAnchor),
            wireframeHeader.leadingAnchor.constraint(equalTo: placeholderView.leadingAnchor),
            wireframeHeader.trailingAnchor.constraint(equalTo: placeholderView.trailingAnchor),
            wireframeHeader.heightAnchor.constraint(equalToConstant: 20),

            dotsStack.leadingAnchor.constraint(equalTo: wireframeHeader.leadingAnchor, constant: 8),
            dotsStack.centerYAnchor.constraint(equalTo: wireframeHeader.centerYAnchor),

            miniSearchPill.centerXAnchor.constraint(equalTo: wireframeHeader.centerXAnchor),
            miniSearchPill.centerYAnchor.constraint(equalTo: wireframeHeader.centerYAnchor),
            miniSearchPill.widthAnchor.constraint(equalToConstant: 80),
            miniSearchPill.heightAnchor.constraint(equalToConstant: 10),

            centerStack.centerXAnchor.constraint(equalTo: placeholderView.centerXAnchor),
            centerStack.centerYAnchor.constraint(equalTo: placeholderView.centerYAnchor, constant: -8),
            centerStack.leadingAnchor.constraint(greaterThanOrEqualTo: placeholderView.leadingAnchor, constant: 16),
            centerStack.trailingAnchor.constraint(lessThanOrEqualTo: placeholderView.trailingAnchor, constant: -16),

            skeletonStack.bottomAnchor.constraint(equalTo: placeholderView.bottomAnchor, constant: -16),
            skeletonStack.leadingAnchor.constraint(equalTo: placeholderView.leadingAnchor, constant: 20),
            skeletonStack.trailingAnchor.constraint(equalTo: placeholderView.trailingAnchor, constant: -20)
        ])
    }

    /// Configures the thumbnail with a snapshot image or fallback information.
    func configure(snapshot: NSImage?, title: String, domain: String, favicon: NSImage? = nil) {
        if let snapshot {
            imageView.image = snapshot
            imageView.isHidden = false
            placeholderView.isHidden = true
        } else {
            imageView.image = nil
            imageView.isHidden = true
            placeholderView.isHidden = false

            if let favicon {
                iconImageView.image = favicon
            } else {
                let symbolConfig = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
                iconImageView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
                    .withSymbolConfiguration(symbolConfig)
            }
            titleLabel.stringValue = title
            domainLabel.stringValue = domain
        }
    }
}
