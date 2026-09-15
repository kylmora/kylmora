import AppKit
import Foundation
import LocalAuthentication
import Security
import WebKit

/// A person, as forms ask for one: name, contact and address.
struct AutofillIdentity: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var label: String
    var givenName: String
    var familyName: String
    var email: String
    var phone: String
    var organization: String
    var street: String
    var street2: String
    var city: String
    var state: String
    var postalCode: String
    var country: String

    init(id: UUID = UUID(), label: String = "", givenName: String = "", familyName: String = "", email: String = "",
         phone: String = "", organization: String = "", street: String = "", street2: String = "", city: String = "",
         state: String = "", postalCode: String = "", country: String = "") {
        self.id = id
        self.label = label
        self.givenName = givenName
        self.familyName = familyName
        self.email = email
        self.phone = phone
        self.organization = organization
        self.street = street
        self.street2 = street2
        self.city = city
        self.state = state
        self.postalCode = postalCode
        self.country = country
    }

    var fullName: String { [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ") }
    var displayName: String { label.isEmpty ? (fullName.isEmpty ? email : fullName) : label }
    var isEmpty: Bool { fullName.isEmpty && email.isEmpty && phone.isEmpty && street.isEmpty }

    /// The values the page script fills, keyed by the autocomplete token.
    var fields: [String: String] {
        [
            "name": fullName, "given-name": givenName, "family-name": familyName,
            "email": email, "tel": phone, "organization": organization,
            "street-address": [street, street2].filter { !$0.isEmpty }.joined(separator: ", "),
            "address-line1": street, "address-line2": street2,
            "address-level2": city, "address-level1": state,
            "postal-code": postalCode, "country": country
        ].filter { !$0.value.isEmpty }
    }
}

/// A payment card. The number lives in the Keychain; this is what the list
/// shows. The security code is never stored anywhere.
struct AutofillCard: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var label: String
    var holder: String
    var last4: String
    var brand: String
    var expiryMonth: Int
    var expiryYear: Int

    init(id: UUID = UUID(), label: String = "", holder: String, last4: String, brand: String, expiryMonth: Int, expiryYear: Int) {
        self.id = id
        self.label = label
        self.holder = holder
        self.last4 = last4
        self.brand = brand
        self.expiryMonth = expiryMonth
        self.expiryYear = expiryYear
    }

    var masked: String { "\(brand) •••• \(last4)" }
    var expiry: String { String(format: "%02d/%02d", expiryMonth, expiryYear % 100) }
    var displayName: String { label.isEmpty ? masked : "\(label) (\(masked))" }

    /// Digits only, so "4242 4242 4242 4242" and "4242-4242-…" are the same card.
    static func digits(of number: String) -> String { number.filter(\.isNumber) }

    /// The Luhn check every real card number passes.
    static func isPlausibleNumber(_ number: String) -> Bool {
        let digits = digits(of: number).compactMap { Int(String($0)) }
        guard digits.count >= 12, digits.count <= 19 else { return false }
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    static func brand(of number: String) -> String {
        let digits = digits(of: number)
        if digits.hasPrefix("4") { return "Visa" }
        if digits.hasPrefix("34") || digits.hasPrefix("37") { return "American Express" }
        if let two = Int(digits.prefix(2)), (51...55).contains(two) { return "Mastercard" }
        if let four = Int(digits.prefix(4)), (2221...2720).contains(four) { return "Mastercard" }
        if digits.hasPrefix("6011") || digits.hasPrefix("65") { return "Discover" }
        if digits.hasPrefix("35") { return "JCB" }
        return "Card"
    }
}

/// Card numbers, in the login Keychain as generic passwords under Kylmora's
/// own service, one per card.
enum KeychainCardStore {
    static let service = "Kylmora Payment Card"

    private static func query(id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
    }

    @discardableResult
    static func save(number: String, for id: UUID) -> Bool {
        let data = Data(AutofillCard.digits(of: number).utf8)
        let update = SecItemUpdate(query(id: id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var attributes = query(id: id)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = KeychainPasswordStore.label
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func number(for id: UUID) -> String? {
        var query = query(id: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(id: UUID) -> Bool {
        SecItemDelete(query(id: id) as CFDictionary) == errSecSuccess
    }
}

/// Identities and card details, as one JSON file in Application Support.
/// Numbers are not in it; see `KeychainCardStore`.
@MainActor
final class AutofillStore {
    static let shared = AutofillStore()

    struct Contents: Codable, Equatable {
        var identities: [AutofillIdentity] = []
        var cards: [AutofillCard] = []
    }

    private(set) var contents: Contents
    private let fileURL: URL
    var onChange: (() -> Void)?

    init(fileURL: URL = AppPaths.supportDirectory.appending(path: "autofill.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let loaded = try? JSONDecoder().decode(Contents.self, from: data) {
            contents = loaded
        } else {
            contents = Contents()
        }
    }

    var identities: [AutofillIdentity] { contents.identities }
    var cards: [AutofillCard] { contents.cards }

    func save(_ identity: AutofillIdentity) {
        if let index = contents.identities.firstIndex(where: { $0.id == identity.id }) {
            contents.identities[index] = identity
        } else {
            contents.identities.append(identity)
        }
        persist()
    }

    func removeIdentity(id: UUID) {
        contents.identities.removeAll { $0.id == id }
        persist()
    }

    /// Stores the card's details here and its number in the Keychain.
    /// Returns nil when the number does not look like a card number.
    @discardableResult
    func addCard(number: String, holder: String, expiryMonth: Int, expiryYear: Int, label: String = "") -> AutofillCard? {
        let digits = AutofillCard.digits(of: number)
        guard AutofillCard.isPlausibleNumber(digits), (1...12).contains(expiryMonth) else { return nil }
        let card = AutofillCard(
            label: label, holder: holder, last4: String(digits.suffix(4)),
            brand: AutofillCard.brand(of: digits), expiryMonth: expiryMonth, expiryYear: expiryYear
        )
        guard KeychainCardStore.save(number: digits, for: card.id) else { return nil }
        contents.cards.append(card)
        persist()
        return card
    }

    func removeCard(id: UUID) {
        KeychainCardStore.delete(id: id)
        contents.cards.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        AppPaths.ensureSupportDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(contents) {
            try? data.write(to: fileURL, options: .atomic)
        }
        onChange?()
    }
}

/// Fills names, addresses and cards into forms, the way `PasswordAutofill`
/// fills logins: a page script recognises the fields, asks native for the
/// values when one is focused, and fills every recognised field in that form.
/// Nothing is submitted, and the security code is never filled.
@MainActor
final class FormAutofill: NSObject {
    static let shared = FormAutofill()
    private let settings = Settings.shared
    private static let messageName = "kylmoraAutofill"
    var store: AutofillStore = .shared

    func attach(_ controller: WKUserContentController) {
        controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.messageName)
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
    }

    /// What the page gets for an identity field: the first identity's
    /// values, or nothing when autofill is off or nothing is stored.
    func identityValues() -> [String: String]? {
        guard settings.formAutofillEnabled, let identity = store.identities.first else { return nil }
        return identity.fields
    }

    /// The first card, number included, after Touch ID when that is on.
    func cardValues() async -> [String: String]? {
        guard settings.cardAutofillEnabled, let card = store.cards.first else { return nil }
        guard await authorize() else { return nil }
        guard let number = KeychainCardStore.number(for: card.id) else { return nil }
        return [
            "cc-number": number,
            "cc-name": card.holder,
            "cc-exp-month": String(format: "%02d", card.expiryMonth),
            "cc-exp-year": String(card.expiryYear),
            "cc-exp": card.expiry
        ]
    }

    private func authorize() async -> Bool {
        guard settings.passwordUsesTouchID else { return true }
        let context = LAContext()
        context.localizedFallbackTitle = "Enter Password"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "fill your saved card") { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}

extension FormAutofill: WKScriptMessageHandlerWithReply {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return (nil, nil) }
        // Cards only go to pages the user can trust the address of.
        let scheme = message.frameInfo.request.url?.scheme?.lowercased() ?? ""
        switch action {
        case "identity":
            return (identityValues(), nil)
        case "card":
            guard scheme == "https" || scheme == "file" else { return (nil, nil) }
            return (await cardValues(), nil)
        default:
            return (nil, nil)
        }
    }
}

extension FormAutofill {
    /// Runs in the page. `window.__kylmoraAutofill` carries the classifier and
    /// the filler so they can be exercised without a message handler; the
    /// wiring below it only runs inside Kylmora.
    static let script = """
    (function() {
      const RULES = [
        ['cc-number', /card.?num|cc.?num|ccnumber|cardnum|\\bpan\\b|creditcard|card_no|cardno/i],
        ['cc-csc', /cvc|cvv|csc|security.?code|card.?code/i],
        ['cc-exp-month', /exp.?month|cc.?month|expmm|exp_mm/i],
        ['cc-exp-year', /exp.?year|cc.?year|expyy|exp_yy/i],
        ['cc-exp', /\\bexp(ir)?(y|ation|es)?(.?date)?\\b|cc.?exp/i],
        ['cc-name', /card.?holder|name.?on.?card|cc.?name|holder/i],
        ['email', /e-?mail/i],
        ['tel', /phone|\\btel\\b|mobile|cell/i],
        ['name', /full.?name|your.?name|^\\s*name\\s*$/i],
        ['given-name', /first.?name|given|fname|forename/i],
        ['family-name', /last.?name|surname|family|lname/i],
        ['organization', /company|organi[sz]ation|\\borg\\b|employer/i],
        ['postal-code', /zip|postal|postcode|pincode/i],
        ['address-line2', /address2|addr2|line2|\\bapt\\b|suite|unit/i],
        ['address-line1', /address1|addr1|line1|street|address/i],
        ['address-level2', /city|town|locality/i],
        ['address-level1', /\\bstate\\b|province|region|county/i],
        ['country', /country/i],
        ['name', /^name$|full.?name|your.?name|\\bname\\b/i]
      ];
      const IDENTITY = new Set(['name','given-name','family-name','email','tel','organization','street-address','address-line1','address-line2','address-level2','address-level1','postal-code','country']);
      const CARD = new Set(['cc-number','cc-name','cc-exp','cc-exp-month','cc-exp-year']);

      function classify(el) {
        const tag = (el.tagName || '').toLowerCase();
        if (tag !== 'input' && tag !== 'select') return null;
        const type = (el.type || 'text').toLowerCase();
        if (['password','hidden','submit','button','checkbox','radio','file','image','reset','search'].indexOf(type) >= 0) return null;
        const ac = (el.getAttribute('autocomplete') || '').toLowerCase().split(/\\s+/).pop();
        if (ac && ac !== 'on' && ac !== 'off') {
          if (ac === 'street-address') return tag === 'select' ? null : 'street-address';
          if (IDENTITY.has(ac) || CARD.has(ac) || ac === 'cc-csc') return ac;
        }
        if (type === 'email') return 'email';
        if (type === 'tel') return 'tel';
        const hint = [el.name, el.id, el.placeholder, el.getAttribute('aria-label'),
          (el.labels && el.labels[0] ? el.labels[0].textContent : '')].join(' ');
        for (const rule of RULES) { if (rule[1].test(hint)) return rule[0]; }
        return null;
      }

      function setValue(el, value) {
        if (el.tagName.toLowerCase() === 'select') {
          const wanted = String(value).toLowerCase();
          for (const opt of el.options) {
            const v = (opt.value || '').toLowerCase(), t = (opt.textContent || '').trim().toLowerCase();
            if (v === wanted || t === wanted || (wanted.length > 2 && t.indexOf(wanted) === 0) || (/^\\d+$/.test(wanted) && parseInt(v, 10) === parseInt(wanted, 10))) {
              el.value = opt.value; el.dispatchEvent(new Event('change', { bubbles: true })); return true;
            }
          }
          return false;
        }
        try {
          const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
          setter.call(el, value);
        } catch (e) { el.value = value; }
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
      }

      function scope(el) { return el.form || document; }

      /// Fills every recognised, empty field in the form with `values`
      /// (autocomplete token -> text). Returns how many were filled.
      function fill(root, values) {
        let count = 0;
        const els = (root || document).querySelectorAll('input, select');
        for (const el of els) {
          const kind = classify(el);
          if (!kind || kind === 'cc-csc') continue;
          let value = values[kind];
          if (value === undefined && kind === 'street-address') value = values['address-line1'];
          if (value === undefined && kind === 'address-line1') value = values['street-address'];
          if (value === undefined && kind === 'name' && (values['given-name'] || values['family-name'])) {
            value = [values['given-name'], values['family-name']].filter(Boolean).join(' ');
          }
          if (value === undefined && kind === 'cc-exp-year' && values['cc-exp-year'] === undefined && values['cc-exp']) value = values['cc-exp'].split('/')[1];
          if (value === undefined || value === '') continue;
          if (el.tagName.toLowerCase() === 'input' && el.value && el.value.trim() !== '') continue;
          if (kind === 'cc-exp-year' && el.maxLength === 2 && String(value).length === 4) value = String(value).slice(2);
          if (setValue(el, value)) count++;
        }
        return count;
      }

      window.__kylmoraAutofill = { classify: classify, fill: fill, IDENTITY: IDENTITY, CARD: CARD };

      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kylmoraAutofill;
      if (!handler) return;

      async function fillFrom(el, kind) {
        const root = scope(el);
        const key = CARD.has(kind) ? 'card' : 'identity';
        const marker = 'kylmoraFilled' + key;
        if (root.dataset ? root.dataset[marker] : root[marker]) return;
        if (root.dataset) root.dataset[marker] = '1'; else root[marker] = true;
        try {
          const values = await handler.postMessage({ action: key });
          if (values) fill(root, values);
        } catch (e) {}
      }

      function wire() {
        for (const el of document.querySelectorAll('input, select')) {
          if (el.dataset.kylmoraAutofill) continue;
          const kind = classify(el);
          if (!kind || kind === 'cc-csc') continue;
          el.dataset.kylmoraAutofill = kind;
          el.addEventListener('focus', function() { fillFrom(el, kind); });
        }
      }

      wire();
      new MutationObserver(function() { wire(); }).observe(document.documentElement, { childList: true, subtree: true });
    })();
    """
}
