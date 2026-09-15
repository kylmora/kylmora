import AppKit
import WebKit

@MainActor
final class WebPanelHeaderView: NSView {
    var onSelectPanel: ((UUID) -> Void)?
    var onAddPanel: (() -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onReloadOrStop: (() -> Void)?
    var onOpenInTab: (() -> Void)?
    var onPopOut: (() -> Void)?
    var onClose: (() -> Void)?

    private let iconImageView = NSImageView()
    private let titleButton = NSButton()
    private let backButton = IconButton(symbolName: "chevron.left", label: "Back", side: 22)
    private let forwardButton = IconButton(symbolName: "chevron.right", label: "Forward", side: 22)
    private let reloadButton = IconButton(symbolName: "arrow.clockwise", label: "Reload", side: 22)
    private let openInTabButton = IconButton(symbolName: "arrow.up.right.square", label: "Open in Tab", side: 22)
    private let popOutButton = IconButton(symbolName: "macwindow.on.rectangle", label: "Pop Out into Floating Window", side: 22)
    private let closeButton = IconButton(symbolName: "xmark", label: "Close Panel", side: 22)
    private let progressIndicator = NSProgressIndicator()
    private let separator = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("WebPanelHeaderView is created in code only")
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 38).isActive = true

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.imageScaling = .scaleProportionallyDown
        iconImageView.contentTintColor = Style.Colors.secondaryText
        NSLayoutConstraint.activate([
            iconImageView.widthAnchor.constraint(equalToConstant: 16),
            iconImageView.heightAnchor.constraint(equalToConstant: 16)
        ])

        titleButton.translatesAutoresizingMaskIntoConstraints = false
        titleButton.isBordered = false
        titleButton.bezelStyle = .accessoryBarAction
        titleButton.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleButton.alignment = .left
        titleButton.lineBreakMode = .byTruncatingTail
        titleButton.target = self
        titleButton.action = #selector(showPanelMenu)

        backButton.setClickHandler { [weak self] in self?.onBack?() }
        forwardButton.setClickHandler { [weak self] in self?.onForward?() }
        reloadButton.setClickHandler { [weak self] in self?.onReloadOrStop?() }
        openInTabButton.setClickHandler { [weak self] in self?.onOpenInTab?() }
        popOutButton.setClickHandler { [weak self] in self?.onPopOut?() }
        closeButton.setClickHandler { [weak self] in self?.onClose?() }

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0.0
        progressIndicator.maxValue = 1.0
        progressIndicator.style = .bar
        progressIndicator.isHidden = true

        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator

        let titleStack = NSStackView(views: [iconImageView, titleButton])
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.orientation = .horizontal
        titleStack.spacing = 6
        titleStack.alignment = .centerY

        let navStack = NSStackView(views: [backButton, forwardButton, reloadButton])
        navStack.translatesAutoresizingMaskIntoConstraints = false
        navStack.orientation = .horizontal
        navStack.spacing = 2
        navStack.alignment = .centerY

        let actionStack = NSStackView(views: [openInTabButton, popOutButton, closeButton])
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.orientation = .horizontal
        actionStack.spacing = 2
        actionStack.alignment = .centerY

        addSubview(titleStack)
        addSubview(navStack)
        addSubview(actionStack)
        addSubview(progressIndicator)
        addSubview(separator)

        NSLayoutConstraint.activate([
            titleStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: navStack.leadingAnchor, constant: -6),

            navStack.trailingAnchor.constraint(equalTo: actionStack.leadingAnchor, constant: -4),
            navStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            actionStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            actionStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),

            progressIndicator.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressIndicator.trailingAnchor.constraint(equalTo: trailingAnchor),
            progressIndicator.bottomAnchor.constraint(equalTo: bottomAnchor),
            progressIndicator.heightAnchor.constraint(equalToConstant: 2)
        ])
    }

    func update(panel: WebPanel, canGoBack: Bool, canGoForward: Bool, isLoading: Bool) {
        iconImageView.image = NSImage(systemSymbolName: panel.symbolName, accessibilityDescription: panel.title)
        titleButton.title = "\(panel.title) ▾"
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        if isLoading {
            reloadButton.setSymbol("xmark", label: "Stop Loading")
            progressIndicator.isHidden = false
        } else {
            reloadButton.setSymbol("arrow.clockwise", label: "Reload")
            progressIndicator.isHidden = true
        }
    }

    func setProgress(_ progress: Double) {
        progressIndicator.doubleValue = progress
        progressIndicator.isHidden = progress >= 1.0 || progress <= 0.0
    }

    @objc private func showPanelMenu() {
        let menu = NSMenu(title: "Web Panels")
        let store = WebPanelStore.shared

        for panel in store.panels {
            let item = NSMenuItem(
                title: panel.title,
                action: #selector(panelItemClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = panel.id
            item.image = NSImage(systemSymbolName: panel.symbolName, accessibilityDescription: panel.title)
            if panel.id == store.activePanelId {
                item.state = .on
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let addMenu = NSMenuItem(title: "Add Web Panel…", action: #selector(addPanelClicked), keyEquivalent: "")
        addMenu.target = self
        menu.addItem(addMenu)

        menu.popUp(positioning: nil, at: NSPoint(x: 10, y: bounds.height - 4), in: self)
    }

    @objc private func panelItemClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onSelectPanel?(id)
    }

    @objc private func addPanelClicked() {
        onAddPanel?()
    }
}
