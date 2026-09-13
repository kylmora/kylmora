import AppKit

/// The strip of bookmarks under the bar above the page.
///
/// Shown or not per space, and drawn as icons and titles, icons alone or
/// titles alone, as the space says. Every top-level bookmark is a chip;
/// an imported folder is a chip that drops a menu of its contents. The
/// chips that do not fit go behind a chevron at the trailing end, so the bar
/// never clips a title in half and never scrolls.
@MainActor
final class BookmarksBarView: NSView {
    static let height: CGFloat = 30
    private static let chipSpacing: CGFloat = 2
    private static let inset: CGFloat = 8

    /// A chip, or an item from a folder or the overflow menu, was clicked.
    var onOpen: ((URL) -> Void)?

    private var chips: [Chip] = []
    private var nodes: [BookmarkTree] = []
    private let overflow = IconButton(symbolName: "chevron.right.2", label: "More Bookmarks")
    private var style: BookmarksBarStyle = .iconAndText
    private var isPrivate = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        overflow.translatesAutoresizingMaskIntoConstraints = false
        overflow.setClickHandler { [weak self] in self?.showOverflowMenu() }
        addSubview(overflow)
        NSLayoutConstraint.activate([
            overflow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            overflow.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Bookmarks bar")
    }

    required init?(coder: NSCoder) {
        fatalError("BookmarksBarView is created in code only")
    }

    /// Replaces the chips. Cheap enough to call on every bookmark change:
    /// a bookmarks list is tens of items, not thousands.
    func show(_ bookmarks: [Bookmark], style: BookmarksBarStyle, isPrivate: Bool) {
        self.style = style
        self.isPrivate = isPrivate
        nodes = BookmarkTree.build(from: bookmarks)
        for chip in chips { chip.removeFromSuperview() }
        chips = nodes.map { node in
            let chip = Chip(node: node, style: style, isPrivate: isPrivate)
            chip.onActivate = { [weak self] source in self?.activate(node, from: source) }
            addSubview(chip)
            return chip
        }
        needsLayout = true
    }

    /// A bookmark opens; a folder drops its menu below the chip.
    private func activate(_ node: BookmarkTree, from source: NSView) {
        switch node {
        case .bookmark(let bookmark):
            onOpen?(bookmark.url)
        case .folder(_, let items):
            let menu = buildMenu(from: items)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: source.bounds.height + 2), in: source)
        }
    }

    /// A menu mirroring a folder's contents, folders inside becoming submenus.
    private func buildMenu(from items: [BookmarkTree]) -> NSMenu {
        let menu = NSMenu()
        for item in items { add(item, to: menu) }
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        return menu
    }

    private func add(_ node: BookmarkTree, to menu: NSMenu) {
        switch node {
        case .bookmark(let bookmark):
            let item = NSMenuItem(
                title: bookmark.title.isEmpty ? bookmark.url.absoluteString : bookmark.title,
                action: #selector(openMenuItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = bookmark.url
            item.toolTip = bookmark.url.absoluteString
            menu.addItem(item)
        case .folder(let name, let children):
            let item = NSMenuItem(title: name.isEmpty ? "Folder" : name, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            item.submenu = buildMenu(from: children)
            menu.addItem(item)
        }
    }

    /// Lays the chips out by hand: an `NSStackView` would either squash
    /// titles or grow past the bar, and neither is what a bookmarks bar does.
    override func layout() {
        super.layout()
        let overflowWidth = overflow.fittingSize.width + Self.chipSpacing
        let available = bounds.width - Self.inset * 2
        var x = Self.inset
        var hiddenFrom = chips.count
        for (index, chip) in chips.enumerated() {
            let width = chip.fittingSize.width
            // The last chip may use the overflow button's room; any earlier
            // one has to leave it.
            let reserve = index == chips.count - 1 ? 0 : overflowWidth
            if x - Self.inset + width + reserve > available {
                hiddenFrom = index
                break
            }
            chip.frame = NSRect(x: x, y: (bounds.height - Chip.height) / 2, width: width, height: Chip.height)
            chip.isHidden = false
            x += width + Self.chipSpacing
        }
        for chip in chips[hiddenFrom...] { chip.isHidden = true }
        overflow.isHidden = hiddenFrom == chips.count
    }

    private func showOverflowMenu() {
        let menu = NSMenu()
        for (index, node) in nodes.enumerated() where chips.indices.contains(index) && chips[index].isHidden {
            add(node, to: menu)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: overflow.frame.minX, y: overflow.frame.minY), in: self)
    }

    @objc private func openMenuItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpen?(url)
    }

    /// One entry on the bar: a bookmark's icon and title, or a folder's glyph
    /// and name, on a pill that shows on hover.
    @MainActor
    private final class Chip: NSControl {
        static let height: CGFloat = 22
        /// Activated by a click; hands back itself so a folder's menu can be
        /// anchored to it.
        var onActivate: ((NSView) -> Void)?

        private let icon = FaviconImageView()
        private let label = NSTextField(labelWithString: "")
        private var trackingArea: NSTrackingArea?
        private var isHovered = false {
            didSet { if isHovered != oldValue { needsDisplay = true } }
        }

        init(node: BookmarkTree, style: BookmarksBarStyle, isPrivate: Bool) {
            super.init(frame: .zero)
            wantsLayer = true

            var views: [NSView] = []
            let title: String
            switch node {
            case .bookmark(let bookmark):
                title = bookmark.title.isEmpty ? (bookmark.url.host() ?? bookmark.url.absoluteString) : bookmark.title
                toolTip = bookmark.url.absoluteString
                if style.showsIcon {
                    icon.show(for: bookmark.url, in: nil, isPrivate: isPrivate)
                    views.append(icon)
                }
                if style.showsText { views.append(configuredLabel(title)) }
            case .folder(let name, _):
                title = name.isEmpty ? "Folder" : name
                toolTip = title
                // A folder always shows its glyph and name, whatever the bar
                // style: identical nameless folder chips would be a guessing
                // game to click through.
                let glyph = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage())
                glyph.contentTintColor = Style.Colors.secondaryText
                views.append(glyph)
                views.append(configuredLabel(title))
            }

            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel(title)

            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.spacing = 5
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }

        required init?(coder: NSCoder) {
            fatalError("Chip is created in code only")
        }

        /// The chip's single label, set up once with the given text.
        private func configuredLabel(_ title: String) -> NSTextField {
            label.stringValue = title
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 160).isActive = true
            return label
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) { isHovered = true }
        override func mouseExited(with event: NSEvent) { isHovered = false }
        override func mouseDown(with event: NSEvent) { onActivate?(self) }
        override func accessibilityPerformPress() -> Bool {
            onActivate?(self)
            return true
        }

        override func draw(_ dirtyRect: NSRect) {
            guard isHovered else { return }
            Style.Colors.rowHoverFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
    }
}
