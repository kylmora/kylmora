import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("Appearance")
@MainActor
struct AppearanceTests {
    private func makeSettings() -> Settings {
        Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
    }

    @Test("Following the system is the default")
    func defaultIsSystem() {
        #expect(makeSettings().appearance == .system)
    }

    @Test("Automatic overrides nothing; light and dark name an appearance")
    func appearanceMapping() {
        #expect(AppearancePreference.system.appearanceName == nil)
        #expect(AppearancePreference.light.appearanceName == .aqua)
        #expect(AppearancePreference.dark.appearanceName == .darkAqua)
    }

    @Test("Every choice resolves to a real appearance, except Automatic")
    func appearancesResolve() {
        #expect(AppearancePreference.system.appearance == nil)
        #expect(AppearancePreference.light.appearance != nil)
        #expect(AppearancePreference.dark.appearance != nil)
    }

    @Test("The choice is stored and read back")
    func roundTrip() {
        let settings = makeSettings()
        for preference in AppearancePreference.allCases {
            settings.appearance = preference
            #expect(settings.appearance == preference)
        }
    }

    @Test("An unknown or missing stored value falls back to Automatic")
    func tolerantDecoding() {
        #expect(AppearancePreference(storedValue: nil) == .system)
        #expect(AppearancePreference(storedValue: "") == .system)
        #expect(AppearancePreference(storedValue: "sepia") == .system)
        #expect(AppearancePreference(storedValue: "dark") == .dark)
    }

    @Test("All three are offered, in the order the menu shows them")
    func menuOrder() {
        #expect(AppearancePreference.allCases.map(\.title) == ["Automatic", "Light", "Dark"])
    }
}

@Suite("Appearance menu tags")
struct AppearanceMenuTagTests {
    @Test("Every preference round-trips through its menu tag")
    func roundTrip() {
        for preference in AppearancePreference.allCases {
            #expect(AppearancePreference.fromMenuTag(preference.menuTag) == preference)
        }
    }

    @Test("Tags start at one, so an untagged item is never mistaken for a choice")
    func zeroIsNotAChoice() {
        #expect(AppearancePreference.fromMenuTag(0) == nil)
        #expect(AppearancePreference.allCases.allSatisfy { $0.menuTag > 0 })
    }

    @Test("An out-of-range tag is refused rather than clamped")
    func outOfRange() {
        #expect(AppearancePreference.fromMenuTag(99) == nil)
        #expect(AppearancePreference.fromMenuTag(-1) == nil)
    }
}
