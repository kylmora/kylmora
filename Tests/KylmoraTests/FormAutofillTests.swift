import AppKit
import Foundation
import Testing
import WebKit
@testable import Kylmora

@Suite("Form autofill")
@MainActor
struct FormAutofillTests {
    @Test("Card numbers are checked, branded and masked")
    func cards() {
        #expect(AutofillCard.isPlausibleNumber("4242 4242 4242 4242"))
        #expect(AutofillCard.isPlausibleNumber("5555-5555-5555-4444"))
        #expect(AutofillCard.isPlausibleNumber("378282246310005"))
        #expect(!AutofillCard.isPlausibleNumber("4242 4242 4242 4241"))
        #expect(!AutofillCard.isPlausibleNumber("1234"))
        #expect(AutofillCard.brand(of: "4242424242424242") == "Visa")
        #expect(AutofillCard.brand(of: "5555555555554444") == "Mastercard")
        #expect(AutofillCard.brand(of: "2221000000000009") == "Mastercard")
        #expect(AutofillCard.brand(of: "378282246310005") == "American Express")
        #expect(AutofillCard.brand(of: "6011111111111117") == "Discover")
        let card = AutofillCard(holder: "A B", last4: "4242", brand: "Visa", expiryMonth: 3, expiryYear: 2031)
        #expect(card.masked == "Visa •••• 4242")
        #expect(card.expiry == "03/31")
    }

    @Test("Identities and cards persist; numbers live only in the Keychain")
    func store() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "autofill-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = AutofillStore(fileURL: file)
        #expect(store.identities.isEmpty)

        let me = AutofillIdentity(label: "Home", givenName: "Ada", familyName: "Lovelace", email: "ada@example.org",
                                  phone: "+44 20 7946 0000", street: "1 Analytical Way", city: "London", postalCode: "N1 1AA", country: "United Kingdom")
        store.save(me)
        #expect(store.identities.count == 1)
        #expect(me.fields["name"] == "Ada Lovelace")
        #expect(me.fields["street-address"] == "1 Analytical Way")
        #expect(me.fields["organization"] == nil, "empty values are not offered")

        #expect(store.addCard(number: "1234", holder: "Ada", expiryMonth: 1, expiryYear: 2030) == nil)
        let card = try #require(store.addCard(number: "4242 4242 4242 4242", holder: "Ada Lovelace", expiryMonth: 12, expiryYear: 2030))
        defer { store.removeCard(id: card.id) }
        #expect(card.last4 == "4242")
        #expect(card.brand == "Visa")
        #expect(KeychainCardStore.number(for: card.id) == "4242424242424242")

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("4242424242424242"), "the number is not in the file")
        #expect(text.contains("\"last4\" : \"4242\""))

        let reloaded = AutofillStore(fileURL: file)
        #expect(reloaded.identities == [me])
        #expect(reloaded.cards == [card])
        reloaded.removeCard(id: card.id)
        #expect(KeychainCardStore.number(for: card.id) == nil)
        reloaded.removeIdentity(id: me.id)
        #expect(AutofillStore(fileURL: file).identities.isEmpty)
    }

    @Test("The page script recognises fields and fills a form, never the security code")
    func script() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let webView = WKWebView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(webView)
        webView.loadHTMLString("""
        <html><body>
        <form id="f">
          <input id="fn" name="first_name"><input id="ln" placeholder="Last name">
          <input id="em" type="email" name="x"><input id="ph" type="tel">
          <input id="st" name="address1"><input id="ci" name="city"><input id="zip" name="postcode">
          <select id="co" name="country"><option value="">Pick</option><option value="GB">United Kingdom</option><option value="US">United States</option></select>
          <input id="cc" autocomplete="cc-number"><input id="ch" name="cardholder">
          <select id="mm" name="exp_month"><option>01</option><option>12</option></select>
          <input id="yy" name="exp_year" maxlength="2"><input id="cvc" name="cvv">
          <input id="pw" type="password"><input id="q" type="search" name="name">
          <input id="already" name="fullname" value="Keep Me">
        </form></body></html>
        """, baseURL: nil)
        for _ in 0..<200 where webView.isLoading { try await Task.sleep(for: .milliseconds(25)) }
        _ = try await webView.evaluateJavaScript(FormAutofill.script)

        let kinds = try await webView.evaluateJavaScript("""
        (function(){ const out = {}; for (const el of document.querySelectorAll('#f input, #f select')) { out[el.id] = __kylmoraAutofill.classify(el); } return JSON.stringify(out); })()
        """) as? String
        let classified = try JSONSerialization.jsonObject(with: Data((kinds ?? "{}").utf8)) as? [String: Any] ?? [:]
        #expect(classified["fn"] as? String == "given-name")
        #expect(classified["ln"] as? String == "family-name")
        #expect(classified["em"] as? String == "email")
        #expect(classified["ph"] as? String == "tel")
        #expect(classified["st"] as? String == "address-line1")
        #expect(classified["ci"] as? String == "address-level2")
        #expect(classified["zip"] as? String == "postal-code")
        #expect(classified["co"] as? String == "country")
        #expect(classified["cc"] as? String == "cc-number")
        #expect(classified["ch"] as? String == "cc-name")
        #expect(classified["mm"] as? String == "cc-exp-month")
        #expect(classified["yy"] as? String == "cc-exp-year")
        #expect(classified["cvc"] as? String == "cc-csc")
        #expect(classified["pw"] is NSNull, "passwords are another feature's")
        #expect(classified["q"] is NSNull, "a search box is not a name")
        #expect(classified["already"] as? String == "name")

        let me = AutofillIdentity(givenName: "Ada", familyName: "Lovelace", email: "ada@example.org", phone: "020", street: "1 Analytical Way", city: "London", postalCode: "N1 1AA", country: "United Kingdom")
        let identityJSON = String(decoding: try JSONSerialization.data(withJSONObject: me.fields), as: UTF8.self)
        let filled = try await webView.evaluateJavaScript("__kylmoraAutofill.fill(document.getElementById('f'), \(identityJSON))") as? Int
        #expect(filled == 8)
        let values = try await webView.evaluateJavaScript("""
        (function(){ const out = {}; for (const el of document.querySelectorAll('#f input, #f select')) { out[el.id] = el.value; } return JSON.stringify(out); })()
        """) as? String
        let after = try JSONSerialization.jsonObject(with: Data((values ?? "{}").utf8)) as? [String: String] ?? [:]
        #expect(after["fn"] == "Ada")
        #expect(after["ln"] == "Lovelace")
        #expect(after["em"] == "ada@example.org")
        #expect(after["st"] == "1 Analytical Way")
        #expect(after["co"] == "GB", "a select is matched by its option text")
        #expect(after["already"] == "Keep Me", "a field with text in it is left alone")
        #expect(after["cc"] == "", "identity values never touch card fields")

        let cardJSON = """
        {"cc-number":"4242424242424242","cc-name":"Ada Lovelace","cc-exp-month":"12","cc-exp-year":"2030","cc-exp":"12/30"}
        """
        let cardFilled = try await webView.evaluateJavaScript("__kylmoraAutofill.fill(document.getElementById('f'), \(cardJSON))") as? Int
        #expect(cardFilled == 4)
        let cardValues = try await webView.evaluateJavaScript("""
        (function(){ return JSON.stringify({cc: cc.value, ch: ch.value, mm: mm.value, yy: yy.value, cvc: cvc.value}); })()
        """) as? String
        let card = try JSONSerialization.jsonObject(with: Data((cardValues ?? "{}").utf8)) as? [String: String] ?? [:]
        #expect(card["cc"] == "4242424242424242")
        #expect(card["ch"] == "Ada Lovelace")
        #expect(card["mm"] == "12")
        #expect(card["yy"] == "30", "a two-character year field gets the short year")
        #expect(card["cvc"] == "", "the security code is never filled")
    }

    @Test("Autofill answers from the store and honours its switches")
    func values() async {
        let file = FileManager.default.temporaryDirectory.appending(path: "autofill-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = AutofillStore(fileURL: file)
        let autofill = FormAutofill()
        autofill.store = store
        let settings = Settings.shared
        let wasOn = settings.formAutofillEnabled
        defer { settings.formAutofillEnabled = wasOn }
        settings.formAutofillEnabled = true
        #expect(autofill.identityValues() == nil, "nothing stored, nothing offered")
        store.save(AutofillIdentity(givenName: "Ada", email: "ada@example.org"))
        #expect(autofill.identityValues()?["email"] == "ada@example.org")
        settings.formAutofillEnabled = false
        #expect(autofill.identityValues() == nil)
        #expect(settings.cardAutofillEnabled || !settings.cardAutofillEnabled)
    }
}
