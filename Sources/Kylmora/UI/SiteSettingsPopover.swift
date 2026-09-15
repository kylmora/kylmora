import AppKit

/// The per-site settings popover, hung off the top bar's gear button.
///
/// Every row is a real `SiteSettings` category for the page's host, read and
/// written live -- nothing here is decoration. Changes persist as they are made
/// (so the content blocker recompiles at once); the page reloads when the
/// popover closes, so settings that only take at load time take together.
@MainActor
final class SiteSettingsPopover: NSViewController {
    /// Called when the popover closes after something changed, so the caller can
    /// reload the page for the new settings.
    var onApply: (() -> Void)?

    private let url: URL
    private var host: String { SiteSettingsState.normalise(url.host() ?? "") }
    private var didChange = false

    /// On/off style categories, shown as checkboxes. The id is the option that
    /// means "checked".
    private let checkboxes: [(category: SiteSettingCategory, onID: String, label: String)] = [
        (.contentBlockers, "on", "Enable Content Blockers"),
        (.antiFingerprinting, "on", "Anti-Fingerprinting Protection"),
        (.blockHostileBehaviour, "on", "Block Hostile Page Behaviour"),
        (.nativeVideoPlayer, "on", "Native Video Player (PiP, Background)"),
        (.javaScript, "on", "Enable JavaScript"),
        (.cookies, "allow", "Enable Cookies"),
        (.forgetWhenClosed, "on", "Forget Data When Closed"),
        (.webFonts, "allow", "Enable Web Fonts"),
        (.readerMode, "on", "Enable Reader Mode"),
        (.sslCheck, "on", "Check SSL Certificate")
    ]
    /// Multi-choice categories, shown as pop-ups.
    private let choices: [SiteSettingCategory] = [
        .trackingPrevention, .autoPlay, .pageZoom, .popups, .compatibilityMode, .userAgent, .pictureInPicture
    ]
    /// Permission categories (Ask / Allow / Deny), also pop-ups.
    private let permissions: [SiteSettingCategory] = [
        .camera, .microphone, .screenSharing, .location, .notifications, .downloads, .externalApps
    ]

    private var checkboxControls: [SiteSettingCategory: NSButton] = [:]
    private var popupControls: [SiteSettingCategory: NSPopUpButton] = [:]

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("SiteSettingsPopover is created in code only") }

    override func loadView() {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        content.translatesAutoresizingMaskIntoConstraints = false

        content.addArrangedSubview(header())
        content.addArrangedSubview(separator())

        for entry in checkboxes {
            content.addArrangedSubview(makeCheckbox(entry.category, onID: entry.onID, label: entry.label))
        }

        content.addArrangedSubview(separator())
        for category in choices {
            content.addArrangedSubview(makePopupRow(category))
        }

        content.addArrangedSubview(separator())
        for category in permissions {
            content.addArrangedSubview(makePopupRow(category))
        }

        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.widthAnchor.constraint(equalToConstant: 340)
        ])
        view = container
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if didChange { onApply?() }
    }

    // MARK: - Building

    private func header() -> NSView {
        let title = NSTextField(labelWithString: "Settings for \(host.isEmpty ? "this site" : host)")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let reset = NSButton(title: "Reset", target: self, action: #selector(reset))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [title, reset])
        row.orientation = .horizontal
        row.distribution = .fill
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.widthAnchor.constraint(equalToConstant: 308).isActive = true
        return row
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 308).isActive = true
        return line
    }

    private func makeCheckbox(_ category: SiteSettingCategory, onID: String, label: String) -> NSButton {
        let box = NSButton(checkboxWithTitle: label, target: self, action: #selector(checkboxToggled(_:)))
        box.state = SiteSettings.shared.resolve(category, for: url) == onID ? .on : .off
        box.tag = SiteSettingCategory.allCases.firstIndex(of: category) ?? 0
        checkboxControls[category] = box
        return box
    }

    private func makePopupRow(_ category: SiteSettingCategory) -> NSView {
        let label = NSTextField(labelWithString: "\(category.title):")
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let popup = NSPopUpButton()
        popup.addItems(withTitles: category.options.map(\.title))
        let current = SiteSettings.shared.resolve(category, for: url)
        if let index = category.options.firstIndex(where: { $0.id == current }) {
            popup.selectItem(at: index)
        }
        popup.target = self
        popup.action = #selector(popupChanged(_:))
        popup.tag = SiteSettingCategory.allCases.firstIndex(of: category) ?? 0
        popupControls[category] = popup

        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    // MARK: - Actions

    @objc private func checkboxToggled(_ sender: NSButton) {
        guard let category = SiteSettingCategory.allCases[safe: sender.tag],
              let entry = checkboxes.first(where: { $0.category == category }) else { return }
        let offID = category.options.first { $0.id != entry.onID }?.id ?? entry.onID
        write(category, to: sender.state == .on ? entry.onID : offID)
    }

    @objc private func popupChanged(_ sender: NSPopUpButton) {
        guard let category = SiteSettingCategory.allCases[safe: sender.tag],
              sender.indexOfSelectedItem >= 0,
              category.options.indices.contains(sender.indexOfSelectedItem) else { return }
        write(category, to: category.options[sender.indexOfSelectedItem].id)
    }

    @objc private func reset() {
        SiteSettings.shared.update { state in
            for category in SiteSettingCategory.allCases { state.remove(host, from: category) }
        }
        didChange = true
        reloadControls()
    }

    private func write(_ category: SiteSettingCategory, to optionID: String) {
        SiteSettings.shared.update { $0.set(optionID, for: host, in: category) }
        didChange = true
    }

    /// Re-reads every control from the resolved settings, after a Reset.
    private func reloadControls() {
        for entry in checkboxes {
            checkboxControls[entry.category]?.state =
                SiteSettings.shared.resolve(entry.category, for: url) == entry.onID ? .on : .off
        }
        for (category, popup) in popupControls {
            let current = SiteSettings.shared.resolve(category, for: url)
            if let index = category.options.firstIndex(where: { $0.id == current }) {
                popup.selectItem(at: index)
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
