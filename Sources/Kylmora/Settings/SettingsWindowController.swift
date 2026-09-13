import AppKit

/// The Settings window: a toolbar of icon tabs, the chosen pane's name as the
/// window's title, and the pane below laid out as a form.
///
/// The classic macOS preferences shape, which is what Safari and Orion still
/// use and what the user asked for. A source list was tried first; the
/// toolbar spends less width on navigation and leaves the pane the whole
/// window, which the form layout needs.
@MainActor
final class SettingsWindowController: NSWindowController {
    /// The panes, in toolbar order.
    enum Pane: Int, CaseIterable {
        case general
        case importData
        case browsing
        case shortcuts
        case passwords
        case privacy
        case search
        case spaces
        case extensions
        case websites
        case sync
        case advanced
        case about

        var title: String {
            switch self {
            case .general: return "General"
            case .importData: return "Import"
            case .browsing: return "Browsing"
            case .shortcuts: return "Shortcuts"
            case .passwords: return "Passwords"
            case .privacy: return "Privacy"
            case .search: return "Search"
            case .spaces: return "Spaces"
            case .extensions: return "Extensions"
            case .websites: return "Websites"
            case .sync: return "Sync"
            case .advanced: return "Advanced"
            case .about: return "About"
            }
        }

        var symbolName: String {
            switch self {
            case .general: return "gearshape"
            case .importData: return "square.and.arrow.down"
            case .browsing: return "menubar.rectangle"
            case .shortcuts: return "keyboard"
            case .passwords: return "key"
            case .privacy: return "hand.raised"
            case .search: return "magnifyingglass"
            case .spaces: return "square.stack"
            case .extensions: return "puzzlepiece.extension"
            case .websites: return "globe"
            case .sync: return "arrow.triangle.2.circlepath"
            case .advanced: return "slider.horizontal.3"
            case .about: return "info.circle"
            }
        }

        var itemIdentifier: NSToolbarItem.Identifier {
            NSToolbarItem.Identifier("kylmora.settings.\(rawValue)")
        }

        init?(itemIdentifier: NSToolbarItem.Identifier) {
            guard let pane = Pane.allCases.first(where: { $0.itemIdentifier == itemIdentifier }) else { return nil }
            self = pane
        }
    }

    static let windowWidth: CGFloat = 860
    private var widthPinned: Set<Pane> = []
    private var keyboardParking: [Pane: NSView] = [:]

    private let session: BrowserSession
    private let syncCoordinator: SyncCoordinator?
    private let settings: Settings
    private var panes: [Pane: NSViewController] = [:]
    private var shown: Pane?
    /// Where "Set to Current Page" reads from.
    var currentPageURL: (() -> URL?)?

    init(session: BrowserSession, syncCoordinator: SyncCoordinator? = nil, settings: Settings = .shared) {
        self.session = session
        self.syncCoordinator = syncCoordinator
        self.settings = settings

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        window.center()

        super.init(window: window)

        let toolbar = NSToolbar(identifier: "kylmora.settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        show(.general)
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is created in code only")
    }

    // MARK: - Panes

    /// Brings the window up on a particular pane. The space menu uses it so
    /// "Space Settings" lands on Spaces rather than on whatever was open the
    /// last time the window was used.
    func showWindow(_ sender: Any?, on pane: Pane) {
        show(pane)
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    /// Opens Spaces with one space already loaded in the editor.
    func showSpace(_ space: Space, sender: Any?) {
        show(.spaces)
        (panes[.spaces] as? SpacesSettingsViewController)?.select(space)
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    @objc private func paneChosen(_ sender: NSToolbarItem) {
        guard let pane = Pane(itemIdentifier: sender.itemIdentifier) else { return }
        show(pane)
    }

    /// Switches panes from inside one: Advanced's "Manage Extensions".
    func select(_ pane: Pane) { show(pane) }

    /// A pane whose height changed after it was shown (About, once the
    /// update check has answered) asks the window to fit it again.
    func paneDidResize() {
        guard let shown else { return }
        let pane = shown
        self.shown = nil
        show(pane)
    }

    private func show(_ pane: Pane) {
        guard let window else { return }
        let controller = panes[pane] ?? make(pane)
        panes[pane] = controller
        window.toolbar?.selectedItemIdentifier = pane.itemIdentifier
        guard pane != shown else { return }
        shown = pane
        window.title = pane.title

        // The pane's own height: the window grows and shrinks to fit each
        // pane, as the classic preferences windows do, rather than every pane
        // living in the tallest one's space.
        let view = controller.view
        view.translatesAutoresizingMaskIntoConstraints = false
        // The pane's own constraints size the window once it is the content
        // view, so the pane is pinned to the one width here rather than
        // each pane deciding.
        if !widthPinned.contains(pane) {
            widthPinned.insert(pane)
            view.widthAnchor.constraint(equalToConstant: Self.windowWidth).isActive = true
        }
        view.frame.size.width = Self.windowWidth
        view.layoutSubtreeIfNeeded()
        // Never taller than the screen: a pane that outgrows it scrolls.
        let screenHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let height = min(max(view.fittingSize.height, 200), screenHeight - 120)

        let wasVisible = window.isVisible
        // The window takes its content controller's preferred size when one
        // is set, so a pane narrower than the window would shrink it and the
        // panes would jump about as the toolbar switched between them.
        controller.preferredContentSize = NSSize(width: Self.windowWidth, height: height)
        window.contentViewController = controller
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: height))
        frame.origin = window.frame.origin
        frame.origin.y += window.frame.height - frame.height
        window.setFrame(frame, display: true, animate: wasVisible)
        // A pane arrives with nothing focused. Otherwise the first text
        // field takes the keyboard and wears a focus ring before the user
        // has touched anything, which reads as a field demanding input.
        // Becoming key hands the keyboard to the first field in the key
        // loop, and a field with the keyboard wears a focus ring. The pane
        // is a form to read first, not a field to fill in, so the keyboard
        // parks on an invisible view until a click or a Tab moves it.
        let parking = keyboardParking[pane] ?? {
            let parking = KeyboardParkingView()
            controller.view.addSubview(parking)
            keyboardParking[pane] = parking
            return parking
        }()
        window.initialFirstResponder = parking
        window.makeFirstResponder(parking)
    }

    /// Nothing to see: a zero-size view that holds the keyboard.
    private final class KeyboardParkingView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private func make(_ pane: Pane) -> NSViewController {
        switch pane {
        case .general:
            let general = GeneralSettingsViewController(settings: settings, session: session)
            general.currentPageURL = { [weak self] in self?.currentPageURL?() }
            return general
        case .importData: return ImportSettingsViewController(session: session)
        case .browsing: return BrowsingSettingsViewController(settings: settings, session: session)
        case .shortcuts: return ShortcutsSettingsViewController()
        case .passwords: return PasswordsSettingsViewController(settings: settings, session: session)
        case .privacy: return PrivacySettingsViewController(settings: settings, session: session)
        case .search: return SearchSettingsViewController(settings: settings)
        case .spaces: return SpacesSettingsViewController(session: session)
        case .extensions: return ExtensionsSettingsViewController(settings: settings)
        case .websites:
            let websites = WebsitesSettingsViewController()
            websites.currentPageURL = { [weak self] in self?.currentPageURL?() }
            return websites
        case .sync: return SyncSettingsViewController(coordinator: syncCoordinator, settings: settings)
        case .advanced: return AdvancedSettingsViewController(settings: settings)
        case .about: return AboutSettingsViewController()
        }
    }
}

// MARK: - The toolbar

extension SettingsWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.itemIdentifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let pane = Pane(itemIdentifier: itemIdentifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.paletteLabel = pane.title
        item.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: pane.title)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
        item.target = self
        item.action = #selector(paneChosen(_:))
        return item
    }
}
