import AppKit
import WebKit

/// The minimal top chrome for a standalone Web App window.
/// Includes navigation controls, security and host badge, reload/stop,
/// and buttons to send the page back to the main browser or access quick site tools.
@MainActor
final class WebAppTopBar: NSView {
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onReload: (() -> Void)?
    var onToggleDarkMode: (() -> Void)?
    var onOpenInBrowser: (() -> Void)?
    var onMoreAction: ((String) -> Void)?

    let backButton = IconButton(symbolName: "chevron.left", label: "Back")
    let forwardButton = IconButton(symbolName: "chevron.right", label: "Forward")
    let reloadButton = IconButton(symbolName: "arrow.clockwise", label: "Reload")
    let favicon = FaviconImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let securityIcon = NSImageView()
    let hostLabel = NSTextField(labelWithString: "")
    let darkModeButton = IconButton(symbolName: "moon", label: "Toggle Dark Mode")
    let openInBrowserButton = IconButton(symbolName: "arrow.up.forward.app", label: "Open in Kylmora")
    let moreButton = NSPopUpButton(frame: .zero, pullsDown: true)

    private var isSecure = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("WebAppTopBar is created in code only")
    }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        titleLabel.font = Style.Fonts.emphasis
        titleLabel.textColor = Style.Colors.primaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        hostLabel.font = Style.Fonts.badge
        hostLabel.textColor = Style.Colors.secondaryText
        hostLabel.lineBreakMode = .byTruncatingMiddle
        hostLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        securityIcon.imageScaling = .scaleProportionallyDown
        securityIcon.contentTintColor = Style.Colors.secondaryText
        securityIcon.translatesAutoresizingMaskIntoConstraints = false
        securityIcon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Secure connection")

        backButton.setClickHandler { [weak self] in self?.onBack?() }
        forwardButton.setClickHandler { [weak self] in self?.onForward?() }
        reloadButton.setClickHandler { [weak self] in self?.onReload?() }
        darkModeButton.setClickHandler { [weak self] in self?.onToggleDarkMode?() }
        openInBrowserButton.setClickHandler { [weak self] in self?.onOpenInBrowser?() }

        moreButton.pullsDown = true
        moreButton.controlSize = .small
        moreButton.bezelStyle = .rounded
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.setAccessibilityLabel("More Options")
        rebuildMoreMenu()

        for subview in [
            backButton, forwardButton, reloadButton, favicon,
            titleLabel, securityIcon, hostLabel,
            darkModeButton, openInBrowserButton, moreButton
        ] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Style.Metrics.topBarHeight),

            // Traffic light spacing
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Style.Metrics.trafficLightWidth + 4),
            backButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            forwardButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            reloadButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 4),
            reloadButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            favicon.leadingAnchor.constraint(equalTo: reloadButton.trailingAnchor, constant: 12),
            favicon.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: favicon.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            securityIcon.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            securityIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            securityIcon.widthAnchor.constraint(equalToConstant: 12),
            securityIcon.heightAnchor.constraint(equalToConstant: 12),

            hostLabel.leadingAnchor.constraint(equalTo: securityIcon.trailingAnchor, constant: 4),
            hostLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            hostLabel.trailingAnchor.constraint(lessThanOrEqualTo: darkModeButton.leadingAnchor, constant: -12),

            darkModeButton.trailingAnchor.constraint(equalTo: openInBrowserButton.leadingAnchor, constant: -4),
            darkModeButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            openInBrowserButton.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -4),
            openInBrowserButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            moreButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            moreButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 32)
        ])
    }

    private func rebuildMoreMenu() {
        let menu = NSMenu()
        let pullItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        pullItem.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More Options")
        menu.addItem(pullItem)

        let zoomIn = NSMenuItem(title: "Zoom In", action: #selector(menuAction(_:)), keyEquivalent: "+")
        zoomIn.target = self
        zoomIn.representedObject = "zoom-in"
        menu.addItem(zoomIn)

        let zoomOut = NSMenuItem(title: "Zoom Out", action: #selector(menuAction(_:)), keyEquivalent: "-")
        zoomOut.target = self
        zoomOut.representedObject = "zoom-out"
        menu.addItem(zoomOut)

        let zoomReset = NSMenuItem(title: "Actual Size", action: #selector(menuAction(_:)), keyEquivalent: "0")
        zoomReset.target = self
        zoomReset.representedObject = "zoom-reset"
        menu.addItem(zoomReset)

        menu.addItem(.separator())

        let boost = NSMenuItem(title: "Boost This Site\u{2026}", action: #selector(menuAction(_:)), keyEquivalent: "e")
        boost.keyEquivalentModifierMask = [.command, .option]
        boost.target = self
        boost.representedObject = "boost"
        menu.addItem(boost)

        let copyURL = NSMenuItem(title: "Copy URL", action: #selector(menuAction(_:)), keyEquivalent: "c")
        copyURL.keyEquivalentModifierMask = [.command, .shift]
        copyURL.target = self
        copyURL.representedObject = "copy-url"
        menu.addItem(copyURL)

        menu.addItem(.separator())

        let revealFinder = NSMenuItem(title: "Show App in Finder", action: #selector(menuAction(_:)), keyEquivalent: "")
        revealFinder.target = self
        revealFinder.representedObject = "reveal-finder"
        menu.addItem(revealFinder)

        moreButton.menu = menu
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            onMoreAction?(id)
        }
    }

    func update(
        title: String,
        url: URL?,
        canGoBack: Bool,
        canGoForward: Bool,
        isLoading: Bool,
        isDark: Bool
    ) {
        titleLabel.stringValue = title
        if let url {
            hostLabel.stringValue = url.host ?? ""
            isSecure = url.scheme?.lowercased() == "https"
            securityIcon.isHidden = !isSecure
        } else {
            hostLabel.stringValue = ""
            securityIcon.isHidden = true
        }

        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward

        if isLoading {
            reloadButton.setSymbol("xmark", label: "Stop")
        } else {
            reloadButton.setSymbol("arrow.clockwise", label: "Reload")
        }

        if isDark {
            darkModeButton.setSymbol("sun.max.fill", label: "Disable Dark Mode")
            darkModeButton.isActive = true
        } else {
            darkModeButton.setSymbol("moon", label: "Enable Dark Mode")
            darkModeButton.isActive = false
        }
    }

    func showIcon(for url: URL?, in webView: WKWebView?, isPrivate: Bool) {
        guard let url else { return }
        favicon.show(for: url, in: webView, isPrivate: isPrivate)
    }
}
