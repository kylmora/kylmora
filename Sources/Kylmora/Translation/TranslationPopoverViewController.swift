import AppKit
import Foundation
import WebKit

/// Popover view controller for initiating, configuring, and toggling on-device page translation.
@MainActor
final class TranslationPopoverViewController: NSViewController {
    private let tab: Tab
    private let onTranslate: (String) -> Void
    private let onRestore: () -> Void

    private let titleLabel = NSTextField(labelWithString: "Translate Page")
    private let privacyBadge = NSTextField(labelWithString: "On-Device • Private & Local")
    private let sourceLabel = NSTextField(labelWithString: "Source:")
    private let sourceValueLabel = NSTextField(labelWithString: "Auto-detected")
    private let targetLabel = NSTextField(labelWithString: "Translate to:")
    private let targetPopUp = NSPopUpButton()
    private let translateButton = NSButton(title: "Translate", target: nil, action: nil)
    private let restoreButton = NSButton(title: "Show Original", target: nil, action: nil)
    private let alwaysCheckbox = NSButton(checkboxWithTitle: "Always translate this language", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    init(
        tab: Tab,
        onTranslate: @escaping (String) -> Void,
        onRestore: @escaping () -> Void
    ) {
        self.tab = tab
        self.onTranslate = onTranslate
        self.onRestore = onRestore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("TranslationPopoverViewController is created in code only")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 310, height: 240))
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root

        let icon = NSImageView(image: NSImage(systemSymbolName: "translate", accessibilityDescription: "Translate")!)
        icon.contentTintColor = .systemBlue
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28)
        ])

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)

        privacyBadge.font = .systemFont(ofSize: 10, weight: .medium)
        privacyBadge.textColor = .secondaryLabelColor

        let headerText = NSStackView(views: [titleLabel, privacyBadge])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 1

        let headerStack = NSStackView(views: [icon, headerText])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 10

        let divider = NSBox()
        divider.boxType = .separator

        // Source & Target Selectors
        let formGrid = NSGridView(views: [
            [sourceLabel, sourceValueLabel],
            [targetLabel, targetPopUp]
        ])
        formGrid.rowSpacing = 8
        formGrid.columnSpacing = 12

        sourceLabel.font = .systemFont(ofSize: 12)
        sourceLabel.textColor = .secondaryLabelColor
        sourceValueLabel.font = .systemFont(ofSize: 12, weight: .medium)

        targetLabel.font = .systemFont(ofSize: 12)
        targetLabel.textColor = .secondaryLabelColor

        targetPopUp.controlSize = .small
        targetPopUp.font = .systemFont(ofSize: 12)
        for lang in TranslationLanguages.all {
            let item = NSMenuItem(title: lang.displayTitle, action: nil, keyEquivalent: "")
            item.representedObject = lang.code
            targetPopUp.menu?.addItem(item)
        }

        // Action Buttons
        translateButton.bezelStyle = .rounded
        translateButton.keyEquivalent = "\r"
        translateButton.target = self
        translateButton.action = #selector(didPressTranslate)

        restoreButton.bezelStyle = .rounded
        restoreButton.target = self
        restoreButton.action = #selector(didPressRestore)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let buttonsStack = NSStackView(views: [restoreButton, spinner, translateButton])
        buttonsStack.orientation = .horizontal
        buttonsStack.alignment = .centerY
        buttonsStack.spacing = 8

        alwaysCheckbox.controlSize = .small
        alwaysCheckbox.font = .systemFont(ofSize: 11)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping

        let mainStack = NSStackView(views: [
            headerStack,
            divider,
            formGrid,
            alwaysCheckbox,
            statusLabel,
            buttonsStack
        ])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 10
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            mainStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            mainStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            mainStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])

        updateFromState()
    }

    private func updateFromState() {
        let state = PageTranslator.shared.state(for: tab.id)

        if let detected = state.detectedLanguage {
            sourceValueLabel.stringValue = TranslationLanguages.displayName(for: detected)
            alwaysCheckbox.title = "Always translate from \(TranslationLanguages.language(for: detected)?.englishName ?? detected)"
            alwaysCheckbox.isHidden = false
        } else {
            sourceValueLabel.stringValue = "Auto-detecting…"
            alwaysCheckbox.isHidden = true
        }

        // Select active target language
        let targetCode = state.targetLanguage
        if let index = targetPopUp.menu?.items.firstIndex(where: { ($0.representedObject as? String) == targetCode }) {
            targetPopUp.selectItem(at: index)
        }

        switch state.status {
        case .untranslated, .detecting, .available:
            translateButton.title = "Translate"
            translateButton.isEnabled = true
            restoreButton.isEnabled = false
            spinner.stopAnimation(nil)
            statusLabel.stringValue = ""

        case .translating:
            translateButton.isEnabled = false
            restoreButton.isEnabled = false
            spinner.startAnimation(nil)
            statusLabel.stringValue = "Translating on-device…"

        case .translated(_, _, let count):
            translateButton.title = "Translate Again"
            translateButton.isEnabled = true
            restoreButton.isEnabled = true
            spinner.stopAnimation(nil)
            statusLabel.stringValue = "Translated \(count) elements on-device."

        case .restored:
            translateButton.title = "Translate"
            translateButton.isEnabled = true
            restoreButton.isEnabled = false
            spinner.stopAnimation(nil)
            statusLabel.stringValue = "Original page restored."

        case .failed(let error):
            translateButton.title = "Retry"
            translateButton.isEnabled = true
            restoreButton.isEnabled = false
            spinner.stopAnimation(nil)
            statusLabel.stringValue = error
        }
    }

    @objc private func didPressTranslate() {
        guard let targetCode = targetPopUp.selectedItem?.representedObject as? String else { return }
        spinner.startAnimation(nil)
        translateButton.isEnabled = false
        onTranslate(targetCode)
    }

    @objc private func didPressRestore() {
        onRestore()
    }

    func refresh() {
        updateFromState()
    }
}
