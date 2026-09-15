import AppKit

/// Settings sheet for customizing and pruning the web view context menu (F-31).
@MainActor
final class ContextMenuSettingsViewController: NSViewController, NSTextFieldDelegate {
    var onDismiss: (() -> Void)?

    private let settings: Settings

    // Text & Search
    private let searchSelection = NSButton(checkboxWithTitle: "Search default engine for selected text", target: nil, action: nil)
    private let searchSubmenu = NSButton(checkboxWithTitle: "Show \"Search Selection With\" submenu for all engines", target: nil, action: nil)

    // Links & Previews
    private let copyCleanLink = NSButton(checkboxWithTitle: "Show \"Copy Clean Link\" (strips tracking parameters)", target: nil, action: nil)
    private let glanceActions = NSButton(checkboxWithTitle: "Show \"Open Link in Glance / Little Arc / Split View\"", target: nil, action: nil)
    private let captureScreenshot = NSButton(checkboxWithTitle: "Show \"Capture Screenshot\" submenu", target: nil, action: nil)

    // System Items
    private let inspectElement = NSButton(checkboxWithTitle: "Show \"Inspect Element\"", target: nil, action: nil)
    private let shareMenu = NSButton(checkboxWithTitle: "Show system \"Share\" menu", target: nil, action: nil)
    private let servicesMenu = NSButton(checkboxWithTitle: "Show system \"Services\" menu", target: nil, action: nil)
    private let speechMenu = NSButton(checkboxWithTitle: "Show system \"Speech\" menu", target: nil, action: nil)
    private let reloadPage = NSButton(checkboxWithTitle: "Show \"Reload Page\"", target: nil, action: nil)
    private let printPage = NSButton(checkboxWithTitle: "Show \"Print…\"", target: nil, action: nil)

    // Blacklist
    private let blacklistField = NSTextField()

    init(settings: Settings = .shared) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("ContextMenuSettingsViewController is created in code only")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 540))
        buildLayout()
        reload()
    }

    private func buildLayout() {
        let title = NSTextField(labelWithString: "Context Menu Customization")
        title.font = .systemFont(ofSize: 16, weight: .bold)

        let subtitle = NSTextField(wrappingLabelWithString: "Choose which actions appear when right-clicking on pages, links, and selected text.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor

        for box in [searchSelection, searchSubmenu, copyCleanLink, glanceActions,
                    captureScreenshot, inspectElement, shareMenu, servicesMenu,
                    speechMenu, reloadPage, printPage] {
            box.target = self
            box.action = #selector(checkboxChanged)
        }

        let searchHeading = sectionHeading("Search & Selection")
        let searchStack = NSStackView(views: [searchSelection, searchSubmenu])
        searchStack.orientation = .vertical
        searchStack.alignment = .leading
        searchStack.spacing = 6

        let linkHeading = sectionHeading("Links & Previews")
        let linkStack = NSStackView(views: [copyCleanLink, glanceActions, captureScreenshot])
        linkStack.orientation = .vertical
        linkStack.alignment = .leading
        linkStack.spacing = 6

        let systemHeading = sectionHeading("System & Developer Items")
        let systemGrid = NSStackView(views: [
            inspectElement, reloadPage, printPage, shareMenu, servicesMenu, speechMenu
        ])
        systemGrid.orientation = .vertical
        systemGrid.alignment = .leading
        systemGrid.spacing = 6

        let blacklistHeading = sectionHeading("Hide Items by Title")
        let blacklistNote = NSTextField(wrappingLabelWithString: "Enter comma-separated words or titles to remove from all context menus:")
        blacklistNote.font = .systemFont(ofSize: 11)
        blacklistNote.textColor = .secondaryLabelColor

        blacklistField.placeholderString = "e.g. Open Image in New Window, Download Video"
        blacklistField.delegate = self

        let doneButton = NSButton(title: "Done", target: self, action: #selector(doneClicked))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"

        let stack = NSStackView(views: [
            title, subtitle,
            searchHeading, searchStack,
            linkHeading, linkStack,
            systemHeading, systemGrid,
            blacklistHeading, blacklistNote, blacklistField
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        doneButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(doneButton)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            blacklistField.widthAnchor.constraint(equalTo: stack.widthAnchor),

            doneButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            doneButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])
    }

    private func sectionHeading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        return label
    }

    private func reload() {
        searchSelection.state = settings.contextMenuSearchSelection ? .on : .off
        searchSubmenu.state = settings.contextMenuSearchSubmenu ? .on : .off
        copyCleanLink.state = settings.contextMenuCopyCleanLink ? .on : .off
        glanceActions.state = settings.contextMenuGlanceActions ? .on : .off
        captureScreenshot.state = settings.contextMenuCaptureScreenshot ? .on : .off
        inspectElement.state = settings.contextMenuInspectElement ? .on : .off
        shareMenu.state = settings.contextMenuShareMenu ? .on : .off
        servicesMenu.state = settings.contextMenuServicesMenu ? .on : .off
        speechMenu.state = settings.contextMenuSpeechMenu ? .on : .off
        reloadPage.state = settings.contextMenuReloadPage ? .on : .off
        printPage.state = settings.contextMenuPrint ? .on : .off

        blacklistField.stringValue = settings.contextMenuHiddenTitles.joined(separator: ", ")
    }

    @objc private func checkboxChanged(_ sender: Any?) {
        settings.contextMenuSearchSelection = (searchSelection.state == .on)
        settings.contextMenuSearchSubmenu = (searchSubmenu.state == .on)
        settings.contextMenuCopyCleanLink = (copyCleanLink.state == .on)
        settings.contextMenuGlanceActions = (glanceActions.state == .on)
        settings.contextMenuCaptureScreenshot = (captureScreenshot.state == .on)
        settings.contextMenuInspectElement = (inspectElement.state == .on)
        settings.contextMenuShareMenu = (shareMenu.state == .on)
        settings.contextMenuServicesMenu = (servicesMenu.state == .on)
        settings.contextMenuSpeechMenu = (speechMenu.state == .on)
        settings.contextMenuReloadPage = (reloadPage.state == .on)
        settings.contextMenuPrint = (printPage.state == .on)
    }

    func controlTextDidChange(_ obj: Notification) {
        let titles = blacklistField.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        settings.contextMenuHiddenTitles = titles
    }

    @objc private func doneClicked() {
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        onDismiss?()
        dismiss(nil)
    }
}
