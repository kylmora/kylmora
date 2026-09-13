import AppKit

/// One trailing action in the top bar.
///
/// The trailing cluster is caller-supplied rather than hard-coded because
/// other browsers' own buttons there are features Kylmora does not have.
/// Inventing lookalikes would be fake UI; this way the bar shows exactly the
/// commands Kylmora actually has.
struct TopBarAction {
    let symbolName: String
    let label: String
    let handler: () -> Void

    init(symbolName: String, label: String, handler: @escaping () -> Void) {
        self.symbolName = symbolName
        self.label = label
        self.handler = handler
    }
}

/// The bar above the page: sidebar toggle, back, forward, reload, the
/// breadcrumb, and a trailing action cluster.
///
/// This is the piece that moves navigation out of the sidebar and back over the
/// page. It deliberately owns no state of its own beyond its subviews --
/// `update(canGoBack:...)` is the only way its appearance changes -- so it can
/// be driven from a tab, a test, or nothing at all.
@MainActor
final class ContentTopBar: NSView {
    let sidebarToggle = IconButton(symbolName: "sidebar.leading", label: "Toggle Sidebar")
    let backButton = IconButton(symbolName: "chevron.left", label: "Back")
    let forwardButton = IconButton(symbolName: "chevron.right", label: "Forward")
    /// Doubles as stop: while a page is loading, the only useful thing in that
    /// spot is a way to stop it.
    let reloadButton = IconButton(symbolName: "arrow.clockwise", label: "Reload")
    let addressField = AddressField()
    /// Zoom out / percentage / zoom in, kept next to the address it acts on.
    let zoomControl = ZoomControl()

    private let actionStack = NSStackView()
    private var navigationLeadingConstraint: NSLayoutConstraint!
    private var trackingArea: NSTrackingArea?

    /// Reports whether the pointer is over the bar. The window controller uses
    /// it to bring the traffic lights back while the sidebar is hidden.
    var onHoverChanged: ((Bool) -> Void)?

    /// Space reserved at the leading edge before the navigation buttons.
    ///
    /// The window has no titlebar, so the sidebar normally hosts the traffic
    /// lights. Hiding the sidebar leaves them where macOS puts them -- the
    /// window's top-left corner -- which is on top of this bar. Rather than
    /// move the lights, the bar steps aside for them.
    var leadingInset: CGFloat = Style.Metrics.sidebarInset {
        didSet {
            guard leadingInset != oldValue else { return }
            navigationLeadingConstraint.animator().constant = leadingInset
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        let navigation = NSStackView(views: [sidebarToggle, backButton, forwardButton, reloadButton])
        navigation.orientation = .horizontal
        navigation.spacing = Style.Metrics.iconButtonSpacing
        navigation.setHuggingPriority(.required, for: .horizontal)

        actionStack.orientation = .horizontal
        actionStack.spacing = Style.Metrics.iconButtonSpacing
        actionStack.setHuggingPriority(.required, for: .horizontal)

        navigation.translatesAutoresizingMaskIntoConstraints = false
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        zoomControl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(navigation)
        addSubview(addressField)
        addSubview(zoomControl)
        addSubview(actionStack)

        // Three separately anchored pieces rather than one stack, because a
        // stack shares its slack out among its views and the bar needs all of
        // it to go to one of them. Navigation is pinned leading, the actions
        // are pinned trailing, and the address field fills the whole width
        // between them -- an address bar wants the room a breadcrumb did not.
        // Stored, because the traffic lights move onto this bar when the
        // sidebar is hidden and the buttons have to step aside for them.
        let navigationLeading = navigation.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: Style.Metrics.sidebarInset
        )
        navigationLeadingConstraint = navigationLeading

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Style.Metrics.topBarHeight),

            navigationLeading,
            navigation.centerYAnchor.constraint(equalTo: centerYAnchor),

            addressField.leadingAnchor.constraint(
                equalTo: navigation.trailingAnchor,
                constant: Style.Metrics.breadcrumbLeadingGap
            ),
            addressField.trailingAnchor.constraint(
                equalTo: zoomControl.leadingAnchor,
                constant: -Style.Metrics.iconButtonSpacing
            ),
            addressField.centerYAnchor.constraint(equalTo: centerYAnchor),

            zoomControl.trailingAnchor.constraint(
                equalTo: actionStack.leadingAnchor,
                constant: -Style.Metrics.iconButtonSpacing
            ),
            zoomControl.centerYAnchor.constraint(equalTo: centerYAnchor),

            actionStack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Style.Metrics.topBarTrailingInset
            ),
            actionStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("ContentTopBar is created in code only")
    }

    /// Rebuilds the trailing cluster. Passing an empty array is a supported
    /// state, not a bug: a build with none of these commands wired shows a bar
    /// with nothing on the right rather than dead buttons.
    func setActions(_ actions: [TopBarAction]) {
        for view in actionStack.arrangedSubviews {
            actionStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for action in actions {
            actionStack.addArrangedSubview(
                IconButton(symbolName: action.symbolName, label: action.label, onClick: action.handler)
            )
        }
        actionStack.isHidden = actions.isEmpty
    }

    /// The button for one of the actions, to anchor a popover on.
    func actionButton(labelled label: String) -> NSView? {
        actionStack.arrangedSubviews.first { $0.accessibilityLabel() == label }
    }

    /// The whole of this bar's mutable appearance, in one call.
    func update(canGoBack: Bool, canGoForward: Bool, isLoading: Bool, hasPage: Bool) {
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        reloadButton.isEnabled = hasPage
        if isLoading {
            reloadButton.setSymbol("xmark", label: "Stop Loading")
        } else {
            reloadButton.setSymbol("arrow.clockwise", label: "Reload")
        }
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

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
}
