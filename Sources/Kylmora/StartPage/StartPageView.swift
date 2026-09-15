import AppKit

/// Kylmora's new-tab page: the Space's pinned sites and most visited sites as
/// tiles, then recently closed tabs and the unread reading list as rows.
///
/// A native view over the (blank) web view, like the error page: a page
/// cannot draw over it, nothing is fetched to show it, and it needs no
/// `data:` URL that would end up in history.
@MainActor
final class StartPageView: NSView {
    /// Open this address in the tab.
    var onOpen: ((URL) -> Void)?

    private(set) var model = StartPageModel()
    private let scroll = NSScrollView()
    private let column = NSStackView()
    private let wash = CAGradientLayer()
    private var isPrivate = false

    /// The tiles and rows on screen, for tests.
    private(set) var tileCount = 0
    private(set) var rowCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        wash.startPoint = CGPoint(x: 0.5, y: 1)
        wash.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(wash)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 28
        column.translatesAutoresizingMaskIntoConstraints = false

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)
        scroll.documentView = document

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            column.topAnchor.constraint(equalTo: document.topAnchor, constant: 56),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -56),
            column.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 32),
            column.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -32)
        ])
        let preferred = column.widthAnchor.constraint(equalToConstant: 760)
        preferred.priority = .defaultLow
        preferred.isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("StartPageView is created in code only")
    }

    override func layout() {
        super.layout()
        wash.frame = CGRect(x: 0, y: bounds.height - 220, width: bounds.width, height: 220)
    }

    func configure(with model: StartPageModel) {
        self.model = model
        isPrivate = model.isPrivate
        let tint = model.spaceColor ?? .controlAccentColor
        wash.colors = [tint.withAlphaComponent(0.16).cgColor, tint.withAlphaComponent(0).cgColor]

        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tileCount = 0
        rowCount = 0

        let heading = NSTextField(labelWithString: model.spaceName.isEmpty ? StartPage.title : model.spaceName)
        heading.font = .systemFont(ofSize: 26, weight: .bold)
        heading.textColor = .labelColor
        column.addArrangedSubview(heading)

        if model.isPrivate {
            column.addArrangedSubview(note("Private Space: nothing is kept after these tabs close.", symbol: "eye.slash"))
        }

        if !model.pinned.isEmpty {
            column.addArrangedSubview(section("Pinned", tiles(model.pinned)))
        }
        let top = Array(model.topSitesNotPinned.prefix(8))
        if !top.isEmpty {
            column.addArrangedSubview(section("Most visited", tiles(top)))
        }
        if !model.recentlyClosed.isEmpty {
            column.addArrangedSubview(section("Recently closed", rows(Array(model.recentlyClosed.prefix(6)), symbol: "arrow.uturn.backward")))
        }
        if !model.readingList.isEmpty {
            column.addArrangedSubview(section("Reading list", rows(Array(model.readingList.prefix(5)), symbol: "book")))
        }
        if model.isEmpty {
            column.addArrangedSubview(note("Type an address or a search above. Sites you pin and visit will gather here.", symbol: "sparkles"))
        }
    }

    // MARK: - Pieces

    private func section(_ title: String, _ content: NSView) -> NSView {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [label, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    private func note(_ text: String, symbol: String) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 600
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 8
        return stack
    }

    /// A wrapping grid of tiles: favicon above a one-line title.
    private func tiles(_ links: [StartPageModel.Link]) -> NSView {
        let grid = NSGridView()
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        let perRow = 6
        var row: [NSView] = []
        for link in links {
            row.append(tile(link))
            if row.count == perRow {
                grid.addRow(with: row)
                row = []
            }
        }
        if !row.isEmpty {
            while row.count < perRow { row.append(NSView()) }
            grid.addRow(with: row)
        }
        return grid
    }

    private func tile(_ link: StartPageModel.Link) -> NSView {
        tileCount += 1
        let button = StartPageTile(link: link, isPrivate: isPrivate) { [weak self] url in self?.onOpen?(url) }
        return button
    }

    private func rows(_ links: [StartPageModel.Link], symbol: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        for link in links {
            rowCount += 1
            stack.addArrangedSubview(StartPageRow(link: link, symbol: symbol) { [weak self] url in self?.onOpen?(url) })
        }
        return stack
    }
}

/// One site on the start page: its favicon over its name.
@MainActor
final class StartPageTile: NSControl {
    let link: StartPageModel.Link
    private let favicon = FaviconImageView()
    private let label = NSTextField(labelWithString: "")
    private let plate = NSView()
    private let open: (URL) -> Void

    init(link: StartPageModel.Link, isPrivate: Bool, open: @escaping (URL) -> Void) {
        self.link = link
        self.open = open
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = link.url.absoluteString
        setAccessibilityRole(.button)
        setAccessibilityLabel(link.title)

        plate.wantsLayer = true
        plate.layer?.cornerRadius = 14
        plate.layer?.cornerCurve = .continuous
        plate.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
        plate.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plate)

        favicon.translatesAutoresizingMaskIntoConstraints = false
        favicon.show(for: link.url, in: nil, isPrivate: isPrivate)
        plate.addSubview(favicon)

        label.stringValue = link.title
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 108),
            plate.topAnchor.constraint(equalTo: topAnchor),
            plate.centerXAnchor.constraint(equalTo: centerXAnchor),
            plate.widthAnchor.constraint(equalToConstant: 64),
            plate.heightAnchor.constraint(equalToConstant: 64),
            favicon.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
            favicon.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
            favicon.widthAnchor.constraint(equalToConstant: 28),
            favicon.heightAnchor.constraint(equalToConstant: 28),
            label.topAnchor.constraint(equalTo: plate.bottomAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("StartPageTile is created in code only")
    }

    override func mouseDown(with event: NSEvent) {
        plate.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.28).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        plate.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
        if bounds.contains(convert(event.locationInWindow, from: nil)) { activate() }
    }

    func activate() { open(link.url) }
}

/// One line on the start page: a symbol, the title, the host.
@MainActor
final class StartPageRow: NSControl {
    let link: StartPageModel.Link
    private let open: (URL) -> Void

    init(link: StartPageModel.Link, symbol: String, open: @escaping (URL) -> Void) {
        self.link = link
        self.open = open
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = link.url.absoluteString
        setAccessibilityRole(.button)
        setAccessibilityLabel(link.title)

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = .tertiaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let title = NSTextField(labelWithString: link.title)
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let host = NSTextField(labelWithString: link.url.host() ?? "")
        host.font = .systemFont(ofSize: 11)
        host.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [icon, title, host])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 760)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("StartPageRow is created in code only")
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { activate() }
    }

    func activate() { open(link.url) }
}
