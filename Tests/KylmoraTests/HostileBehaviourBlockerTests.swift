import AppKit
import Foundation
import Testing
import WebKit
@testable import Kylmora

@Suite("Block Hostile Page Behaviour (F-34)")
@MainActor
struct HostileBehaviourBlockerTests {
    @Test("Hostile behaviour blocker script covers text selection, contextmenu, and clipboard shielding")
    func scriptCoverage() {
        let script = SiteBehaviourScripts.hostileBehaviourBlocker
        #expect(!script.isEmpty)

        // 1. Force selectable text
        #expect(script.contains("user-select: text !important"))
        #expect(script.contains("kylmora-anti-hostile-style"))

        // 2. Prevent right-click trapping
        #expect(script.contains("contextmenu"))
        #expect(script.contains("origPreventDefault"))

        // 3. Prevent clipboard snooping and write hijacking
        #expect(script.contains("navigator.clipboard.readText"))
        #expect(script.contains("navigator.clipboard.read"))
        #expect(script.contains("navigator.clipboard.writeText"))
        #expect(script.contains("userActivation"))

        // 4. Clean hostile attributes and dynamic observer
        #expect(script.contains("oncontextmenu"))
        #expect(script.contains("onselectstart"))
        #expect(script.contains("MutationObserver"))
    }

    @Test("SiteSettingCategory includes blockHostileBehaviour with default on")
    func siteSettingCategoryIntegration() {
        let category = SiteSettingCategory.blockHostileBehaviour
        #expect(category.builtInDefault == "on")
        #expect(category.option("on") != nil)
        #expect(category.option("off") != nil)
        #expect(!category.title.isEmpty)
        #expect(!category.instruction.isEmpty)
        #expect(SiteSettingCategory.allCases.contains(.blockHostileBehaviour))
    }

    @Test("Settings has blockHostilePageBehaviour defaulting to true and posting notification")
    func settingsToggleAndNotification() {
        let defaults = UserDefaults(suiteName: "kylmora.tests.hostile.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        #expect(settings.blockHostilePageBehaviour == true)

        var notified = false
        let observer = NotificationCenter.default.addObserver(
            forName: .blockHostilePageBehaviourDidChange,
            object: nil,
            queue: .main
        ) { _ in
            notified = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        settings.blockHostilePageBehaviour = false
        #expect(settings.blockHostilePageBehaviour == false)
        #expect(notified == true)
    }

    @Test("SitePolicy applies blockHostileBehaviour according to global and per-site settings")
    func sitePolicyResolution() {
        let file = FileManager.default.temporaryDirectory.appending(path: "kylmora-sites-\(UUID().uuidString).json")
        let siteSettings = SiteSettings(file: file)
        let policy = siteSettings.policy(for: URL(string: "https://example.com")!)
        #expect(policy["blockHostileBehaviour"] == "on")

        siteSettings.update { $0.set("off", for: "example.com", in: .blockHostileBehaviour) }
        let policyUpdated = siteSettings.policy(for: URL(string: "https://example.com")!)
        #expect(policyUpdated["blockHostileBehaviour"] == "off")
    }

    @Test("Command catalog includes toggle-block-hostile-behaviour")
    func commandCatalogEntry() {
        let commands = CommandCatalog.all
        #expect(commands.contains { $0.id == "toggle-block-hostile-behaviour" })
    }
}
