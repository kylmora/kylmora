import Foundation
import WebKit

/// Automatically detects and clicks "Reject All" / "Decline" / "Necessary only"
/// buttons on cookie consent banners (CMPs) to eliminate cookie popups.
@MainActor
final class CookieConsentAutoReject {
    static let shared = CookieConsentAutoReject()

    private let settings: Settings
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()

    init(settings: Settings = .shared) {
        self.settings = settings
    }

    func attach(_ controller: WKUserContentController) {
        controllers.add(controller)
        apply(to: controller)
    }

    func preferencesChanged() {
        for controller in controllers.allObjects { apply(to: controller) }
    }

    private func apply(to controller: WKUserContentController) {
        let others = controller.userScripts.filter { $0.source != Self.source }
        controller.removeAllUserScripts()
        for script in others { controller.addUserScript(script) }
        if settings.autoRejectCookieBanners {
            controller.addUserScript(
                WKUserScript(
                    source: Self.source,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: false,
                    in: .defaultClient
                )
            )
        }
    }

    static let source = #"""
    (function () {
      if (window !== window.top) return;

      function findAndClickReject() {
        // 1. OneTrust CMP
        var otReject = document.getElementById('onetrust-reject-all-handler') ||
                       document.querySelector('button.onetrust-reject-all-handler') ||
                       document.querySelector('#onetrust-pc-btn-handler');
        if (otReject && otReject.offsetParent !== null) {
          otReject.click();
          unfreezeScroll();
          return true;
        }

        // 2. Cookiebot CMP
        var cbDecline = document.getElementById('CybotCookiebotDialogBodyButtonDecline') ||
                        document.getElementById('CybotCookiebotDialogBodyLevelButtonDecline') ||
                        document.querySelector('button#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowallSelection');
        if (cbDecline && cbDecline.offsetParent !== null) {
          cbDecline.click();
          unfreezeScroll();
          return true;
        }

        // 3. Didomi CMP
        var didomiDisagree = document.getElementById('didomi-notice-disagree-button') ||
                             document.querySelector('.didomi-components-button--disagree') ||
                             document.querySelector('#didomi-consent-popup .didomi-button-highlight');
        if (didomiDisagree && didomiDisagree.offsetParent !== null) {
          didomiDisagree.click();
          unfreezeScroll();
          return true;
        }

        // 4. TrustArc CMP
        var taReject = document.getElementById('truste-consent-required') ||
                       document.querySelector('.truste_box_overlay button.reject') ||
                       document.querySelector('#truste-consent-button');
        if (taReject && taReject.offsetParent !== null) {
          taReject.click();
          unfreezeScroll();
          return true;
        }

        // 5. Usercentrics CMP (including Shadow DOM)
        var ucRoot = document.getElementById('usercentrics-root');
        if (ucRoot && ucRoot.shadowRoot) {
          var ucDeny = ucRoot.shadowRoot.querySelector('button[data-testid="uc-deny-all-button"]') ||
                       ucRoot.shadowRoot.querySelector('button[data-testid="uc-save-button"]');
          if (ucDeny) {
            ucDeny.click();
            unfreezeScroll();
            return true;
          }
        }

        // 6. Quantcast Choice CMP
        var qcReject = document.querySelector('.qc-cmp2-summary-buttons button[mode="secondary"]') ||
                       document.querySelector('.qc-cmp-cleanslate button[mode="secondary"]');
        if (qcReject && qcReject.offsetParent !== null) {
          qcReject.click();
          unfreezeScroll();
          return true;
        }

        // 7. Klaro / Axeptio / Complianz
        var miscReject = document.querySelector('.klaro .cn-decline, button.cn-decline, #axeptio_btn_dismiss, .cmplz-deny');
        if (miscReject && miscReject.offsetParent !== null) {
          miscReject.click();
          unfreezeScroll();
          return true;
        }

        // 8. Heuristic rejection inside typical consent containers
        var consentContainers = document.querySelectorAll(
          '[id*="cookie" i], [class*="cookie" i], [id*="consent" i], [class*="consent" i], [id*="gdpr" i], [class*="gdpr" i], [id*="notice" i]'
        );
        var rejectKeywords = [
          "reject all", "decline all", "reject non-essential", "only necessary",
          "necessary only", "refuse all", "deny all", "essential only", "decline", "reject", "deny"
        ];
        for (var i = 0; i < consentContainers.length; i++) {
          var container = consentContainers[i];
          if (container.offsetWidth === 0 || container.offsetHeight === 0) continue;
          var buttons = container.querySelectorAll('button, [role="button"], a.btn');
          for (var j = 0; j < buttons.length; j++) {
            var btn = buttons[j];
            var text = (btn.textContent || "").trim().toLowerCase();
            for (var k = 0; k < rejectKeywords.length; k++) {
              if (text === rejectKeywords[k] || (text.length < 35 && text.startsWith(rejectKeywords[k]))) {
                btn.click();
                unfreezeScroll();
                return true;
              }
            }
          }
        }
        return false;
      }

      function unfreezeScroll() {
        setTimeout(function () {
          if (document.documentElement.style.overflow === 'hidden') document.documentElement.style.overflow = '';
          if (document.body && document.body.style.overflow === 'hidden') document.body.style.overflow = '';
        }, 120);
      }

      if (findAndClickReject()) return;

      var observer = new MutationObserver(function () {
        if (findAndClickReject()) {
          observer.disconnect();
        }
      });
      observer.observe(document.body || document.documentElement, { childList: true, subtree: true });
      setTimeout(function () { observer.disconnect(); }, 6000);
    })();
    """#
}
