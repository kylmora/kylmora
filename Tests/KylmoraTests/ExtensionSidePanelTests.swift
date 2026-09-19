import Foundation
import JavaScriptCore
import Testing
@testable import Kylmora

/// Side panels: the manifest, the state, the API's meaning, the package the
/// shim goes into, and the shim's own JavaScript, which is run for real.
private enum Panels {
    static func makeRoot() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "kylmora.sidepanel.\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func remove(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes a real extension folder and returns it.
    @discardableResult
    static func package(_ manifest: [String: Any], files: [String: String] = [:], in root: URL) -> URL {
        let data = try! JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try? data.write(to: root.appending(path: "manifest.json"))
        for (name, contents) in files {
            try? Data(contents.utf8).write(to: root.appending(path: name))
        }
        return root
    }

    static func manifest(in root: URL) -> [String: Any] {
        let data = try! Data(contentsOf: root.appending(path: "manifest.json"))
        return (try! JSONSerialization.jsonObject(with: data)) as! [String: Any]
    }

    static func contents(_ name: String, in root: URL) -> String? {
        guard let data = try? Data(contentsOf: root.appending(path: name)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// A function rather than a constant: a dictionary of `Any` cannot be a
    /// shared global in Swift 6, and every test wants its own copy anyway.
    static func chromeManifest() -> [String: Any] {
        [
            "manifest_version": 3,
            "name": "Panelled",
            "version": "1.0",
            "permissions": ["storage"],
            "background": ["service_worker": "worker.js"],
            "side_panel": ["default_path": "panel.html"],
        ]
    }
}

@Suite("A manifest's side panel is read the way its browser reads it")
struct ExtensionSidebarDefinitionTests {
    @Test("Chrome's side_panel names the page")
    func chrome() {
        let definition = ExtensionSidebarDefinition.read(from: Panels.chromeManifest())
        #expect(definition?.path == "panel.html")
        #expect(definition?.flavour == .chrome)
        #expect(definition?.title == nil)
    }

    @Test("Firefox's sidebar_action names the page, a title and an icon")
    func firefox() {
        let definition = ExtensionSidebarDefinition.read(from: [
            "sidebar_action": [
                "default_panel": "sidebar/panel.html",
                "default_title": "My Sidebar",
                "default_icon": ["32": "icons/small.png", "64": "icons/big.png"],
            ],
        ])
        #expect(definition?.path == "sidebar/panel.html")
        #expect(definition?.title == "My Sidebar")
        #expect(definition?.flavour == .firefox)
        // Largest first: the panel header asks for one and should get the best.
        #expect(definition?.iconPaths == ["icons/big.png", "icons/small.png"])
    }

    @Test("Firefox's older default_page is read too")
    func firefoxPage() {
        let definition = ExtensionSidebarDefinition.read(from: ["sidebar_action": ["default_page": "p.html"]])
        #expect(definition?.path == "p.html")
    }

    @Test("A single icon is as good as a map")
    func singleIcon() {
        let definition = ExtensionSidebarDefinition.read(from: [
            "sidebar_action": ["default_panel": "p.html", "default_icon": "icon.png"],
        ])
        #expect(definition?.iconPaths == ["icon.png"])
    }

    @Test("A path is taken as written but never as an absolute one", arguments: [
        ("/panel.html", "panel.html"), ("./panel.html", "panel.html"), ("a/b/panel.html", "a/b/panel.html"),
        ("  panel.html  ", "panel.html"),
    ])
    func paths(_ written: String, _ expected: String) {
        let definition = ExtensionSidebarDefinition.read(from: ["side_panel": ["default_path": written]])
        #expect(definition?.path == expected)
    }

    @Test("Firefox's sidebar wins when a manifest somehow has both")
    func bothSpellings() {
        let definition = ExtensionSidebarDefinition.read(from: [
            "side_panel": ["default_path": "chrome.html"],
            "sidebar_action": ["default_panel": "firefox.html"],
        ])
        #expect(definition?.path == "firefox.html")
        #expect(definition?.flavour == .firefox)
    }

    @Test("An extension with no panel has none")
    func none() {
        #expect(ExtensionSidebarDefinition.read(from: ["name": "Plain"]) == nil)
        #expect(!ExtensionSidebarDefinition.wantsSidebarAPI(["name": "Plain"]))
        #expect(ExtensionSidebarDefinition.read(from: ["side_panel": ["default_path": ""]]) == nil)
    }

    @Test("An extension that sets its path at runtime still wants the API")
    func permissionOnly() {
        #expect(ExtensionSidebarDefinition.wantsSidebarAPI(["permissions": ["sidePanel"]]))
        #expect(ExtensionSidebarDefinition.wantsSidebarAPI(["optional_permissions": ["sidePanel"]]))
        #expect(ExtensionSidebarDefinition.read(from: ["permissions": ["sidePanel"]]) == nil)
    }
}

@Suite("What a panel is set to")
struct ExtensionSidebarStateTests {
    @Test("With nothing set, the manifest's page is the panel")
    func manifestPage() {
        let state = ExtensionSidebarState(manifestPath: "panel.html")
        #expect(state.path(forTab: nil) == "panel.html")
        #expect(state.path(forTab: 7) == "panel.html")
        #expect(state.isEnabled(forTab: 7))
    }

    @Test("A default set at runtime wins over the manifest")
    func defaultOverride() {
        var state = ExtensionSidebarState(manifestPath: "panel.html")
        state.setOptions(tabID: nil, path: "other.html", isEnabled: nil)
        #expect(state.path(forTab: nil) == "other.html")
    }

    @Test("One tab's page is that tab's alone")
    func perTab() {
        var state = ExtensionSidebarState(manifestPath: "panel.html")
        state.setOptions(tabID: 3, path: "three.html", isEnabled: nil)
        #expect(state.path(forTab: 3) == "three.html")
        #expect(state.path(forTab: 4) == "panel.html")
        #expect(state.path(forTab: nil) == "panel.html")
    }

    @Test("A panel switched off for a tab has no page there")
    func disabledTab() {
        var state = ExtensionSidebarState(manifestPath: "panel.html")
        state.setOptions(tabID: 3, path: nil, isEnabled: false)
        #expect(state.path(forTab: 3) == nil)
        #expect(state.path(forTab: 4) == "panel.html")
    }

    @Test("Switching the panel off everywhere leaves nothing to open")
    func disabledEverywhere() {
        var state = ExtensionSidebarState(manifestPath: "panel.html")
        state.setOptions(tabID: nil, path: nil, isEnabled: false)
        #expect(state.path(forTab: nil) == nil)
        #expect(state.path(forTab: 9) == nil)
    }

    @Test("An empty path means back to the manifest's")
    func emptyPathResets() {
        var state = ExtensionSidebarState(manifestPath: "panel.html")
        state.setOptions(tabID: nil, path: "other.html", isEnabled: nil)
        state.setOptions(tabID: nil, path: "", isEnabled: nil)
        #expect(state.path(forTab: nil) == "panel.html")
    }

    @Test("A tab with nothing left to say is forgotten")
    func tabsAreNotHoarded() {
        var state = ExtensionSidebarState(manifestPath: "panel.html")
        state.setOptions(tabID: 3, path: "three.html", isEnabled: nil)
        state.setOptions(tabID: 3, path: "", isEnabled: nil)
        #expect(state.perTab.isEmpty)
    }

    @Test("Firefox's null panel switches the panel off rather than resetting it")
    func firefoxNullPanel() {
        var state = ExtensionSidebarState(manifestPath: "panel.html")
        state.setPanel(tabID: nil, panel: nil)
        #expect(state.path(forTab: nil) == nil)
        state.setPanel(tabID: nil, panel: "back.html")
        #expect(state.path(forTab: nil) == "back.html")
    }

    @Test("A tab that closes takes its settings with it")
    func forgetTab() {
        var state = ExtensionSidebarState(manifestPath: "panel.html")
        state.setOptions(tabID: 3, path: "three.html", isEnabled: nil)
        state.forgetTab(3)
        #expect(state.path(forTab: 3) == "panel.html")
    }

    @Test("A title set at runtime wins over the manifest's")
    func titles() {
        var state = ExtensionSidebarState(manifestPath: "p.html", manifestTitle: "From manifest")
        #expect(state.title == "From manifest")
        state.setTitle(tabID: nil, title: "From runtime")
        #expect(state.title == "From runtime")
        state.setTitle(tabID: nil, title: "")
        #expect(state.title == "From manifest")
    }
}

@Suite("Side panel settings survive a relaunch")
@MainActor
struct ExtensionSidebarStoreTests {
    private func makeStore() -> (ExtensionSidebarStore, UserDefaults, String) {
        let suite = "kylmora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (ExtensionSidebarStore(defaults: defaults), defaults, suite)
    }

    @Test("What an extension set is still there next launch")
    func persists() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        store.update(id) { $0.setOptions(tabID: nil, path: "chosen.html", isEnabled: nil) }
        let reopened = ExtensionSidebarStore(defaults: defaults)
        #expect(reopened.state(for: id).path(forTab: nil) == "chosen.html")
    }

    @Test("An update moves the manifest's page without losing what was chosen")
    func adoptKeepsChoices() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        store.adopt(ExtensionSidebarDefinition(path: "v1.html", title: nil, iconPaths: [], opensOnInstall: false, flavour: .chrome), for: id)
        store.update(id) { $0.opensOnActionClick = true }
        store.adopt(ExtensionSidebarDefinition(path: "v2.html", title: "New", iconPaths: [], opensOnInstall: false, flavour: .firefox), for: id)
        #expect(store.state(for: id).path(forTab: nil) == "v2.html")
        #expect(store.state(for: id).opensOnActionClick)
        #expect(store.state(for: id).title == "New")
    }

    @Test("Removing an extension removes its panel settings")
    func forget() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        store.update(id) { $0.setOptions(tabID: nil, path: "p.html", isEnabled: nil) }
        store.forget(id)
        #expect(store.state(for: id).path(forTab: nil) == nil)
    }

    @Test("A change tells whoever is listening")
    func notifies() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        var changed: [UUID] = []
        store.onChange = { changed.append($0) }
        let id = UUID()
        store.update(id) { $0.opensOnActionClick = true }
        #expect(changed == [id])
    }
}

@Suite("The side panel API means one thing wherever it is called from")
@MainActor
struct ExtensionSidebarBrokerTests {
    private func makeBroker() -> (ExtensionSidebarBroker, ExtensionSidebarStore, UUID, UserDefaults, String) {
        let suite = "kylmora.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = ExtensionSidebarStore(defaults: defaults)
        let id = UUID()
        store.adopt(ExtensionSidebarDefinition(path: "panel.html", title: "Panel", iconPaths: [], opensOnInstall: false, flavour: .chrome), for: id)
        return (ExtensionSidebarBroker(store: store), store, id, defaults, suite)
    }

    @Test("setOptions and getOptions agree")
    func options() {
        let (broker, _, id, defaults, suite) = makeBroker()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(broker.perform("sidePanel.setOptions", arguments: ["path": "one.html"], for: id) == .done)
        #expect(broker.perform("sidePanel.getOptions", arguments: [:], for: id)
            == .value(["path": .string("one.html"), "enabled": .bool(true)]))
    }

    @Test("A tab's options are that tab's when it asks and nobody else's")
    func tabOptions() {
        let (broker, _, id, defaults, suite) = makeBroker()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = broker.perform("sidePanel.setOptions", arguments: ["tabId": 5, "path": "five.html"], for: id)
        #expect(broker.perform("sidePanel.getOptions", arguments: ["tabId": 5], for: id)
            == .value(["path": .string("five.html"), "enabled": .bool(true), "tabId": .number(5)]))
        #expect(broker.perform("sidePanel.getOptions", arguments: ["tabId": 6], for: id)
            == .value(["path": .string("panel.html"), "enabled": .bool(true), "tabId": .number(6)]))
    }

    @Test("A switched-off panel says so")
    func disabled() {
        let (broker, _, id, defaults, suite) = makeBroker()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = broker.perform("sidePanel.setOptions", arguments: ["enabled": false], for: id)
        #expect(broker.perform("sidePanel.getOptions", arguments: [:], for: id)
            == .value(["path": .null, "enabled": .bool(false)]))
    }

    @Test("The button's behaviour is remembered and reported")
    func panelBehavior() {
        let (broker, _, id, defaults, suite) = makeBroker()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(broker.perform("sidePanel.getPanelBehavior", arguments: [:], for: id)
            == .value(["openPanelOnActionClick": .bool(false)]))
        _ = broker.perform("sidePanel.setPanelBehavior", arguments: ["openPanelOnActionClick": true], for: id)
        #expect(broker.opensOnActionClick(id))
    }

    @Test("open opens, for the tab it was asked about")
    func open() {
        let (broker, _, id, defaults, suite) = makeBroker()
        defer { defaults.removePersistentDomain(forName: suite) }
        var opened: [(UUID, Int?)] = []
        broker.opensPanel = { opened.append(($0, $1)) }
        #expect(broker.perform("sidePanel.open", arguments: ["tabId": 9], for: id) == .done)
        #expect(opened.count == 1)
        #expect(opened.first?.0 == id)
        #expect(opened.first?.1 == 9)
    }

    @Test("Opening a panel that is switched off fails instead of opening nothing")
    func openWithoutPanel() {
        let (broker, _, id, defaults, suite) = makeBroker()
        defer { defaults.removePersistentDomain(forName: suite) }
        var opened = 0
        broker.opensPanel = { _, _ in opened += 1 }
        _ = broker.perform("sidePanel.setOptions", arguments: ["enabled": false], for: id)
        guard case .failure = broker.perform("sidePanel.open", arguments: [:], for: id) else {
            Issue.record("Opening a disabled panel should fail")
            return
        }
        #expect(opened == 0)
    }

    @Test("Firefox's setPanel and getPanel agree")
    func firefoxPanel() {
        let (broker, _, id, defaults, suite) = makeBroker()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = broker.perform("sidebarAction.setPanel", arguments: ["panel": "fox.html"], for: id)
        #expect(broker.perform("sidebarAction.getPanel", arguments: [:], for: id)
            == .value(["panel": .string("fox.html")]))
    }

    @Test("Firefox's title round-trips")
    func firefoxTitle() {
        let (broker, _, id, defaults, suite) = makeBroker()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = broker.perform("sidebarAction.setTitle", arguments: ["title": "Reading"], for: id)
        #expect(broker.perform("sidebarAction.getTitle", arguments: [:], for: id)
            == .value(["title": .string("Reading")]))
    }

    @Test("An icon an extension sets is accepted rather than refused")
    func firefoxIcon() {
        let (broker, _, id, defaults, suite) = makeBroker()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(broker.perform("sidebarAction.setIcon", arguments: ["path": "icon.png"], for: id) == .done)
    }

    @Test("toggle opens a closed panel and closes an open one")
    func toggle() {
        let (broker, _, id, defaults, suite) = makeBroker()
        defer { defaults.removePersistentDomain(forName: suite) }
        var isOpen = false
        broker.isPanelOpen = { _ in isOpen }
        broker.opensPanel = { _, _ in isOpen = true }
        broker.closesPanel = { _ in isOpen = false }
        _ = broker.perform("sidebarAction.toggle", arguments: [:], for: id)
        #expect(isOpen)
        #expect(broker.perform("sidebarAction.isOpen", arguments: [:], for: id) == .value(["isOpen": .bool(true)]))
        _ = broker.perform("sidebarAction.toggle", arguments: [:], for: id)
        #expect(!isOpen)
    }

    @Test("close closes")
    func close() {
        let (broker, _, id, defaults, suite) = makeBroker()
        defer { defaults.removePersistentDomain(forName: suite) }
        var closed = 0
        broker.closesPanel = { _ in closed += 1 }
        #expect(broker.perform("sidebarAction.close", arguments: [:], for: id) == .done)
        #expect(closed == 1)
    }

    @Test("The tab the extension says is in front is the one per-tab options follow")
    func currentTab() {
        let (broker, _, id, defaults, suite) = makeBroker()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = broker.perform("sidePanel.setOptions", arguments: ["tabId": 11, "path": "eleven.html"], for: id)
        #expect(broker.panelPath(for: id) == "panel.html")
        _ = broker.perform("kylmora.tabChanged", arguments: ["tabId": 11], for: id)
        #expect(broker.panelPath(for: id) == "eleven.html")
    }

    @Test("A tab that closes takes its panel setting with it")
    func tabRemoved() {
        let (broker, _, id, defaults, suite) = makeBroker()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = broker.perform("sidePanel.setOptions", arguments: ["tabId": 11, "path": "eleven.html"], for: id)
        _ = broker.perform("kylmora.tabChanged", arguments: ["tabId": 11], for: id)
        _ = broker.perform("kylmora.tabRemoved", arguments: ["tabId": 11], for: id)
        #expect(broker.panelPath(for: id) == "panel.html")
    }

    @Test("A call the API does not have says so rather than pretending")
    func unknownMethod() {
        let (broker, _, id, defaults, suite) = makeBroker()
        defer { defaults.removePersistentDomain(forName: suite) }
        guard case .failure(let message) = broker.perform("sidePanel.explode", arguments: [:], for: id) else {
            Issue.record("An unknown call should fail")
            return
        }
        #expect(message.contains("sidePanel.explode"))
    }

    @Test("One extension's settings are not another's")
    func extensionsAreSeparate() {
        let (broker, _, first, defaults, suite) = makeBroker()
        defer { defaults.removePersistentDomain(forName: suite) }
        let second = UUID()
        _ = broker.perform("sidePanel.setOptions", arguments: ["path": "mine.html"], for: first)
        #expect(broker.panelPath(for: first) == "mine.html")
        #expect(broker.panelPath(for: second) == nil)
    }
}

@Suite("The shim goes into the package, and nothing else is touched")
struct ExtensionSidebarPackageTests {
    @Test("A Chrome extension's worker loads the shim and then its own code")
    func wrapsServiceWorker() throws {
        let root = Panels.makeRoot()
        defer { Panels.remove(root) }
        Panels.package(Panels.chromeManifest(), files: ["worker.js": "self.kylmoraOriginalRan = true;\n"], in: root)
        let outcome = try ExtensionSidebarPackage.prepare(folder: root)
        #expect(outcome.wrappedBackground)
        #expect(outcome.definition?.path == "panel.html")

        let manifest = Panels.manifest(in: root)
        let background = manifest["background"] as? [String: Any]
        #expect(background?["service_worker"] as? String == ExtensionSidebarShim.workerEntryFileName)
        let entry = Panels.contents(ExtensionSidebarShim.workerEntryFileName, in: root)
        #expect(entry?.contains("importScripts('\(ExtensionSidebarShim.workerFileName)')") == true)
        #expect(entry?.contains("importScripts('worker.js')") == true)
        // The extension's own file is left exactly as it was.
        #expect(Panels.contents("worker.js", in: root) == "self.kylmoraOriginalRan = true;\n")
        #expect(Panels.contents(ExtensionSidebarShim.workerFileName, in: root)?.contains("sidePanel") == true)
    }

    @Test("A module worker is imported as a module")
    func wrapsModuleWorker() throws {
        let root = Panels.makeRoot()
        defer { Panels.remove(root) }
        var manifest = Panels.chromeManifest()
        manifest["background"] = ["service_worker": "worker.js", "type": "module"]
        Panels.package(manifest, files: ["worker.js": "export const x = 1;\n"], in: root)
        _ = try ExtensionSidebarPackage.prepare(folder: root)
        let entry = Panels.contents(ExtensionSidebarShim.workerEntryFileName, in: root)
        #expect(entry?.contains("import './\(ExtensionSidebarShim.workerFileName)';") == true)
        #expect(entry?.contains("import './worker.js';") == true)
        #expect(entry?.contains("importScripts") == false)
        // The type is left alone: it still is a module.
        let background = Panels.manifest(in: root)["background"] as? [String: Any]
        #expect(background?["type"] as? String == "module")
    }

    @Test("An older extension's background scripts get the shim first")
    func prependsToScripts() throws {
        let root = Panels.makeRoot()
        defer { Panels.remove(root) }
        Panels.package([
            "manifest_version": 2,
            "name": "Old",
            "version": "1",
            "background": ["scripts": ["a.js", "b.js"]],
            "sidebar_action": ["default_panel": "panel.html"],
        ], in: root)
        let outcome = try ExtensionSidebarPackage.prepare(folder: root)
        #expect(outcome.wrappedBackground)
        let background = Panels.manifest(in: root)["background"] as? [String: Any]
        #expect(background?["scripts"] as? [String] == [ExtensionSidebarShim.workerFileName, "a.js", "b.js"])
    }

    @Test("The shim's way back to Kylmora is asked for in the manifest")
    func addsNativeMessaging() throws {
        let root = Panels.makeRoot()
        defer { Panels.remove(root) }
        Panels.package(Panels.chromeManifest(), files: ["worker.js": ""], in: root)
        _ = try ExtensionSidebarPackage.prepare(folder: root)
        let permissions = Panels.manifest(in: root)["permissions"] as? [String]
        #expect(permissions?.contains("nativeMessaging") == true)
        // And what the extension itself asked for is still there.
        #expect(permissions?.contains("storage") == true)
    }

    @Test("An extension with no panel is left byte for byte as it arrived")
    func leavesOthersAlone() throws {
        let root = Panels.makeRoot()
        defer { Panels.remove(root) }
        Panels.package([
            "manifest_version": 3, "name": "Plain", "version": "1",
            "background": ["service_worker": "worker.js"],
        ], files: ["worker.js": "// nothing to see\n"], in: root)
        let before = try Data(contentsOf: root.appending(path: "manifest.json"))
        let outcome = try ExtensionSidebarPackage.prepare(folder: root)
        #expect(outcome == .notWanted)
        #expect(try Data(contentsOf: root.appending(path: "manifest.json")) == before)
        #expect(Panels.contents(ExtensionSidebarShim.workerFileName, in: root) == nil)
    }

    @Test("Preparing twice does not wrap the wrapper")
    func idempotent() throws {
        let root = Panels.makeRoot()
        defer { Panels.remove(root) }
        Panels.package(Panels.chromeManifest(), files: ["worker.js": ""], in: root)
        _ = try ExtensionSidebarPackage.prepare(folder: root)
        let afterFirst = Panels.manifest(in: root)
        let outcome = try ExtensionSidebarPackage.prepare(folder: root)
        let afterSecond = Panels.manifest(in: root)
        #expect(outcome.wrappedBackground)
        #expect((afterSecond["background"] as? [String: Any])?["service_worker"] as? String
            == ExtensionSidebarShim.workerEntryFileName)
        #expect((afterFirst["permissions"] as? [String]) == (afterSecond["permissions"] as? [String]))
        let entry = Panels.contents(ExtensionSidebarShim.workerEntryFileName, in: root)
        #expect(entry?.contains("importScripts('worker.js')") == true)
        #expect(entry?.contains(ExtensionSidebarShim.workerEntryFileName) == false)
    }

    @Test("A second pass writes the current shim over an older one")
    func refreshesShim() throws {
        let root = Panels.makeRoot()
        defer { Panels.remove(root) }
        Panels.package(Panels.chromeManifest(), files: ["worker.js": ""], in: root)
        _ = try ExtensionSidebarPackage.prepare(folder: root)
        try Data("// an older Kylmora wrote this\n".utf8)
            .write(to: root.appending(path: ExtensionSidebarShim.workerFileName))
        _ = try ExtensionSidebarPackage.prepare(folder: root)
        #expect(Panels.contents(ExtensionSidebarShim.workerFileName, in: root)?.contains("sidebarAction") == true)
    }

    @Test("An extension with a panel and no background code still gets its panel")
    func noBackground() throws {
        let root = Panels.makeRoot()
        defer { Panels.remove(root) }
        Panels.package([
            "manifest_version": 3, "name": "Panel only", "version": "1",
            "side_panel": ["default_path": "panel.html"],
        ], in: root)
        let outcome = try ExtensionSidebarPackage.prepare(folder: root)
        #expect(!outcome.wrappedBackground)
        #expect(outcome.definition?.path == "panel.html")
        #expect(outcome.note?.isEmpty == false)
    }

    @Test("A package with no manifest is refused rather than half-written")
    func noManifest() {
        let root = Panels.makeRoot()
        defer { Panels.remove(root) }
        #expect(throws: ExtensionSidebarPackage.Failure.noManifest) {
            _ = try ExtensionSidebarPackage.prepare(folder: root)
        }
    }
}

/// The shim is JavaScript, so it is tested as JavaScript: loaded into a real
/// engine, given the objects an extension would have, and called the way an
/// extension calls it.
@Suite("The shim's JavaScript does what an extension expects")
struct ExtensionSidebarShimTests {
    /// A context holding a `chrome` object and a fake native port, standing in
    /// for what the engine gives a background worker.
    private final class Harness {
        let context = JSContext()!
        /// Every message the shim posted, in order.
        var posted: [[String: Any]] = []
        private var onMessage: JSValue?

        init() {
            context.exceptionHandler = { _, value in
                Issue.record("JavaScript threw: \(value?.toString() ?? "unknown")")
            }
            let post: @convention(block) (JSValue) -> Void = { [weak self] message in
                self?.posted.append(message.toDictionary() as? [String: Any] ?? [:])
            }
            let addListener: @convention(block) (JSValue) -> Void = { [weak self] handler in
                if self?.onMessage == nil { self?.onMessage = handler }
            }
            let noop: @convention(block) (JSValue) -> Void = { _ in }
            context.evaluateScript("var chrome = { runtime: {} };")
            let runtime = context.objectForKeyedSubscript("chrome")!.objectForKeyedSubscript("runtime")!
            let connectNative: @convention(block) (String) -> JSValue = { [weak self] _ in
                guard let self else { return JSValue(undefinedIn: nil) }
                let port = JSValue(newObjectIn: self.context)!
                port.setObject(post, forKeyedSubscript: "postMessage" as NSString)
                let onMessageObject = JSValue(newObjectIn: self.context)!
                onMessageObject.setObject(addListener, forKeyedSubscript: "addListener" as NSString)
                port.setObject(onMessageObject, forKeyedSubscript: "onMessage" as NSString)
                let onDisconnect = JSValue(newObjectIn: self.context)!
                onDisconnect.setObject(noop, forKeyedSubscript: "addListener" as NSString)
                port.setObject(onDisconnect, forKeyedSubscript: "onDisconnect" as NSString)
                return port
            }
            runtime.setObject(connectNative, forKeyedSubscript: "connectNative" as NSString)
            context.evaluateScript(ExtensionSidebarShim.worker)
        }

        /// Answers the call the shim is waiting on, the way Kylmora would.
        func reply(to id: Any, ok: Bool, value: [String: Any]? = nil, error: String? = nil) {
            var message: [String: Any] = ["id": id, "ok": ok]
            if let value { message["value"] = value }
            if let error { message["error"] = error }
            onMessage?.call(withArguments: [message])
        }

        @discardableResult
        func run(_ script: String) -> JSValue? {
            context.evaluateScript(script)
        }
    }

    @Test("The shim defines both spellings of the API")
    func definesBoth() {
        let harness = Harness()
        #expect(harness.run("typeof chrome.sidePanel.setOptions")?.toString() == "function")
        #expect(harness.run("typeof chrome.sidePanel.open")?.toString() == "function")
        #expect(harness.run("typeof chrome.sidebarAction.toggle")?.toString() == "function")
        #expect(harness.run("typeof chrome.sidePanel.getPanelBehavior")?.toString() == "function")
    }

    @Test("A call goes out as the method and the arguments it was given")
    func posts() {
        let harness = Harness()
        harness.run("chrome.sidePanel.setOptions({ path: 'p.html', enabled: true })")
        #expect(harness.posted.count == 1)
        #expect(harness.posted.first?["method"] as? String == "sidePanel.setOptions")
        let args = harness.posted.first?["args"] as? [String: Any]
        #expect(args?["path"] as? String == "p.html")
        #expect(args?["enabled"] as? Bool == true)
    }

    @Test("A promise resolves with the answer Kylmora gives")
    func resolvesPromise() {
        let harness = Harness()
        harness.run("var result = null; chrome.sidePanel.getOptions({}).then(function (v) { result = v; });")
        guard let id = harness.posted.first?["id"] else {
            Issue.record("Nothing was posted")
            return
        }
        harness.reply(to: id, ok: true, value: ["path": "p.html", "enabled": true])
        // Promise callbacks run on the microtask queue, which JavaScriptCore
        // drains when the next script runs.
        harness.run(";")
        #expect(harness.run("result && result.path")?.toString() == "p.html")
    }

    @Test("A callback is called too, for extensions written the older way")
    func callsBack() {
        let harness = Harness()
        harness.run("var seen = null; chrome.sidePanel.getOptions({}, function (v) { seen = v; });")
        guard let id = harness.posted.first?["id"] else {
            Issue.record("Nothing was posted")
            return
        }
        harness.reply(to: id, ok: true, value: ["path": "cb.html"])
        harness.run(";")
        #expect(harness.run("seen && seen.path")?.toString() == "cb.html")
    }

    @Test("A refusal rejects the promise rather than resolving with nothing")
    func rejects() {
        let harness = Harness()
        harness.run("var failed = null; chrome.sidePanel.open({}).catch(function (e) { failed = e.message; });")
        guard let id = harness.posted.first?["id"] else {
            Issue.record("Nothing was posted")
            return
        }
        harness.reply(to: id, ok: false, error: "No side panel is set for this tab.")
        harness.run(";")
        #expect(harness.run("failed")?.toString() == "No side panel is set for this tab.")
    }

    @Test("Firefox's plain-value calls are understood", arguments: [
        ("chrome.sidebarAction.setTitle('Reading')", "sidebarAction.setTitle", "title", "Reading"),
        ("chrome.sidebarAction.setPanel('fox.html')", "sidebarAction.setPanel", "panel", "fox.html"),
    ])
    func valueCalls(_ script: String, _ method: String, _ key: String, _ value: String) {
        let harness = Harness()
        harness.run(script)
        #expect(harness.posted.first?["method"] as? String == method)
        #expect((harness.posted.first?["args"] as? [String: Any])?[key] as? String == value)
    }

    @Test("Firefox's object form is understood as well")
    func objectForm() {
        let harness = Harness()
        harness.run("chrome.sidebarAction.setPanel({ panel: 'fox.html', tabId: 4 })")
        let args = harness.posted.first?["args"] as? [String: Any]
        #expect(args?["panel"] as? String == "fox.html")
        #expect(args?["tabId"] as? Int == 4)
    }

    @Test("Two calls in flight are answered separately")
    func concurrentCalls() {
        let harness = Harness()
        harness.run("""
        var first = null, second = null;
        chrome.sidePanel.getOptions({ tabId: 1 }).then(function (v) { first = v.path; });
        chrome.sidePanel.getOptions({ tabId: 2 }).then(function (v) { second = v.path; });
        """)
        #expect(harness.posted.count == 2)
        // Answered out of order on purpose: the reply carries the call it
        // belongs to, and nothing may be matched by arrival order.
        harness.reply(to: harness.posted[1]["id"]!, ok: true, value: ["path": "two.html"])
        harness.reply(to: harness.posted[0]["id"]!, ok: true, value: ["path": "one.html"])
        harness.run(";")
        #expect(harness.run("first")?.toString() == "one.html")
        #expect(harness.run("second")?.toString() == "two.html")
    }

    @Test("The shim stays out of the way if the engine ever grows the real API")
    func defersToTheEngine() {
        let context = JSContext()!
        context.evaluateScript("""
        var chrome = { runtime: {}, sidePanel: { real: true }, sidebarAction: { real: true } };
        """)
        context.evaluateScript(ExtensionSidebarShim.worker)
        #expect(context.evaluateScript("chrome.sidePanel.real")?.toBool() == true)
        #expect(context.evaluateScript("typeof chrome.sidePanel.setOptions")?.toString() == "undefined")
    }

    @Test("The page shim is valid JavaScript and needs no native port")
    func pageShimLoads() {
        let context = JSContext()!
        var thrown: String?
        context.exceptionHandler = { _, value in thrown = value?.toString() }
        context.evaluateScript("var chrome = { runtime: {} }; var window = { webkit: undefined };")
        context.evaluateScript(ExtensionSidebarShim.page)
        #expect(thrown == nil)
        #expect(context.evaluateScript("typeof chrome.sidePanel.setOptions")?.toString() == "function")
    }
}
