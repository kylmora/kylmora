import Foundation
import WebKit

extension Notification.Name {
    static let cookieBannerDidAutoReject = Notification.Name("cookieBannerDidAutoReject")
}

/// Automatically detects and clicks "Reject All" / "Decline" / "Necessary only"
/// buttons on cookie consent banners (CMPs) to eliminate cookie popups and protect privacy.
@MainActor
final class CookieConsentAutoReject: NSObject, WKScriptMessageHandler {
    static let shared = CookieConsentAutoReject()
    static let messageHandlerName = "cookieConsentAutoReject"

    private let settings: Settings
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()

    private(set) var totalRejectionsCount: Int = 0
    private(set) var lastRejectedCMP: String?

    init(settings: Settings = .shared) {
        self.settings = settings
        super.init()
    }

    func attach(_ controller: WKUserContentController) {
        controllers.add(controller)
        controller.removeScriptMessageHandler(forName: Self.messageHandlerName, contentWorld: .defaultClient)
        controller.add(self, contentWorld: .defaultClient, name: Self.messageHandlerName)
        apply(to: controller)
    }

    func preferencesChanged() {
        for controller in controllers.allObjects { apply(to: controller) }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageHandlerName else { return }
        totalRejectionsCount += 1
        if let dict = message.body as? [String: Any], let cmp = dict["cmp"] as? String {
            lastRejectedCMP = cmp
        }
        NotificationCenter.default.post(name: .cookieBannerDidAutoReject, object: self)
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
      var isTop = (window === window.top);
      var isConsentFrame = false;
      try {
        var loc = window.location.href.toLowerCase();
        isConsentFrame = loc.includes('consent') || loc.includes('cookie') || loc.includes('privacy') || loc.includes('cmp') || loc.includes('notice');
      } catch (e) {}
      if (!isTop && !isConsentFrame) return;

      function notifyReject(cmp, elem) {
        try {
          if (elem) elem.setAttribute('data-kylmora-cookie-rejected', 'true');
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.cookieConsentAutoReject) {
            window.webkit.messageHandlers.cookieConsentAutoReject.postMessage({ cmp: cmp });
          }
        } catch (e) {}
      }

      function findAndClickReject() {
        // 1. OneTrust CMP
        var otReject = document.getElementById('onetrust-reject-all-handler') ||
                       document.querySelector('button.onetrust-reject-all-handler') ||
                       document.querySelector('#onetrust-pc-btn-handler');
        if (otReject && otReject.offsetParent !== null) {
          otReject.click();
          notifyReject('OneTrust', otReject);
          unfreezeScroll();
          return true;
        }

        // 2. Cookiebot CMP
        var cbDecline = document.getElementById('CybotCookiebotDialogBodyButtonDecline') ||
                        document.getElementById('CybotCookiebotDialogBodyLevelButtonDecline') ||
                        document.getElementById('CybotCookiebotDialogBodyButtonNecessary') ||
                        document.querySelector('button#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowallSelection');
        if (cbDecline && cbDecline.offsetParent !== null) {
          cbDecline.click();
          notifyReject('Cookiebot', cbDecline);
          unfreezeScroll();
          return true;
        }

        // 3. Didomi CMP
        var didomiDisagree = document.getElementById('didomi-notice-disagree-button') ||
                             document.querySelector('.didomi-components-button--disagree') ||
                             document.querySelector('#didomi-consent-popup .didomi-button-highlight');
        if (didomiDisagree && didomiDisagree.offsetParent !== null) {
          didomiDisagree.click();
          notifyReject('Didomi', didomiDisagree);
          unfreezeScroll();
          return true;
        }

        // 4. TrustArc CMP
        var taReject = document.getElementById('truste-consent-required') ||
                       document.querySelector('.truste_box_overlay button.reject') ||
                       document.querySelector('#truste-consent-button') ||
                       document.querySelector('button.reject-all');
        if (taReject && taReject.offsetParent !== null) {
          taReject.click();
          notifyReject('TrustArc', taReject);
          unfreezeScroll();
          return true;
        }

        // 5. Usercentrics CMP (including recursive Shadow DOM traversal)
        function searchShadow(root) {
          if (!root) return null;
          var deny = root.querySelector('button[data-testid="uc-deny-all-button"]') ||
                     root.querySelector('button[data-testid="uc-save-button"]') ||
                     root.querySelector('button#uc-btn-deny-all') ||
                     root.querySelector('button.deny-all');
          if (deny) return deny;
          var children = root.querySelectorAll('*');
          for (var idx = 0; idx < children.length; idx++) {
            if (children[idx].shadowRoot) {
              var found = searchShadow(children[idx].shadowRoot);
              if (found) return found;
            }
          }
          return null;
        }
        var ucRoot = document.getElementById('usercentrics-root') || document.querySelector('div#usercentrics-root');
        if (ucRoot && ucRoot.shadowRoot) {
          var ucDeny = searchShadow(ucRoot.shadowRoot);
          if (ucDeny) {
            ucDeny.click();
            notifyReject('Usercentrics', ucDeny);
            unfreezeScroll();
            return true;
          }
        }

        // 6. Quantcast Choice CMP
        var qcReject = document.querySelector('.qc-cmp2-summary-buttons button[mode="secondary"]') ||
                       document.querySelector('.qc-cmp-cleanslate button[mode="secondary"]') ||
                       document.querySelector('button.qc-cmp2-button[mode="secondary"]');
        if (qcReject && qcReject.offsetParent !== null) {
          qcReject.click();
          notifyReject('Quantcast', qcReject);
          unfreezeScroll();
          return true;
        }

        // 7. Google Consent Dialog (Search, YouTube, Maps)
        var gBtn = document.querySelector('form[action*="consent.google"] button:not([jsaction*="accept"])') ||
                   document.querySelector('button[aria-label*="Reject all" i]') ||
                   document.querySelector('button[aria-label*="Alle ablehnen" i]') ||
                   document.querySelector('button[aria-label*="Tout refuser" i]');
        if (gBtn && gBtn.offsetParent !== null) {
          gBtn.click();
          notifyReject('Google Consent', gBtn);
          unfreezeScroll();
          return true;
        }

        // 8. Sourcepoint CMP
        var spBtn = document.querySelector('.sp_choice_type_REJECT_ALL') ||
                    document.querySelector('button.sp_choice_type_13') ||
                    document.querySelector('button[title="Reject All" i]') ||
                    document.querySelector('button[title="Reject" i]') ||
                    document.querySelector('button[title="Disagree" i]') ||
                    document.querySelector('.message-component button[aria-label*="reject" i]');
        if (spBtn && spBtn.offsetParent !== null) {
          spBtn.click();
          notifyReject('Sourcepoint', spBtn);
          unfreezeScroll();
          return true;
        }

        // 9. Standard Industry CMPs (Iubenda, Civic UK, Evidon, Borlabs, Complianz, Axeptio, Klaro, Osano, CookieYes, Ketch)
        var commonCmp = document.querySelector(
          '.iubenda-cs-reject-btn, #ccc-reject-settings, #_evidon-decline-button, ' +
          'button._brlbs-btn-reject, a._brlbs-btn-reject-all, button.cmplz-btn.cmplz-deny, ' +
          '.cmplz-deny, #axeptio_btn_dismiss, .klaro .cn-decline, button.cn-decline, ' +
          '.osano-cm-deny, button.osano-cm-denyAll, button.cky-btn-reject, .cky-btn-reject, ' +
          '.ketch-reject-all, button[data-ketch-action="reject-all"]'
        );
        if (commonCmp && commonCmp.offsetParent !== null) {
          commonCmp.click();
          notifyReject('Industry CMP', commonCmp);
          unfreezeScroll();
          return true;
        }

        // 10. Multi-language heuristic rejection inside consent containers
        var consentContainers = document.querySelectorAll(
          '[id*="cookie" i], [class*="cookie" i], [id*="consent" i], [class*="consent" i], [id*="gdpr" i], [class*="gdpr" i], [id*="notice" i], [role="dialog"], [aria-label*="cookie" i], [aria-label*="consent" i]'
        );
        var rejectKeywords = [
          // English
          "reject all", "decline all", "reject non-essential", "only necessary",
          "necessary only", "refuse all", "deny all", "essential only", "decline",
          "reject", "deny", "continue without accepting", "use necessary cookies only",
          // German
          "alle ablehnen", "nur notwendige", "nur essenzielle", "nicht zustimmen",
          "ablehnen", "verweigern", "alles ablehnen", "nur erforderliche",
          // French
          "tout refuser", "continuer sans accepter", "refuser tout", "refuser", "rejeter tout",
          // Spanish
          "rechazar todo", "rechazar todos", "solo necesarias", "continuar sin aceptar", "rechazar", "denegar todo",
          // Italian
          "rifiuta tutto", "rifiuta tutti", "solo necessari", "continua senza accettare", "rifiuta",
          // Dutch
          "alles weigeren", "weigeren", "alleen noodzakelijk", "alleen noodzakelijke", "weiger alle",
          // Portuguese
          "rejeitar todos", "rejeitar tudo", "apenas necessários", "rejeitar",
          // Polish
          "odrzuć wszystko", "odrzuć wszystkie", "tylko niezbędne", "odrzuć",
          // Nordic (SE/DK/NO)
          "avvisa alla", "avvisa alla kakor", "endast nödvändiga", "afvis alle", "kun nødvendige", "avvis alle"
        ];

        for (var i = 0; i < consentContainers.length; i++) {
          var container = consentContainers[i];
          if (container.offsetWidth === 0 || container.offsetHeight === 0) continue;
          var buttons = container.querySelectorAll('button, [role="button"], a.btn, input[type="button"], input[type="submit"]');
          for (var j = 0; j < buttons.length; j++) {
            var btn = buttons[j];
            var text = (btn.textContent || btn.value || btn.getAttribute('aria-label') || "").trim().toLowerCase();
            for (var k = 0; k < rejectKeywords.length; k++) {
              var kw = rejectKeywords[k];
              if (text === kw || (text.length < 40 && text.startsWith(kw))) {
                btn.click();
                notifyReject('Heuristic (' + kw + ')', btn);
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
          if (document.documentElement.style.position === 'fixed') document.documentElement.style.position = '';
          if (document.body && document.body.style.position === 'fixed') document.body.style.position = '';

          var backdrops = document.querySelectorAll('.modal-backdrop, .cmp-backdrop, .didomi-popup-backdrop, .fc-ab-root');
          for (var b = 0; b < backdrops.length; b++) {
            backdrops[b].remove();
          }
        }, 150);
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
