import AppKit

/// The Settings window: a spine of coloured tiles, a canvas washed in the
/// space's own colour, and the pane's cards floating on it.
///
/// Two earlier attempts at this window were thrown away for being the same
/// window every Mac app has -- a toolbar over a form, then a source list over
/// grouped cards under a header band. Both are perfectly good and neither is
/// Kylmora's. What is here now follows from what the browser actually is: a
/// thing you customise. So the window is painted in the colour of the space you
/// are in, every pane has a hue you navigate by, and the miniature browser in
/// the corner is both the preview and a second way to navigate -- point at the
/// part you want to change.
///
/// What is deliberately absent: a header band. A hundred points of window
/// carrying a title and a sentence is a hundred points not carrying settings.
/// The pane's name is set small above its first card, where a name belongs.
@MainActor
final class SettingsWindowController: NSWindowController {
    /// A group of panes. Drawn as air between tiles rather than as a heading:
    /// three tiles with a gap above them read as a group without a word.
    enum PaneGroup {
        case browsing
        case privacy
        case content
        case system

        var title: String {
            switch self {
            case .browsing: return "Browsing"
            case .privacy: return "Privacy"
            case .content: return "Content"
            case .system: return "System"
            }
        }
    }

    /// The panes, in spine order.
    enum Pane: Int, CaseIterable {
        case general
        case browsing
        case search
        case spaces
        case shortcuts
        case automations
        case privacy
        case passwords
        case websites
        case extensions
        case importData
        case sync
        case advanced
        case taskManager
        case about

        var group: PaneGroup {
            switch self {
            case .general, .browsing, .search, .spaces, .shortcuts, .automations: return .browsing
            case .privacy, .passwords, .websites: return .privacy
            case .extensions, .importData, .sync: return .content
            case .advanced, .taskManager, .about: return .system
            }
        }

        var title: String {
            switch self {
            case .general: return "General"
            case .importData: return "Import"
            case .browsing: return "Browsing"
            case .shortcuts: return "Shortcuts"
            case .automations: return "Automations"
            case .passwords: return "Passwords"
            case .privacy: return "Privacy"
            case .search: return "Search"
            case .spaces: return "Spaces"
            case .extensions: return "Extensions"
            case .websites: return "Websites"
            case .sync: return "Sync"
            case .advanced: return "Advanced"
            case .taskManager: return "Task Manager"
            case .about: return "About"
            }
        }

        /// One line under the pane's name, saying what is on the page, so a
        /// pane opens with an answer to "am I in the right place?" rather than
        /// with a wall of controls.
        var subtitle: String {
            switch self {
            case .general: return "What Kylmora opens with, downloads, and how tabs sleep."
            case .importData: return "Bring bookmarks, history and passwords over from another browser."
            case .browsing: return "The sidebar, the top bar, and how pages behave as you read them."
            case .shortcuts: return "Every keyboard shortcut, and what you have changed."
            case .automations: return "Which Space a link opens in, and rules that act on tabs when something happens."
            case .passwords: return "Saved logins, autofill, and the manager you use."
            case .privacy: return "Tracking, cookies, website data and what is blocked."
            case .search: return "Your search engine, suggestions, and private-window search."
            case .spaces: return "Each space's colour, look and window border."
            case .extensions: return "Extensions you have installed and where to find more."
            case .websites: return "Per-site permissions: zoom, camera, sound, notifications."
            case .sync: return "Keep tabs, bookmarks and settings together across your Macs."
            case .advanced: return "Developer tools, rendering and everything not settled elsewhere."
            case .taskManager: return "What every space and page is costing in memory, processor and graphics."
            case .about: return "Version, updates, and who made this."
            }
        }


        /// Words that should find this pane, beyond its name and its subtitle.
        /// What someone types is the thing they want changed, not the heading
        /// it happens to live under: "cookies" is Privacy, "dark" is General.
        var searchTerms: [String] {
            switch self {
            case .general: return ["dark", "light", "appearance", "theme", "startup", "homepage", "downloads", "sleep", "archive"]
            case .browsing: return ["sidebar", "toolbar", "top bar", "tabs", "split", "zoom", "reader"]
            case .search: return ["engine", "google", "duckduckgo", "suggestions"]
            case .spaces: return ["colour", "color", "gradient", "border", "wash", "workspace"]
            case .shortcuts: return ["keyboard", "keys", "bindings", "hotkey"]
            case .automations: return ["rules", "routing", "route", "trigger", "action", "when", "idle", "shortcut", "applescript", "automation"]
            case .privacy: return ["cookies", "tracking", "trackers", "ads", "blocker", "history", "clear"]
            case .passwords: return ["logins", "autofill", "keychain", "touch id"]
            case .websites: return ["permissions", "camera", "microphone", "location", "notifications", "sound"]
            case .extensions: return ["add-ons", "plugins", "webextension"]
            case .importData: return ["safari", "chrome", "firefox", "bookmarks", "migrate"]
            case .sync: return ["icloud", "devices", "backup"]
            case .advanced: return ["developer", "inspector", "json", "experimental"]
            case .taskManager: return ["memory", "ram", "cpu", "processor", "gpu", "graphics", "activity", "performance", "usage", "slow", "hog"]
            case .about: return ["version", "update", "licence", "license", "credits"]
            }
        }

        /// Whether this pane answers to what was typed in the rail's search.
        func matches(_ query: String) -> Bool {
            let query = query.trimmingCharacters(in: .whitespaces).lowercased()
            guard !query.isEmpty else { return true }
            if title.lowercased().contains(query) { return true }
            if subtitle.lowercased().contains(query) { return true }
            return searchTerms.contains { $0.contains(query) }
        }

        var symbolName: String {
            switch self {
            case .general: return "gearshape"
            case .importData: return "square.and.arrow.down"
            case .browsing: return "menubar.rectangle"
            case .shortcuts: return "keyboard"
            case .automations: return "bolt.horizontal"
            case .passwords: return "key"
            case .privacy: return "hand.raised"
            case .search: return "magnifyingglass"
            case .spaces: return "square.stack"
            case .extensions: return "puzzlepiece.extension"
            case .websites: return "globe"
            case .sync: return "arrow.triangle.2.circlepath"
            case .advanced: return "slider.horizontal.3"
            case .taskManager: return "speedometer"
            case .about: return "info.circle"
            }
        }

        /// The tile's colour, and the card edge and eyebrow on its page.
        ///
        /// Fifteen hues, walked around the wheel in rail order so neighbours
        /// never collide, and grouped by meaning where it helps: the three
        /// privacy panes are the warm end, the three content panes the cool.
        /// You stop reading the spine after a week and start reaching for
        /// "the orange one", which is the whole point of colouring it.
        var accent: NSColor {
            switch self {
            case .general: return NSColor(srgbRed: 0.29, green: 0.56, blue: 0.92, alpha: 1)
            case .browsing: return NSColor(srgbRed: 0.35, green: 0.70, blue: 0.90, alpha: 1)
            case .search: return NSColor(srgbRed: 0.25, green: 0.72, blue: 0.70, alpha: 1)
            case .spaces: return NSColor(srgbRed: 0.36, green: 0.74, blue: 0.47, alpha: 1)
            case .shortcuts: return NSColor(srgbRed: 0.56, green: 0.72, blue: 0.32, alpha: 1)
            case .automations: return NSColor(srgbRed: 0.76, green: 0.66, blue: 0.28, alpha: 1)
            case .privacy: return NSColor(srgbRed: 0.91, green: 0.45, blue: 0.32, alpha: 1)
            case .passwords: return NSColor(srgbRed: 0.93, green: 0.62, blue: 0.24, alpha: 1)
            case .websites: return NSColor(srgbRed: 0.90, green: 0.76, blue: 0.28, alpha: 1)
            case .extensions: return NSColor(srgbRed: 0.60, green: 0.47, blue: 0.88, alpha: 1)
            case .importData: return NSColor(srgbRed: 0.47, green: 0.52, blue: 0.90, alpha: 1)
            case .sync: return NSColor(srgbRed: 0.42, green: 0.63, blue: 0.94, alpha: 1)
            case .advanced: return NSColor(srgbRed: 0.55, green: 0.57, blue: 0.64, alpha: 1)
            case .taskManager: return NSColor(srgbRed: 0.30, green: 0.74, blue: 0.82, alpha: 1)
            case .about: return NSColor(srgbRed: 0.85, green: 0.48, blue: 0.66, alpha: 1)
            }
        }
    }

    /// What a pane may assume it has to lay out in. Panes that size themselves
    /// -- Shortcuts, Websites -- measure against this.
    static let windowWidth: CGFloat = Style.SettingsUI.contentMaxWidth

    private let session: BrowserSession
    private let syncCoordinator: SyncCoordinator?
    private let settings: Settings
    private var panes: [Pane: NSViewController] = [:]
    private var shown: Pane?
    private var keyboardParking: [Pane: NSView] = [:]

    /// The size the window opens at, and the least it may be squeezed to.
    ///
    /// The floor is a constraint on the canvas as well as the window's
    /// `minSize`. A window takes its size from its content view controller, and
    /// nothing inside this one demands any particular width -- the spine is 66
    /// points and the form is happy at any width at all -- so without a floor
    /// here the window opens collapsed to a sliver. It did not before only by
    /// accident: the header band's subtitle was a long sentence, and its
    /// intrinsic width was holding the window open.
    private static let openingSize = NSSize(width: 1060, height: 700)
    private static let floorSize = NSSize(width: 880, height: 540)

    private let root = NSViewController()
    private let canvas = SettingsCanvasView()
    private let spine = SettingsSpineView()
    private let eyebrow = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let pageBody = FlippedView()
    /// The reading width a form is held to. Lifted for a pane that is a wide
    /// thing in its own right -- a four-column table has nothing to gain from
    /// being squeezed into a column and a great deal to lose.
    private var readingWidth: NSLayoutConstraint?
    private let paneContainer = FlippedView()

    /// Where "Set to Current Page" reads from.
    var currentPageURL: (() -> URL?)?

    init(session: BrowserSession, syncCoordinator: SyncCoordinator? = nil, settings: Settings = .shared) {
        self.session = session
        self.syncCoordinator = syncCoordinator
        self.settings = settings

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsWindowController.openingSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Kept for the Window menu and for VoiceOver, hidden from the window:
        // the pane's name is already on the page.
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = SettingsWindowController.floorSize

        super.init(window: window)

        buildLayout()
        window.contentViewController = root
        window.delegate = self
        // After the content view controller, which would otherwise size the
        // window to whatever its constraints happen to allow.
        window.setContentSize(Self.openingSize)
        window.setFrameAutosaveName("KylmoraSettings")
        // Setting the autosave name restores the frame the window was last
        // left at, which may be one a previous build saved while it was
        // collapsed. A window that cannot be seen cannot be dragged back out,
        // so anything under the floor is thrown away rather than restored.
        if window.frame.width < Self.floorSize.width || window.frame.height < Self.floorSize.height {
            window.setContentSize(Self.openingSize)
        }
        window.center()
        show(.general)
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is created in code only")
    }

    // MARK: - Layout

    private func buildLayout() {
        root.view = canvas

        spine.onSelect = { [weak self] pane in self?.show(pane) }
        spine.onSearch = { [weak self] query in self?.filter(by: query) }
        spine.onAppearance = { [weak self] preference in
            self?.settings.settingsWindowAppearance = preference
            self?.applyAppearance()
        }
        canvas.addSubview(spine)
        applyAppearance()

        eyebrow.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(eyebrow)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = pageBody
        canvas.addSubview(scroll)
        pageBody.addSubview(paneContainer)

        let gutter = Style.SettingsUI.detailGutter
        let width = paneContainer.widthAnchor.constraint(
            equalTo: pageBody.widthAnchor, constant: -gutter * 2
        )
        // Above .defaultHigh on purpose. A wrapping label hugs its text at
        // exactly .defaultHigh, so at that priority the two ties, and the
        // solver is free to pick either: the pane is the gutter's width on one
        // run and the widest label's natural width on the next. About, whose
        // longest line settles around 585 points, is where the tie shows --
        // the pane came out some four points narrow, and, being centred, wore
        // half of that at each margin. The gutter is the rule; a label's
        // natural width is a preference, and it now loses. The reading-width
        // cap below is required, so it still wins over this.
        width.priority = .required - 1

        NSLayoutConstraint.activate([
            canvas.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.floorSize.width),
            canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.floorSize.height),

            spine.topAnchor.constraint(equalTo: canvas.topAnchor),
            spine.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            spine.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),

            // The name sits where a header band used to be a hundred points.
            //
            // Its baseline is lined up with the search field's centre across
            // the way rather than hung from the top of the window: the two are
            // the only things on this row, and a title floating a few points
            // above or below the field beside it is precisely the sort of
            // near-miss that reads as untidy without being nameable.
            eyebrow.leadingAnchor.constraint(equalTo: spine.trailingAnchor, constant: gutter),
            eyebrow.trailingAnchor.constraint(lessThanOrEqualTo: canvas.trailingAnchor, constant: -gutter),
            eyebrow.centerYAnchor.constraint(
                equalTo: canvas.topAnchor,
                constant: Style.SettingsUI.titlebarHeight + Style.SettingsUI.spineRowHeight / 2
            ),

            scroll.topAnchor.constraint(
                equalTo: eyebrow.bottomAnchor,
                constant: Style.SettingsUI.eyebrowGap
            ),
            scroll.leadingAnchor.constraint(equalTo: spine.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),

            pageBody.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            paneContainer.topAnchor.constraint(
                equalTo: pageBody.topAnchor,
                constant: Style.SettingsUI.paneTopGap
            ),
            paneContainer.bottomAnchor.constraint(equalTo: pageBody.bottomAnchor, constant: -32),
            paneContainer.centerXAnchor.constraint(equalTo: pageBody.centerXAnchor),
            paneContainer.leadingAnchor.constraint(greaterThanOrEqualTo: pageBody.leadingAnchor, constant: gutter),
            width
        ])

        let reading = paneContainer.widthAnchor.constraint(
            lessThanOrEqualToConstant: Style.SettingsUI.contentMaxWidth
        )
        reading.isActive = true
        readingWidth = reading

    }

    /// The window's own appearance, from the choice at the foot of the spine.
    ///
    /// Set on the window rather than on `NSApp`: the application's appearance
    /// is the General pane's business and every browser window's space has
    /// the last word on its own. `nil` -- Automatic -- lets the window inherit
    /// whatever the application is set to.
    func applyAppearance() {
        let preference = settings.settingsWindowAppearance
        window?.appearance = preference.appearance
        spine.showAppearance(preference)
    }

    /// Filters the list of panes. Nothing else.
    ///
    /// It used to open the pane as soon as the search narrowed to one, which
    /// seemed helpful and made typing crawl: every keystroke that happened to
    /// match a single pane built that pane's entire view controller, and some
    /// of them are six hundred lines of controls. Filtering thirteen rows is
    /// free; constructing Privacy is not. Press Return, or click, to open one.
    private func filter(by query: String) {
        spine.show(Pane.allCases.filter { $0.matches(query) })
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

    /// Switches panes from inside one: Advanced's "Manage Extensions".
    func select(_ pane: Pane) { show(pane) }

    /// Was how a pane asked the window to grow around it. The canvas scrolls
    /// now, so a pane that gets taller simply gets taller.
    func paneDidResize() {}

    /// Puts the keyboard in the spine's search.
    @objc func searchSettings(_ sender: Any?) { spine.focusSearch() }

    /// The pane on screen, for a test that measures how panes are laid out.
    var shownPaneView: NSView? { paneContainer.subviews.first }

    /// A row in the list, for a test that wants to know how it is drawn.
    func spineRow(for pane: Pane) -> SettingsSpineView.RowView? { spine.row(for: pane) }

    private func show(_ pane: Pane) {
        spine.select(pane)
        guard pane != shown else { return }
        let previous = shown
        shown = pane

        let controller = panes[pane] ?? make(pane)
        panes[pane] = controller
        window?.title = "Settings \u{2014} \(pane.title)"

        // The pane's name, at the size the type scale already reserved for it.
        //
        // It was set in the 11.5-point group font, upper-cased and tracked out,
        // which is the treatment for a caption *over* something -- and there
        // was nothing over. On its own above an empty row it read as a stray
        // label rather than as the page's title, which is what it is. The
        // 22-point `settingsTitle` has existed all along, documented as "the
        // pane's name at the top of the detail side", and was used nowhere.
        eyebrow.attributedStringValue = NSAttributedString(
            string: pane.title,
            attributes: [
                .font: Style.Fonts.settingsTitle,
                .foregroundColor: pane.accent
            ]
        )
        // The pane's hue runs through its page: the eyebrow, and the edge down
        // every card. It is the same colour as the tile you pressed, which is
        // what ties the spine to what it opened.
        (controller.view as? SettingsForm)?.accent = pane.accent
        (controller.view as? SettingsScrollingPane)?.form.accent = pane.accent
        canvas.accentHint = pane.accent
        spine.accent = pane.accent

        for view in paneContainer.subviews { view.removeFromSuperview() }
        for child in root.children { child.removeFromParent() }
        root.addChild(controller)

        let view = controller.view
        readingWidth?.isActive = !(controller is SettingsWidePane)
        view.translatesAutoresizingMaskIntoConstraints = false
        paneContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: paneContainer.topAnchor),
            view.leadingAnchor.constraint(equalTo: paneContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: paneContainer.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: paneContainer.bottomAnchor)
        ])

        // The pane arrives from the side of the spine it was chosen from: a
        // pane further down the list comes up from below, one further up comes
        // down from above. A pane that always slid the same way would say the
        // list has a direction and then contradict it half the time; this way
        // the movement and the spine agree, and the window reads as one surface
        // being scrolled rather than as pages being swapped.
        //
        // Nothing to travel from on the first pane of a freshly opened window:
        // it is not replacing anything, so it simply fades up.
        let travel = previous.map {
            pane.rawValue > $0.rawValue ? Style.Motion.entrySlide : -Style.Motion.entrySlide
        } ?? 0
        SpringPresence.slideIn(view, from: CGVector(dx: 0, dy: travel), fading: true)

        // Every pane starts at its top. Carrying the last pane's scroll offset
        // into a shorter one lands the reader in the middle of a page they have
        // not seen.
        scroll.documentView?.scroll(.zero)
        scroll.reflectScrolledClipView(scroll.contentView)

        // A pane arrives with nothing focused. Otherwise the first text field
        // takes the keyboard and wears a focus ring before the user has touched
        // anything, which reads as a field demanding input.
        let parking = keyboardParking[pane] ?? {
            let parking = KeyboardParkingView()
            controller.view.addSubview(parking)
            keyboardParking[pane] = parking
            return parking
        }()
        window?.initialFirstResponder = parking
        window?.makeFirstResponder(parking)
    }

    /// Nothing to see: a zero-size view that holds the keyboard.
    private final class KeyboardParkingView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// Settings pages are read top-down, so every container here is flipped.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            translatesAutoresizingMaskIntoConstraints = false
        }
        required init?(coder: NSCoder) {
            fatalError("FlippedView is created in code only")
        }
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
        case .automations: return AutomationsSettingsViewController(session: session)
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
        case .taskManager: return TaskManagerSettingsViewController(session: session, settings: settings)
        case .about: return AboutSettingsViewController()
        }
    }
}

extension SettingsWindowController: NSWindowDelegate {
    /// Every switch the form put in front of a checkbox is observing it. The
    /// window is kept alive between openings, so this is the one moment those
    /// observers can be let go without the panes being rebuilt.
    func windowWillClose(_ notification: Notification) {
        for controller in panes.values {
            (controller.view as? SettingsForm)?.stopObserving()
            (controller.view as? SettingsScrollingPane)?.form.stopObserving()
        }
    }
}
