import AppKit
import UniformTypeIdentifiers

/// The Sync pane in Settings: enables and configures cross-device sync via Apple iCloud,
/// manages manual JSON backup and restore, and provides one-click migration from Arc.
@MainActor
final class SyncSettingsViewController: NSViewController {
    private let coordinator: SyncCoordinator?
    private let settings: Settings

    // Status & controls
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let syncNowButton = NSButton(title: "Sync Now", target: nil, action: nil)

    // Main enable toggle
    private let enableSyncCheckbox = NSButton(checkboxWithTitle: "Enable iCloud Sync", target: nil, action: nil)
    private let syncOpenTabsCheckbox = NSButton(checkboxWithTitle: "Sync open tabs", target: nil, action: nil)
    private let syncBookmarksCheckbox = NSButton(checkboxWithTitle: "Sync bookmarks", target: nil, action: nil)
    private let syncSiteSettingsCheckbox = NSButton(checkboxWithTitle: "Sync website settings and rules", target: nil, action: nil)

    // Folder location
    private let locationLabel = NSTextField(labelWithString: "iCloud Drive (Automatic)")
    private let chooseFolderButton = NSButton(title: "Choose Folder\u{2026}", target: nil, action: nil)
    private let resetFolderButton = NSButton(title: "Reset", target: nil, action: nil)

    // Backup & Arc Migration
    private let exportButton = NSButton(title: "Export JSON Backup\u{2026}", target: nil, action: nil)
    private let importButton = NSButton(title: "Import JSON Backup\u{2026}", target: nil, action: nil)
    private let importArcButton = NSButton(title: "Import Arc Sidebar\u{2026}", target: nil, action: nil)

    init(coordinator: SyncCoordinator?, settings: Settings = .shared) {
        self.coordinator = coordinator
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("SyncSettingsViewController is created in code only")
    }

    override func loadView() {
        // Enforce iCloud as the active sync service
        if settings.syncService != .iCloud {
            settings.syncService = .iCloud
            coordinator?.reloadProviders()
        }

        let form = SettingsForm()
        view = form
        buildLayout(in: form)
        reload()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if settings.syncService != .iCloud {
            settings.syncService = .iCloud
            coordinator?.reloadProviders()
        }
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

        // 6. Privacy Note
        form.addNote("Zero-account architecture: all sync data is transmitted securely through your private Apple iCloud account with no external servers.")
    }

    private func reload() {
        let enabled = settings.syncEnabled
        enableSyncCheckbox.state = enabled ? .on : .off
        syncOpenTabsCheckbox.state = settings.syncOpenTabs ? .on : .off
        syncBookmarksCheckbox.state = settings.syncBookmarks ? .on : .off
        syncSiteSettingsCheckbox.state = settings.syncSiteSettings ? .on : .off

        syncOpenTabsCheckbox.isEnabled = enabled
        syncBookmarksCheckbox.isEnabled = enabled
        syncSiteSettingsCheckbox.isEnabled = enabled
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
}
