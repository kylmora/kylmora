import AppKit
import Foundation
import Testing
import WebKit
@testable import Kylmora

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@Suite("Keyboard-Driven Browsing & Vim Navigation (F-20)")
@MainActor
struct KeyboardNavigationTests {

    @Test("Link hints and vim navigation settings persist and post notifications")
    func testSettings() {
        let name = "test-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let settings = Settings(defaults: defaults)

        #expect(settings.linkHintsEnabled == true)
        #expect(settings.vimBindingsEnabled == false)

        let linkHintsNotified = Box(false)
        let token1 = NotificationCenter.default.addObserver(
            forName: .linkHintsSettingDidChange,
            object: nil,
            queue: .main
        ) { _ in
            linkHintsNotified.value = true
        }
        defer { NotificationCenter.default.removeObserver(token1) }

        settings.linkHintsEnabled = false
        #expect(settings.linkHintsEnabled == false)
        #expect(linkHintsNotified.value)

        let vimNotified = Box(false)
        let token2 = NotificationCenter.default.addObserver(
            forName: .vimBindingsSettingDidChange,
            object: nil,
            queue: .main
        ) { _ in
            vimNotified.value = true
        }
        defer { NotificationCenter.default.removeObserver(token2) }

        settings.vimBindingsEnabled = true
        #expect(settings.vimBindingsEnabled == true)
        #expect(vimNotified.value)
    }

    @Test("Link hints generator produces unique prefix-free characters")
    func testGenerateHints() {
        let empty = LinkHintsScript.generateHints(count: 0)
        #expect(empty.isEmpty)

        // Single character generation
        let chars = "sadf"
        let singles = LinkHintsScript.generateHints(count: 4, characters: chars)
        #expect(singles == ["s", "a", "d", "f"])

        // Two-character generation for larger lists
        let count = 12
        let doubles = LinkHintsScript.generateHints(count: count, characters: chars)
        #expect(doubles.count == 12)
        #expect(doubles[0] == "ss")
        #expect(doubles[1] == "sa")
        #expect(doubles[2] == "sd")
        #expect(doubles[3] == "sf")
        #expect(doubles[4] == "as")
        // Check all generated hints are unique
        let unique = Set(doubles)
        #expect(unique.count == count)
    }

    @Test("Link hints script incorporates target modes and DOM overlay")
    func testLinkHintsScriptContent() {
        let scriptNormal = LinkHintsScript.script(openInNewTab: false)
        #expect(scriptNormal.contains("kylmora-link-hints-root"))
        #expect(scriptNormal.contains("kylmoraLinkHints"))
        #expect(scriptNormal.contains("openInNewTab = false"))
        #expect(scriptNormal.contains("#fef08a")) // Normal yellow badge

        let scriptNewTab = LinkHintsScript.script(openInNewTab: true)
        #expect(scriptNewTab.contains("openInNewTab = true"))
        #expect(scriptNewTab.contains("#fed7aa")) // Orange / amber badge
    }

    @Test("LinkHintsCoordinator notifies on new tab message")
    func testLinkHintsCoordinator() {
        let coordinator = LinkHintsCoordinator()
        let receivedURL = Box<URL?>(nil)

        coordinator.onOpenNewTab = { url in
            receivedURL.value = url
        }

        let fakeMessage = MockScriptMessage(
            name: LinkHintsCoordinator.handlerName,
            body: ["action": "openNewTab", "url": "https://example.com/target"]
        )

        coordinator.userContentController(WKUserContentController(), didReceive: fakeMessage)
        #expect(receivedURL.value == URL(string: "https://example.com/target"))
    }

    @Test("Vim navigation script contains standard vim key mappings")
    func testVimScriptContent() {
        let script = VimNavigationScript.script
        #expect(script.contains("kylmoraVimNav"))
        #expect(script.contains("case 'j':"))
        #expect(script.contains("case 'k':"))
        #expect(script.contains("case 'h':"))
        #expect(script.contains("case 'l':"))
        #expect(script.contains("case 'd':"))
        #expect(script.contains("case 'u':"))
        #expect(script.contains("case 'g':"))
        #expect(script.contains("case 'G':"))
        #expect(script.contains("case 'r':"))
        #expect(script.contains("case 'H':"))
        #expect(script.contains("case 'L':"))
        #expect(script.contains("case 'x':"))
        #expect(script.contains("case 'X':"))
        #expect(script.contains("case 'J':"))
        #expect(script.contains("case 'K':"))
        #expect(script.contains("case 'y':"))
        #expect(script.contains("case 'f':"))
        #expect(script.contains("case 'F':"))
        #expect(script.contains("case '/':"))
        #expect(script.contains("case 'i':"))
        #expect(script.contains("isEditable"))
    }

    @Test("VimNavigationCoordinator dispatches browser actions")
    func testVimNavigationCoordinator() {
        let coordinator = VimNavigationCoordinator()
        let receivedAction = Box<String?>(nil)

        coordinator.onAction = { action, _ in
            receivedAction.value = action
        }

        let actions = ["back", "forward", "closeTab", "reopenTab", "nextTab", "prevTab", "copyUrl", "find", "linkHints"]
        for action in actions {
            let msg = MockScriptMessage(
                name: VimNavigationCoordinator.handlerName,
                body: ["action": action]
            )
            coordinator.userContentController(WKUserContentController(), didReceive: msg)
            #expect(receivedAction.value == action)
        }
    }

    @Test("CommandCatalog includes link hints and vim navigation commands")
    func testCommandCatalog() {
        let catalog = CommandCatalog.all
        let ids = catalog.map(\.id)

        #expect(ids.contains("show-link-hints"))
        #expect(ids.contains("show-link-hints-new-tab"))
        #expect(ids.contains("toggle-vim-bindings"))

        let hintsCmd = catalog.first(where: { $0.id == "show-link-hints" })
        #expect(hintsCmd?.shortcut == "⌥F")

        let hintsNewTabCmd = catalog.first(where: { $0.id == "show-link-hints-new-tab" })
        #expect(hintsNewTabCmd?.shortcut == "⌥⇧F")
    }

    @Test("ShortcutManager registers default link hints shortcuts")
    func testShortcutManagerDefaults() {
        let manager = ShortcutManager.shared
        let defs = manager.definitions
        let ids = defs.map(\.id)

        #expect(ids.contains("link-hints"))
        #expect(ids.contains("link-hints-new-tab"))

        let hintDef = defs.first(where: { $0.id == "link-hints" })
        #expect(hintDef?.category == .navigation)
        #expect(hintDef?.defaultKey == "f")
        #expect(hintDef?.defaultModifiers == [.option])

        let hintNewTabDef = defs.first(where: { $0.id == "link-hints-new-tab" })
        #expect(hintNewTabDef?.category == .navigation)
        #expect(hintNewTabDef?.defaultKey == "f")
        #expect(hintNewTabDef?.defaultModifiers == [.option, .shift])
    }
}

private final class MockScriptMessage: WKScriptMessage, @unchecked Sendable {
    private let mockName: String
    private let mockBody: Any

    init(name: String, body: Any) {
        self.mockName = name
        self.mockBody = body
        super.init()
    }

    override var name: String { mockName }
    override var body: Any { mockBody }
}
