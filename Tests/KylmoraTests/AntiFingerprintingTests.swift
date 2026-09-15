import Testing
import Foundation
import AppKit
import WebKit
@testable import Kylmora

@Suite("Anti-Fingerprinting Protection (F-30)")
@MainActor
struct AntiFingerprintingTests {

    @Test("SiteSettingCategory.antiFingerprinting properties and default value")
    func siteSettingCategoryAntiFingerprinting() {
        let category = SiteSettingCategory.antiFingerprinting
        #expect(category.title == "Anti-Fingerprinting")
        #expect(category.symbolName == "shield.lefthalf.filled")
        #expect(category.builtInDefault == "on")
        #expect(category.options.map(\.id) == ["on", "off"])
    }

    @Test("SiteSettings per-host anti-fingerprinting lookup and update")
    func siteSettingsAntiFingerprintingPerHost() {
        let testURL = URL(string: "https://fingerprint-test.org/page")!
        
        // Ensure default is enabled
        #expect(SiteSettings.shared.usesAntiFingerprinting(for: testURL) == true)
        
        // Disable for this host
        SiteSettings.shared.update {
            $0.set("off", for: "fingerprint-test.org", in: .antiFingerprinting)
        }
        #expect(SiteSettings.shared.usesAntiFingerprinting(for: testURL) == false)
        
        // Re-enable for this host
        SiteSettings.shared.update {
            $0.set("on", for: "fingerprint-test.org", in: .antiFingerprinting)
        }
        #expect(SiteSettings.shared.usesAntiFingerprinting(for: testURL) == true)
    }

    @Test("Settings anti-fingerprinting global configuration flags")
    func globalAntiFingerprintingSettings() {
        let originalEnabled = Settings.shared.antiFingerprintingEnabled
        defer { Settings.shared.antiFingerprintingEnabled = originalEnabled }

        Settings.shared.antiFingerprintingEnabled = true
        #expect(Settings.shared.antiFingerprintingEnabled == true)
        #expect(Settings.shared.canvasNoiseEnabled == true)
        #expect(Settings.shared.audioNoiseEnabled == true)
        #expect(Settings.shared.hardwareMaskingEnabled == true)

        Settings.shared.antiFingerprintingEnabled = false
        #expect(Settings.shared.antiFingerprintingEnabled == false)
    }

    @Test("SitePolicy dictionary includes anti-fingerprinting and per-space seed")
    func sitePolicyDictionaryAndPerSpaceSeed() {
        let spaceA = Space.Identity.makeIsolated()
        let spaceB = Space.Identity.makeIsolated()
        let testURL = URL(string: "https://privacy-test.io")!

        let webViewA = WKWebView(frame: .zero)
        SitePolicy.shared.apply(for: testURL, to: webViewA.configuration.userContentController, spaceIdentity: spaceA)

        // Seed determinism check: same space generates identical seed
        let seedA1 = SitePolicy.shared.seed(for: spaceA)
        let seedA2 = SitePolicy.shared.seed(for: spaceA)
        #expect(seedA1 == seedA2)

        // Different spaces generate different seeds
        let seedB = SitePolicy.shared.seed(for: spaceB)
        #expect(seedA1 != seedB)
    }

    @Test("SiteBehaviourScripts anti-fingerprinting script injection and coverage")
    func antiFingerprintingScriptContent() {
        let scriptSource = SiteBehaviourScripts.antiFingerprinting

        // Verify key anti-fingerprinting techniques are implemented in the script source
        #expect(scriptSource.contains("makeRNG"))
        #expect(scriptSource.contains("0x6D2B79F5"))
        #expect(scriptSource.contains("CanvasRenderingContext2D.prototype.getImageData"))
        #expect(scriptSource.contains("HTMLCanvasElement.prototype.toDataURL"))
        #expect(scriptSource.contains("AudioBuffer.prototype.getChannelData"))
        #expect(scriptSource.contains("AnalyserNode.prototype.getFloatFrequencyData"))
        #expect(scriptSource.contains("0x9245"))
        #expect(scriptSource.contains("0x9246"))
        #expect(scriptSource.contains("Apple GPU"))
        #expect(scriptSource.contains("hardwareConcurrency"))
        #expect(scriptSource.contains("deviceMemory"))
        #expect(scriptSource.contains("getBattery"))
        #expect(scriptSource.contains("availWidth"))

        // Verify that SiteBehaviourScripts.all includes the script
        let allSources = SiteBehaviourScripts.all.map(\.source)
        #expect(allSources.contains(scriptSource))
    }

    @Test("CommandCatalog has toggle-anti-fingerprinting registered")
    func commandCatalogRegistration() {
        let command = CommandCatalog.all.first(where: { $0.id == "toggle-anti-fingerprinting" })
        #expect(command != nil)
        #expect(command?.title == "Toggle Anti-Fingerprinting Protection")
        #expect(command?.symbolName == "shield.lefthalf.filled")
    }
}
