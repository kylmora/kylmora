import Testing
import AppKit
import Foundation
@testable import Kylmora

@Suite("Browser Lock with Touch ID / Master Password (F-25)")
@MainActor
struct BrowserLockTests {

    @Test("MasterPasswordStore handles setting, verifying, and removing master passwords")
    func masterPasswordStore() {
        MasterPasswordStore.testOverridePassword = "initialPassword123"
        #expect(MasterPasswordStore.hasMasterPassword() == true)
        #expect(MasterPasswordStore.verifyMasterPassword("initialPassword123") == true)
        #expect(MasterPasswordStore.verifyMasterPassword("wrongPassword") == false)

        MasterPasswordStore.setMasterPassword("newSecret456")
        #expect(MasterPasswordStore.verifyMasterPassword("newSecret456") == true)
        #expect(MasterPasswordStore.verifyMasterPassword("initialPassword123") == false)

        MasterPasswordStore.removeMasterPassword()
        #expect(MasterPasswordStore.hasMasterPassword() == false)
        #expect(MasterPasswordStore.verifyMasterPassword("newSecret456") == false)
    }

    @Test("BrowserLockManager transitions lock state and verifies master password")
    func lockManagerTransitions() {
        let manager = BrowserLockManager()
        MasterPasswordStore.testOverridePassword = "testPassword"

        #expect(manager.isLocked == false)

        manager.lock(animated: false)
        #expect(manager.isLocked == true)

        let wrongResult = manager.verifyAndUnlock(with: "badPassword")
        #expect(wrongResult == false)
        #expect(manager.isLocked == true)

        let rightResult = manager.verifyAndUnlock(with: "testPassword")
        #expect(rightResult == true)
        #expect(manager.isLocked == false)

        // Reset
        MasterPasswordStore.testOverridePassword = nil
    }

    @Test("LockOverlayView toggles subview layout based on lock method")
    func lockOverlayViews() {
        let overlay = LockOverlayView()

        overlay.applyMethod(.touchIDOrPasscode)
        // Hit test traps point
        let hit = overlay.hitTest(NSPoint(x: 10, y: 10))
        #expect(hit != nil)

        overlay.applyMethod(.masterPassword)
        #expect(overlay.subviews.count > 0)
    }

    @Test("BrowserLock settings persist and broadcast change notifications")
    func lockSettingsPersistence() {
        let settings = Settings(defaults: UserDefaults(suiteName: "test-lock-\(UUID().uuidString)")!)

        final class Receiver: @unchecked Sendable {
            var received = false
        }
        let receiver = Receiver()
        let token = NotificationCenter.default.addObserver(
            forName: .browserLockSettingsDidChange,
            object: nil,
            queue: nil
        ) { _ in
            receiver.received = true
        }

        settings.browserLockEnabled = true
        #expect(settings.browserLockEnabled == true)
        #expect(receiver.received == true)

        settings.browserLockMethod = .masterPassword
        #expect(settings.browserLockMethod == .masterPassword)

        settings.browserLockOnLaunch = false
        #expect(settings.browserLockOnLaunch == false)

        settings.browserLockIdleTimeout = .minutes15
        #expect(settings.browserLockIdleTimeout == .minutes15)

        NotificationCenter.default.removeObserver(token)
    }

    @Test("CommandCatalog and ShortcutManager register lock-browser with ⌃⌘L")
    func lockCommandCatalog() {
        let command = CommandCatalog.all.first { $0.id == "lock-browser" }
        #expect(command != nil)
        #expect(command?.shortcut == "⌃⌘L")

        let definition = ShortcutManager.shared.definitions.first { $0.id == "lock-browser" }
        #expect(definition != nil)
        #expect(definition?.defaultKey == "l")
        let expectedModifiers: NSEvent.ModifierFlags = [.command, .control]
        #expect(definition?.defaultModifiers == expectedModifiers)
    }
}
