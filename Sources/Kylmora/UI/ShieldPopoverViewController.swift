import AppKit
import Foundation
import WebKit

/// The popover shown when clicking the Shield button in the top bar.
///
/// Gives a 1-click toggle to pause or enable content blocking on the current site,
/// displays active rules & filter list statistics, and provides shortcuts to launch
/// the interactive Element Picker or open the Filter Lists & My Rules settings.
@MainActor
final class ShieldPopoverViewController: NSViewController {
    private let url: URL?
    private weak var webView: WKWebView?
    private let onReload: () -> Void
    private let onBlockElement: () -> Void
    private let onOpenSettings: () -> Void

    private var host: String {
        guard let host = url?.host() else { return "This Site" }
        return SiteSettings.normalise(host)
    }

    private let shieldImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let toggleSwitch = NSSwitch()
    private let reloadButton = NSButton()

    init(
        url: URL?,
        webView: WKWebView?,
        onReload: @escaping () -> Void,
        onBlockElement: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.url = url
        self.webView = webView
        self.onReload = onReload
        self.onBlockElement = onBlockElement
        self.onOpenSettings = onOpenSettings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("ShieldPopoverViewController is created in code only")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 340))
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root

        let isBlocked = SiteSettings.shared.blocksContent(for: url)

        // Header
        shieldImageView.imageScaling = .scaleProportionallyUpOrDown
        shieldImageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            shieldImageView.widthAnchor.constraint(equalToConstant: 36),
            shieldImageView.heightAnchor.constraint(equalToConstant: 36)
        ])

        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.stringValue = host

        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor

        let headerTextStack = NSStackView(views: [titleLabel, subtitleLabel])
        headerTextStack.orientation = .vertical
        headerTextStack.alignment = .leading
        headerTextStack.spacing = 2

        let headerStack = NSStackView(views: [shieldImageView, headerTextStack])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 12

        // Toggle Switch Row
        let toggleLabel = NSTextField(labelWithString: "Block Ads & Trackers")
        toggleLabel.font = .systemFont(ofSize: 13, weight: .medium)

        toggleSwitch.state = isBlocked ? .on : .off
        toggleSwitch.target = self
        toggleSwitch.action = #selector(toggleChanged)

        let toggleRow = NSStackView(views: [toggleLabel, NSView(), toggleSwitch])
        toggleRow.orientation = .horizontal
        toggleRow.alignment = .centerY
        toggleRow.translatesAutoresizingMaskIntoConstraints = false

        // Reload prompt button
        reloadButton.title = "Reload to Apply Changes"
        reloadButton.bezelStyle = .rounded
        reloadButton.controlSize = .small
        reloadButton.target = self
        reloadButton.action = #selector(reloadTapped)
        reloadButton.isHidden = true

        // Stats card
        let statsBox = NSBox()
        statsBox.boxType = .custom
        statsBox.borderWidth = 1
        statsBox.borderColor = NSColor.separatorColor.withAlphaComponent(0.4)
        statsBox.fillColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.2)
        statsBox.cornerRadius = 8
        statsBox.translatesAutoresizingMaskIntoConstraints = false

        let summary = ContentBlocker.shared.activeSummary
        let userRulesCount = ContentBlocker.shared.userRulesCount

        let ruleCountLabel = NSTextField(labelWithString: "🛡️ \(summary.rules.formatted()) rules active across \(summary.lists) lists")
        ruleCountLabel.font = .systemFont(ofSize: 11)
        ruleCountLabel.textColor = .secondaryLabelColor

        let userRuleLabel = NSTextField(labelWithString: "🎯 \(userRulesCount) custom user rules")
        userRuleLabel.font = .systemFont(ofSize: 11)
        userRuleLabel.textColor = .secondaryLabelColor

        let cookieStatus = Settings.shared.autoRejectCookieBanners ? "Active" : "Disabled"
        let cookieLabel = NSTextField(labelWithString: "🍪 Auto-reject cookie banners: \(cookieStatus)")
        cookieLabel.font = .systemFont(ofSize: 11)
        cookieLabel.textColor = .secondaryLabelColor

        let statsStack = NSStackView(views: [ruleCountLabel, userRuleLabel, cookieLabel])
        statsStack.orientation = .vertical
        statsStack.alignment = .leading
        statsStack.spacing = 4
        statsStack.translatesAutoresizingMaskIntoConstraints = false
        statsBox.contentView = statsStack

        // Action buttons
        let blockElementButton = NSButton(
            title: "Block Element on Page\u{2026}",
            target: self,
            action: #selector(blockElementTapped)
        )
        blockElementButton.bezelStyle = .rounded
        blockElementButton.image = NSImage(systemSymbolName: "target", accessibilityDescription: "Block Element")
        blockElementButton.imagePosition = .imageLeading

        let settingsButton = NSButton(
            title: "Filter Lists & My Rules\u{2026}",
            target: self,
            action: #selector(settingsTapped)
        )
        settingsButton.bezelStyle = .rounded
        settingsButton.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Rules")
        settingsButton.imagePosition = .imageLeading

        let actionsStack = NSStackView(views: [blockElementButton, settingsButton])
        actionsStack.orientation = .vertical
        actionsStack.alignment = .leading
        actionsStack.spacing = 6
        actionsStack.translatesAutoresizingMaskIntoConstraints = false

        // Divider
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        // Main layout stack
        let mainStack = NSStackView(views: [
            headerStack,
            toggleRow,
            reloadButton,
            divider,
            statsBox,
            actionsStack
        ])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 12
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(mainStack)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 310),
            mainStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            mainStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            mainStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            mainStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            headerStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            toggleRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            reloadButton.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            divider.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            statsBox.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            actionsStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            blockElementButton.widthAnchor.constraint(equalTo: actionsStack.widthAnchor),
            settingsButton.widthAnchor.constraint(equalTo: actionsStack.widthAnchor),

            statsStack.topAnchor.constraint(equalTo: statsBox.topAnchor, constant: 8),
            statsStack.leadingAnchor.constraint(equalTo: statsBox.leadingAnchor, constant: 10),
            statsStack.trailingAnchor.constraint(equalTo: statsBox.trailingAnchor, constant: -10),
            statsStack.bottomAnchor.constraint(equalTo: statsBox.bottomAnchor, constant: -8)
        ])

        updateState(isBlocked: isBlocked)
    }

    private func updateState(isBlocked: Bool) {
        if isBlocked {
            shieldImageView.image = NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: "Protected")
            shieldImageView.contentTintColor = .systemGreen
            subtitleLabel.stringValue = "Protection is active on this site"
        } else {
            shieldImageView.image = NSImage(systemSymbolName: "shield.slash.fill", accessibilityDescription: "Protection Paused")
            shieldImageView.contentTintColor = .secondaryLabelColor
            subtitleLabel.stringValue = "Protection is paused on this site"
        }
    }

    @objc private func toggleChanged() {
        let isNowBlocked = toggleSwitch.state == .on
        SiteSettings.shared.update {
            $0.set(isNowBlocked ? "on" : "off", for: host, in: .contentBlockers)
        }
        if let controller = webView?.configuration.userContentController {
            ContentBlocker.shared.applySiteChoice(for: url, to: controller)
        }
        updateState(isBlocked: isNowBlocked)
        reloadButton.isHidden = false
    }

    @objc private func reloadTapped() {
        onReload()
        dismiss(nil)
    }

    @objc private func blockElementTapped() {
        dismiss(nil)
        onBlockElement()
    }

    @objc private func settingsTapped() {
        dismiss(nil)
        onOpenSettings()
    }
}
