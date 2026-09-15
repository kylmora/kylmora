import AppKit
import Combine
import UniformTypeIdentifiers

/// The Sync pane in Settings: enables and configures cross-device sync via Apple iCloud,
/// manages manual JSON backup and restore, and provides one-click migration from Arc.
@MainActor
final class SyncSettingsViewController: NSViewController, NSTextFieldDelegate {
    private let coordinator: SyncCoordinator?
    private let settings: Settings
    private var statusSubscription: AnyCancellable?

    // Status & controls
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let syncNowButton = NSButton(title: "Sync Now", target: nil, action: nil)

    // Main enable toggle
    private let enableSyncCheckbox = NSButton(checkboxWithTitle: "Enable iCloud Sync", target: nil, action: nil)
    private let syncOpenTabsCheckbox = NSButton(checkboxWithTitle: "Sync open tabs", target: nil, action: nil)
    private let syncBookmarksCheckbox = NSButton(checkboxWithTitle: "Sync bookmarks", target: nil, action: nil)
    private let syncSiteSettingsCheckbox = NSButton(checkboxWithTitle: "Sync website settings and rules", target: nil, action: nil)
    private let syncHistoryCheckbox = NSButton(checkboxWithTitle: "Sync history (the last 2,000 visits)", target: nil, action: nil)
    private let syncPasswordsCheckbox = NSButton(checkboxWithTitle: "Sync passwords (needs a passphrase)", target: nil, action: nil)
    private let passphraseField = NSSecureTextField()

    // Folder location
    private let locationLabel = NSTextField(labelWithString: "iCloud Drive (Automatic)")
    private let chooseFolderButton = NSButton(title: "Choose Folder\u{2026}", target: nil, action: nil)
    private let resetFolderButton = NSButton(title: "Reset", target: nil, action: nil)

    // Backup & Arc Migration
    private let exportButton = NSButton(title: "Export JSON Backup\u{2026}", target: nil, action: nil)
    private let importButton = NSButton(title: "Import JSON Backup\u{2026}", target: nil, action: nil)
    private let importArcButton = NSButton(title: "Import Arc Sidebar\u{2026}", target: nil, action: nil)

    // iPhone & iPad Companion (F-35)
    private let enableInboxCheckbox = NSButton(checkboxWithTitle: "Monitor iCloud Inbox for links from iPhone & iPad", target: nil, action: nil)
    private let inboxDefaultSpacePopUp = NSPopUpButton()
    private let inboxTargetModePopUp = NSPopUpButton()
    private let inboxNotifyCheckbox = NSButton(checkboxWithTitle: "Show notification when a link is received from iPhone", target: nil, action: nil)
    private let inboxAutoCreateSpaceCheckbox = NSButton(checkboxWithTitle: "Automatically create 'Read Later' space if missing", target: nil, action: nil)
    private let revealInboxButton = NSButton(title: "Reveal iCloud Inbox in Finder", target: nil, action: nil)
    private let exportShortcutButton = NSButton(title: "Export Apple Shortcut\u{2026}", target: nil, action: nil)

    init(coordinator: SyncCoordinator?, settings: Settings = .shared) {
        self.coordinator = coordinator
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("SyncSettingsViewController is created in code only")
    }

    override func loadView() {
        let form = SettingsForm()
        view = form
        buildLayout(in: form)
        reload()
        // Live status: background syncs change the coordinator's status while
        // the pane is open; reflect them without waiting for a revisit.
        statusSubscription = coordinator?.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.statusLabel.stringValue = status.title
            }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    private func buildLayout(in form: SettingsForm) {
        // 1. Status and Sync Now
        syncNowButton.target = self
        syncNowButton.action = #selector(syncNowClicked)
        syncNowButton.bezelStyle = .rounded
        statusLabel.textColor = .secondaryLabelColor

        let statusStack = NSStackView(views: [statusLabel, syncNowButton])
        statusStack.orientation = .horizontal
        statusStack.spacing = 12
        statusStack.alignment = .centerY
        form.addRow("Status", statusStack)

        form.addSeparator()

        // 2. Enable Sync Switch
        enableSyncCheckbox.target = self
        enableSyncCheckbox.action = #selector(enableSyncChanged)
        form.addRow("iCloud Sync", enableSyncCheckbox)
        form.addNote("Synchronizes your spaces, folders, pinned essentials, and bookmarks across Macs using your personal Apple iCloud account.")

        // 3. Sync Content Choices
        syncOpenTabsCheckbox.target = self
        syncOpenTabsCheckbox.action = #selector(syncOpenTabsChanged)
        form.addContinuation(syncOpenTabsCheckbox)

        syncBookmarksCheckbox.target = self
        syncBookmarksCheckbox.action = #selector(syncBookmarksChanged)
        form.addContinuation(syncBookmarksCheckbox)

        syncSiteSettingsCheckbox.target = self
        syncSiteSettingsCheckbox.action = #selector(syncSiteSettingsChanged)
        form.addContinuation(syncSiteSettingsCheckbox)

        syncHistoryCheckbox.target = self
        syncHistoryCheckbox.action = #selector(syncHistoryChanged)
        form.addContinuation(syncHistoryCheckbox)

        syncPasswordsCheckbox.target = self
        syncPasswordsCheckbox.action = #selector(syncPasswordsChanged)
        form.addContinuation(syncPasswordsCheckbox)

        passphraseField.placeholderString = "Passphrase every device shares"
        passphraseField.target = self
        passphraseField.action = #selector(passphraseChanged)
        passphraseField.delegate = self
        form.addRow("Encryption passphrase", SettingsForm.fill(passphraseField))
        form.addNote("With a passphrase, the archive is encrypted end to end before it leaves this Mac. Passwords are only ever included in an encrypted archive, and never in CloudKit; the other Macs need the same passphrase to read it.")

        form.addSeparator()

        // 4. File Location Row
        chooseFolderButton.target = self
        chooseFolderButton.action = #selector(chooseFolderClicked)
        chooseFolderButton.bezelStyle = .rounded

        resetFolderButton.target = self
        resetFolderButton.action = #selector(resetFolderClicked)
        resetFolderButton.bezelStyle = .rounded

        locationLabel.lineBreakMode = .byTruncatingMiddle
        locationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let folderStack = NSStackView(views: [locationLabel, chooseFolderButton, resetFolderButton])
        folderStack.orientation = .horizontal
        folderStack.spacing = 8
        folderStack.alignment = .centerY
        form.addRow("Sync Location", folderStack)
        form.addNote("Uses your personal iCloud Drive container. You can also choose a custom folder if desired.")

        form.addSeparator()

        // 5. Backup & Arc Migration (F-12)
        exportButton.target = self
        exportButton.action = #selector(exportBackupClicked)
        exportButton.bezelStyle = .rounded

        importButton.target = self
        importButton.action = #selector(importBackupClicked)
        importButton.bezelStyle = .rounded

        importArcButton.target = self
        importArcButton.action = #selector(importArcClicked)
        importArcButton.bezelStyle = .rounded

        let backupStack = NSStackView(views: [exportButton, importButton, importArcButton])
        backupStack.orientation = .horizontal
        backupStack.spacing = 8
        backupStack.alignment = .centerY
        form.addRow("Backup & Migration", backupStack)
        form.addNote("Export or restore the entire sidebar as a standalone JSON file, or migrate Spaces and pins directly from Arc's StorableSidebar.json.")

        form.addSeparator()

        // 6. iPhone Companion (F-35)
        enableInboxCheckbox.target = self
        enableInboxCheckbox.action = #selector(enableInboxChanged)
        form.addRow("iPhone Companion", enableInboxCheckbox)
        form.addNote("Send links from Safari, Twitter, Reddit, or any iOS app via the Share Sheet directly into a chosen Space in Kylmora.")

        inboxDefaultSpacePopUp.target = self
        inboxDefaultSpacePopUp.action = #selector(inboxDefaultSpaceChanged)
        form.addRow("Default Space", inboxDefaultSpacePopUp)

        inboxTargetModePopUp.target = self
        inboxTargetModePopUp.action = #selector(inboxTargetModeChanged)
        form.addRow("Open Links As", inboxTargetModePopUp)

        inboxNotifyCheckbox.target = self
        inboxNotifyCheckbox.action = #selector(inboxNotifyChanged)
        form.addContinuation(inboxNotifyCheckbox)

        inboxAutoCreateSpaceCheckbox.target = self
        inboxAutoCreateSpaceCheckbox.action = #selector(inboxAutoCreateSpaceChanged)
        form.addContinuation(inboxAutoCreateSpaceCheckbox)

        revealInboxButton.target = self
        revealInboxButton.action = #selector(revealInboxClicked)
        revealInboxButton.bezelStyle = .rounded

        exportShortcutButton.target = self
        exportShortcutButton.action = #selector(exportShortcutClicked)
        exportShortcutButton.bezelStyle = .rounded

        let companionStack = NSStackView(views: [revealInboxButton, exportShortcutButton])
        companionStack.orientation = .horizontal
        companionStack.spacing = 8
        companionStack.alignment = .centerY
        form.addRow("iOS Setup", companionStack)
        form.addNote("Exports the official 'Send to Kylmora' Apple Shortcut and setup guide to your iCloud Drive folder.")

        form.addSeparator()

        // 7. Privacy Note
        form.addNote("Zero-account architecture: all sync data is transmitted securely through your private Apple iCloud account with no external servers.")
    }

    private func reload() {
        let enabled = settings.syncEnabled
        enableSyncCheckbox.state = enabled ? .on : .off
        syncOpenTabsCheckbox.state = settings.syncOpenTabs ? .on : .off
        syncBookmarksCheckbox.state = settings.syncBookmarks ? .on : .off
        syncSiteSettingsCheckbox.state = settings.syncSiteSettings ? .on : .off
        syncHistoryCheckbox.state = settings.syncHistory ? .on : .off
        syncPasswordsCheckbox.state = settings.syncPasswords ? .on : .off
        if passphraseField.stringValue != settings.syncPassphrase { passphraseField.stringValue = settings.syncPassphrase }

        syncOpenTabsCheckbox.isEnabled = enabled
        syncBookmarksCheckbox.isEnabled = enabled
        syncSiteSettingsCheckbox.isEnabled = enabled
        syncHistoryCheckbox.isEnabled = enabled
        syncPasswordsCheckbox.isEnabled = enabled && !settings.syncPassphrase.isEmpty
        passphraseField.isEnabled = enabled
        syncNowButton.isEnabled = enabled

        if !settings.syncCustomDirectory.isEmpty {
            locationLabel.stringValue = (settings.syncCustomDirectory as NSString).lastPathComponent
            resetFolderButton.isHidden = false
        } else {
            locationLabel.stringValue = "iCloud Drive (Automatic)"
            resetFolderButton.isHidden = true
        }

        if let coordinator {
            statusLabel.stringValue = coordinator.status.title
        } else if !enabled {
            statusLabel.stringValue = "Sync Disabled"
        } else {
            statusLabel.stringValue = "Ready"
        }

        // iPhone Companion (F-35)
        let inboxEnabled = settings.iCloudInboxEnabled
        enableInboxCheckbox.state = inboxEnabled ? .on : .off
        inboxNotifyCheckbox.state = settings.iCloudInboxNotify ? .on : .off
        inboxAutoCreateSpaceCheckbox.state = settings.iCloudInboxAutoCreateSpace ? .on : .off

        inboxDefaultSpacePopUp.isEnabled = inboxEnabled
        inboxTargetModePopUp.isEnabled = inboxEnabled
        inboxNotifyCheckbox.isEnabled = inboxEnabled
        inboxAutoCreateSpaceCheckbox.isEnabled = inboxEnabled

        inboxDefaultSpacePopUp.removeAllItems()
        inboxDefaultSpacePopUp.addItem(withTitle: "Read Later")
        if let session = coordinator?.session {
            for space in session.spaces where space.name != "Read Later" {
                inboxDefaultSpacePopUp.addItem(withTitle: space.name)
            }
        }
        inboxDefaultSpacePopUp.selectItem(withTitle: settings.iCloudInboxDefaultSpace)
        if inboxDefaultSpacePopUp.selectedItem == nil {
            inboxDefaultSpacePopUp.selectItem(withTitle: "Read Later")
        }

        inboxTargetModePopUp.removeAllItems()
        inboxTargetModePopUp.addItem(withTitle: "New Tab")
        inboxTargetModePopUp.addItem(withTitle: "Pinned Tile")
        inboxTargetModePopUp.addItem(withTitle: "Little Arc Window")
        switch settings.iCloudInboxTargetMode {
        case "pinned": inboxTargetModePopUp.selectItem(withTitle: "Pinned Tile")
        case "littleArc": inboxTargetModePopUp.selectItem(withTitle: "Little Arc Window")
        default: inboxTargetModePopUp.selectItem(withTitle: "New Tab")
        }
    }

    @objc private func enableSyncChanged() {
        settings.syncEnabled = enableSyncCheckbox.state == .on
        settings.syncService = .iCloud
        coordinator?.updateStatusFromSettings()
        reload()
        if settings.syncEnabled {
            Task { [weak self] in
                try? await self?.coordinator?.syncNow()
                self?.reload()
            }
        }
    }

    @objc private func syncOpenTabsChanged() {
        settings.syncOpenTabs = syncOpenTabsCheckbox.state == .on
    }

    @objc private func syncBookmarksChanged() {
        settings.syncBookmarks = syncBookmarksCheckbox.state == .on
    }

    @objc private func syncSiteSettingsChanged() {
        settings.syncSiteSettings = syncSiteSettingsCheckbox.state == .on
    }

    @objc private func syncHistoryChanged() {
        settings.syncHistory = syncHistoryCheckbox.state == .on
    }

    @objc private func syncPasswordsChanged() {
        settings.syncPasswords = syncPasswordsCheckbox.state == .on
    }

    @objc private func passphraseChanged() {
        settings.syncPassphrase = passphraseField.stringValue
        syncPasswordsCheckbox.isEnabled = enableSyncCheckbox.state == .on && !settings.syncPassphrase.isEmpty
        if settings.syncPassphrase.isEmpty {
            syncPasswordsCheckbox.state = .off
            settings.syncPasswords = false
        }
    }

    @objc private func syncNowClicked() {
        syncNowButton.isEnabled = false
        statusLabel.stringValue = "Syncing…"
        settings.syncService = .iCloud
        Task { [weak self] in
            do {
                try await self?.coordinator?.syncNow()
            } catch {
                self?.statusLabel.stringValue = "Error: \(error.localizedDescription)"
            }
            self?.reload()
        }
    }

    @objc private func chooseFolderClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select a folder for Kylmora cross-device sync"
        if panel.runModal() == .OK, let url = panel.url {
            settings.syncCustomDirectory = url.path(percentEncoded: false)
            coordinator?.updateSyncDirectory()
            reload()
        }
    }

    @objc private func resetFolderClicked() {
        settings.syncCustomDirectory = ""
        coordinator?.updateSyncDirectory()
        reload()
    }

    @objc private func exportBackupClicked() {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.title = "Export Kylmora Backup"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        panel.nameFieldStringValue = "Kylmora-Backup-\(formatter.string(from: .now)).json"
        panel.allowedContentTypes = [.json]

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let coordinator = self?.coordinator else { return }
            Task { @MainActor in
                do {
                    try await coordinator.exportBackup(to: url)
                } catch {
                    let alert = NSAlert(error: error)
                    _ = await alert.beginSheetModal(for: window)
                }
            }
        }
    }

    @objc private func importBackupClicked() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Kylmora Backup"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let coordinator = self?.coordinator else { return }
            let alert = NSAlert()
            alert.messageText = "Import Backup"
            alert.informativeText = "Do you want to merge this backup with your existing spaces and tabs, or replace everything?"
            alert.addButton(withTitle: "Merge")
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")

            alert.beginSheetModal(for: window) { button in
                let mode: SyncMergePolicy.MergeMode
                switch button {
                case .alertFirstButtonReturn: mode = .merge
                case .alertSecondButtonReturn: mode = .replace
                default: return
                }

                Task { @MainActor in
                    do {
                        try await coordinator.importBackup(from: url, mode: mode)
                    } catch {
                        let errorAlert = NSAlert(error: error)
                        _ = await errorAlert.beginSheetModal(for: window)
                    }
                }
            }
        }
    }

    @objc private func importArcClicked() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Arc Sidebar (StorableSidebar.json)"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        let defaultArcDir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Arc", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: defaultArcDir.path(percentEncoded: false)) {
            panel.directoryURL = defaultArcDir
        }

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let coordinator = self?.coordinator else { return }
            Task { @MainActor in
                do {
                    try await coordinator.importArcSidebar(from: url)
                } catch {
                    let errorAlert = NSAlert(error: error)
                    _ = await errorAlert.beginSheetModal(for: window)
                }
            }
        }
    }

    // MARK: - iPhone Companion Actions (F-35)

    @objc private func enableInboxChanged() {
        settings.iCloudInboxEnabled = enableInboxCheckbox.state == .on
        reload()
    }

    @objc private func inboxDefaultSpaceChanged() {
        if let title = inboxDefaultSpacePopUp.titleOfSelectedItem {
            settings.iCloudInboxDefaultSpace = title
        }
    }

    @objc private func inboxTargetModeChanged() {
        switch inboxTargetModePopUp.indexOfSelectedItem {
        case 1: settings.iCloudInboxTargetMode = "pinned"
        case 2: settings.iCloudInboxTargetMode = "littleArc"
        default: settings.iCloudInboxTargetMode = "tab"
        }
    }

    @objc private func inboxNotifyChanged() {
        settings.iCloudInboxNotify = inboxNotifyCheckbox.state == .on
    }

    @objc private func inboxAutoCreateSpaceChanged() {
        settings.iCloudInboxAutoCreateSpace = inboxAutoCreateSpaceCheckbox.state == .on
    }

    @objc private func revealInboxClicked() {
        ICloudInboxCoordinator.shared.revealInboxInFinder()
    }

    @objc private func exportShortcutClicked() {
        let savePanel = NSSavePanel()
        savePanel.title = "Export Apple Shortcut for iPhone / iPad"
        savePanel.nameFieldStringValue = "Send to Kylmora.shortcut"
        savePanel.prompt = "Export"

        savePanel.beginSheetModal(for: view.window ?? NSApp.mainWindow ?? NSWindow()) { response in
            guard response == .OK, let destination = savePanel.url else { return }
            do {
                let parent = destination.deletingLastPathComponent()
                try AppleShortcutHelper.exportShortcutBundle(to: parent)
                let alert = NSAlert()
                alert.messageText = "Shortcut Exported"
                alert.informativeText = "Exported 'Send to Kylmora.shortcut' and setup instructions to \(parent.path()). Open this file on your iPhone or iPad to add it to your Shortcuts app!"
                alert.addButton(withTitle: "OK")
                alert.runModal()
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }
}

extension SyncSettingsViewController {
    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === passphraseField else { return }
        passphraseChanged()
    }
}
