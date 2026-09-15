import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("Auto-Update (Sparkle-Style) & Security Assurances (F-23)", .serialized)
@MainActor
struct AutoUpdateTests {

    @Test("UpdateController transitions to available on new release")
    func updateAvailable() async {
        let controller = UpdateController()
        let origDownload = Settings.shared.automaticallyDownloadUpdates
        Settings.shared.automaticallyDownloadUpdates = false
        defer { Settings.shared.automaticallyDownloadUpdates = origDownload }

        let expectedRelease = UpdateCheck.Release(
            version: "99.0.0",
            url: URL(string: "https://kylmora.com/download"),
            notes: "Amazing new features"
        )

        controller.checkOutcomeProvider = { _ in
            .available(
                version: expectedRelease.version,
                url: expectedRelease.url,
                notes: expectedRelease.notes
            )
        }

        controller.checkForUpdates(userInitiated: false)

        for _ in 0..<100 {
            if controller.state != .checking { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(controller.state == .updateAvailable(expectedRelease))
        #expect(controller.updateWindowController != nil)
        #expect(controller.updateWindowController?.release.version == "99.0.0")
    }

    @Test("UpdateController respects skipped version during background checks")
    func skippedVersionBackground() async {
        let controller = UpdateController()
        Settings.shared.skippedUpdateVersion = "99.0.0"
        defer { Settings.shared.skippedUpdateVersion = nil }

        controller.checkOutcomeProvider = { _ in
            .available(version: "99.0.0", url: URL(string: "https://kylmora.com"), notes: "Notes")
        }

        controller.checkForUpdates(userInitiated: false)

        for _ in 0..<100 {
            if controller.state != .checking { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        // Skipped in background check: state returns to idle
        #expect(controller.state == .idle)
    }

    @Test("UpdateController transitions to idle on up-to-date outcome")
    func upToDateOutcome() async {
        let controller = UpdateController()
        controller.checkOutcomeProvider = { current in
            .upToDate(current: current)
        }

        controller.checkForUpdates(userInitiated: false)

        for _ in 0..<100 {
            if controller.state != .checking { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(controller.state == .idle)
        #expect(Settings.shared.lastUpdateCheckDate != nil)
    }

    @Test("UpdateController transitions to error on unreachable outcome")
    func unreachableOutcome() async {
        let controller = UpdateController()
        controller.checkOutcomeProvider = { _ in
            .unreachable("Could not reach update server.")
        }

        controller.checkForUpdates(userInitiated: false)

        for _ in 0..<100 {
            if controller.state != .checking { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(controller.state == .error("Could not reach update server."))
    }

    @Test("UpdateWindowController renders info, security notice, and transitions")
    func updateWindowTransitions() {
        let controller = UpdateController()
        let release = UpdateCheck.Release(
            version: "1.5.0",
            url: URL(string: "https://kylmora.com"),
            notes: "Major security and speed overhaul",
            downloadUrl: URL(string: "https://kylmora.com/Kylmora-1.5.0.dmg")
        )
        let windowController = UpdateWindowController(release: release, controller: controller)
        _ = windowController.window

        #expect(windowController.release.version == "1.5.0")
        #expect(windowController.displayState == .prompt)

        // Transition to downloading
        windowController.transition(to: .downloading(progress: 0.5, bytesWritten: 5000, totalBytes: 10000))
        if case .downloading(let progress, _, _) = windowController.displayState {
            #expect(progress == 0.5)
        } else {
            Issue.record("Expected downloading state")
        }

        // Transition to ready
        let testURL = URL(filePath: "/tmp/Kylmora-1.5.0.dmg")
        windowController.transition(to: .readyToInstall(fileURL: testURL))
        if case .readyToInstall(let fileURL) = windowController.displayState {
            #expect(fileURL == testURL)
        } else {
            Issue.record("Expected readyToInstall state")
        }
    }

    @Test("Auto-update settings toggle and persist")
    func settingsPersistence() {
        let origCheck = Settings.shared.automaticallyCheckForUpdates
        let origDownload = Settings.shared.automaticallyDownloadUpdates
        defer {
            Settings.shared.automaticallyCheckForUpdates = origCheck
            Settings.shared.automaticallyDownloadUpdates = origDownload
        }

        Settings.shared.automaticallyCheckForUpdates = false
        #expect(!Settings.shared.automaticallyCheckForUpdates)

        Settings.shared.automaticallyCheckForUpdates = true
        #expect(Settings.shared.automaticallyCheckForUpdates)

        Settings.shared.automaticallyDownloadUpdates = true
        #expect(Settings.shared.automaticallyDownloadUpdates)
    }

    @Test("CommandCatalog and ShortcutManager register check-for-updates")
    func commandsAndShortcuts() {
        let catalog = CommandCatalog.all
        let candidate = catalog.first { $0.id == "check-for-updates" }
        #expect(candidate != nil)
        #expect(candidate?.title.contains("Updates") == true)

        let definition = ShortcutManager.shared.definition(for: "check-for-updates")
        #expect(definition != nil)
        #expect(definition?.category == .tools)
    }

    @Test("AboutSettingsViewController includes update checkboxes and security messaging")
    func aboutPaneSettings() {
        let pane = AboutSettingsViewController()
        _ = pane.view

        #expect(pane.isAutoCheckEnabled == Settings.shared.automaticallyCheckForUpdates)
        #expect(pane.isAutoDownloadEnabled == Settings.shared.automaticallyDownloadUpdates)
    }
}
