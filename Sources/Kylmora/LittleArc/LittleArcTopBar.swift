import AppKit
import WebKit

/// The strip along the top of a Little Arc window: what the page is, and the
/// one decision the window exists to ask -- which space the page belongs in.
///
/// Built from the same pieces as the rest of the chrome (`IconButton`,
/// `FaviconImageView`, `Style`), so a little window is recognisably Kylmora's
/// and not a plain page in a frame.
///
/// Its leading inset is always `trafficLightWidth`: unlike the main window,
/// which may or may not be hosting the window's buttons, this window always is
/// -- it is a titled window with a transparent titlebar, so the lights float
/// over this strip by construction.
@MainActor
final class LittleArcTopBar: NSView {
    /// A space the page may be kept in, reduced to what the menu draws.
    ///
    /// Plain values rather than `Space`, because this view has no session: the
    /// window controller maps spaces to these, and a test can build them with
    /// nothing behind them.
    struct SpaceChoice: Equatable {
        let id: UUID
        let title: String
        let image: NSImage?
        /// The space the page was loaded in. Keeping it there is the default,
        /// and the menu says so.
        let isOwner: Bool
    }

    /// The space the user chose. The owner arrives through this same path as
    /// any other, so "keep it here" is not a second implementation.
    var onMove: ((UUID) -> Void)?
    var onReload: (() -> Void)?

    /// The choices as last shown. Read by the window's keyboard handling, and
    /// by the tests.
    private(set) var choices: [SpaceChoice] = []

    // The controls are internal rather than private, as the top bar's are: the
    // tests drive the strip through them rather than through the window.
    let favicon = FaviconImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let addressLabel = NSTextField(labelWithString: "")
    let reloadButton = IconButton(symbolName: "arrow.clockwise", label: "Reload")
    let moveButton = NSPopUpButton(frame: .zero, pullsDown: true)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("LittleArcTopBar is created in code only")
    }

    private func build() {
        titleLabel.font = Style.Fonts.emphasis
        titleLabel.textColor = Style.Colors.primaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        // The title gives way first when the two run out of room: a long page
        // title is the page's own words, and the address is where the user
        // actually is.
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        addressLabel.font = Style.Fonts.badge
        addressLabel.textColor = Style.Colors.secondaryText
        addressLabel.lineBreakMode = .byTruncatingMiddle
        addressLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        for label in [titleLabel, addressLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.maximumNumberOfLines = 1
            addSubview(label)
        }

        reloadButton.setClickHandler { [weak self] in self?.onReload?() }
        reloadButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(reloadButton)

        // A pull-down, so the button is its own label: the menu lists spaces,
        // and "Move to Space" is what the button says until it is opened.
        moveButton.pullsDown = true
        moveButton.controlSize = .small
        moveButton.bezelStyle = .rounded
        moveButton.translatesAutoresizingMaskIntoConstraints = false
        moveButton.setAccessibilityLabel("Move to Space")
        rebuildMenu()
        addSubview(moveButton)

        addSubview(favicon)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Style.Metrics.topBarHeight),

            favicon.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Style.Metrics.trafficLightWidth
            ),
            favicon.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.leadingAnchor.constraint(
                equalTo: favicon.trailingAnchor,
                constant: Style.Metrics.rowContentSpacing
            ),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            addressLabel.leadingAnchor.constraint(
                equalTo: titleLabel.trailingAnchor,
                constant: Style.Metrics.rowContentSpacing
            ),
            addressLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            addressLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: reloadButton.leadingAnchor,
                constant: -Style.Metrics.rowContentSpacing
            ),

            reloadButton.trailingAnchor.constraint(
                equalTo: moveButton.leadingAnchor,
                constant: -Style.Metrics.iconButtonSpacing
            ),
            reloadButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            moveButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Style.Metrics.topBarTrailingInset
            ),
            moveButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    // MARK: - Showing a page

    func show(title: String, address: String, spaces: [SpaceChoice]) {
        titleLabel.stringValue = title
        addressLabel.stringValue = address
        titleLabel.toolTip = title.isEmpty ? nil : title
        addressLabel.toolTip = address.isEmpty ? nil : address
        choices = spaces
        rebuildMenu()
    }

    /// The icon slot follows the page, like a sidebar row's does.
    func showIcon(for url: URL?, in webView: WKWebView?, isPrivate: Bool) {
        guard let url else {
            favicon.clear()
            return
        }
        favicon.show(for: url, in: webView, isPrivate: isPrivate)
    }

    /// Reload doubles as stop, in symbol and in label together, because the
    /// only useful control in that spot while a page is loading is a way to
    /// stop it (`ContentTopBar` does the same).
    func setLoading(_ isLoading: Bool) {
        reloadButton.setSymbol(
            isLoading ? "xmark" : "arrow.clockwise",
            label: isLoading ? "Stop Loading" : "Reload"
        )
    }

    // MARK: - Spaces

    /// The space the page was loaded in, if it is still among the choices.
    var ownerSpaceID: UUID? { choices.first { $0.isOwner }?.id }

    /// What choosing a menu item does, and what the window's keyboard shortcut
    /// does. One path, so a space reached by key and a space reached by menu
    /// cannot behave differently.
    func move(to spaceID: UUID) {
        guard choices.contains(where: { $0.id == spaceID }) else { return }
        onMove?(spaceID)
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        // Item zero of a pull-down is the button's own face, not a choice.
        let label = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
        menu.addItem(label)
        menu.addItem(.separator())

        for (index, space) in choices.enumerated() {
            let key = index < 9 ? "\(index + 1)" : ""
            let item = NSMenuItem(
                title: space.isOwner ? "Keep in \(space.title)" : space.title,
                action: #selector(spaceChosen(_:)),
                keyEquivalent: key
            )
            item.keyEquivalentModifierMask = [.command]
            item.target = self
            item.representedObject = space.id
            item.image = space.image
            item.state = space.isOwner ? .on : .off
            item.toolTip = space.isOwner
                ? "\(space.title) is the space this page is loaded in. (⌘\(index + 1) or ↩)"
                : "Open the page as a tab in \(space.title). (⌘\(index + 1))"
            menu.addItem(item)
        }
        moveButton.menu = menu
        moveButton.isEnabled = !choices.isEmpty
    }

    @objc private func spaceChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        move(to: id)
    }
}
