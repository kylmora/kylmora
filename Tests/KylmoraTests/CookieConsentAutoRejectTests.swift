import AppKit
import Foundation
import Testing
import WebKit
@testable import Kylmora

@Suite("Cookie Banner Auto-Reject (F-33)")
@MainActor
struct CookieConsentAutoRejectTests {
    @Test("CookieConsentAutoReject script contains comprehensive CMP coverage")
    func scriptCoverage() {
        let script = CookieConsentAutoReject.source
        #expect(!script.isEmpty)

        // Major CMP identifiers
        #expect(script.contains("onetrust"))
        #expect(script.contains("CybotCookiebot"))
        #expect(script.contains("didomi"))
        #expect(script.contains("truste"))
        #expect(script.contains("usercentrics"))
        #expect(script.contains("Quantcast") || script.contains("qc-cmp2"))
        #expect(script.contains("Google Consent") || script.contains("consent.google"))
        #expect(script.contains("Sourcepoint") || script.contains("sp_choice_type_REJECT_ALL"))
        #expect(script.contains("iubenda"))
        #expect(script.contains("cmplz"))
        #expect(script.contains("axeptio"))
        #expect(script.contains("klaro"))
        #expect(script.contains("osano"))
        #expect(script.contains("cky-btn-reject"))

        // Recursive shadow DOM traversal
        #expect(script.contains("searchShadow"))

        // Scroll unfreeze and backdrop cleanup
        #expect(script.contains("unfreezeScroll"))
        #expect(script.contains("modal-backdrop"))

        // Multi-language reject keywords
        #expect(script.contains("reject all"))
        #expect(script.contains("alle ablehnen")) // German
        #expect(script.contains("tout refuser"))  // French
        #expect(script.contains("rechazar todo")) // Spanish
        #expect(script.contains("rifiuta tutto")) // Italian
        #expect(script.contains("alles weigeren")) // Dutch
    }

    @Test("UserContentController gets script injected when enabled, removed when disabled")
    func scriptInjectionToggle() {
        let defaults = UserDefaults(suiteName: "kylmora.tests.cookie.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        let rejecter = CookieConsentAutoReject(settings: settings)
        let controller = WKUserContentController()

        settings.autoRejectCookieBanners = true
        rejecter.attach(controller)
        #expect(controller.userScripts.contains { $0.source == CookieConsentAutoReject.source })

        settings.autoRejectCookieBanners = false
        rejecter.preferencesChanged()
        #expect(!controller.userScripts.contains { $0.source == CookieConsentAutoReject.source })

        settings.autoRejectCookieBanners = true
        rejecter.preferencesChanged()
        #expect(controller.userScripts.contains { $0.source == CookieConsentAutoReject.source })
    }

    @Test("Settings has autoRejectCookieBanners defaulting to true")
    func settingsDefaultValue() {
        let defaults = UserDefaults(suiteName: "kylmora.tests.cookie.defaults.\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        #expect(settings.autoRejectCookieBanners == true)

        settings.autoRejectCookieBanners = false
        #expect(settings.autoRejectCookieBanners == false)
    }

    @Test("Message handler name is cookieConsentAutoReject and instance conforms to WKScriptMessageHandler")
    func messageHandlerRegistration() {
        #expect(CookieConsentAutoReject.messageHandlerName == "cookieConsentAutoReject")
        let rejecter = CookieConsentAutoReject.shared
        #expect(rejecter is WKScriptMessageHandler)
    }
}
