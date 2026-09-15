import AppKit
import Foundation
import Testing
@testable import Kylmora

@MainActor
private final class RecordingPerformer: AutomationPerformer {
    var performed: [(AutomationAction, Tab?, AutomationRule)] = []
    func perform(_ action: AutomationAction, on tab: Tab?, event: AutomationEvent, rule: AutomationRule) {
        performed.append((action, tab, rule))
    }
}

@Suite("Automations")
@MainActor
struct AutomationTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test("A rule fires for its own event, on matching addresses, only when enabled")
    func matching() {
        let work = UUID()
        let mute = AutomationRule(name: "Mute news", trigger: .pageLoaded(pattern: "news.example", match: .contains), actions: [.muteTab])
        let idle = AutomationRule(name: "Archive idle", trigger: .tabIdle(minutes: 30, pattern: "", match: .contains), actions: [.archiveTab])
        let media = AutomationRule(name: "Pin players", trigger: .mediaStarted(pattern: "^https://music\\.", match: .regex), actions: [.pinTab, .moveToSpace(work)])
        let pdf = AutomationRule(name: "PDFs", trigger: .downloadFinished(fileExtension: "pdf"), actions: [.notify("Got {{file}}")])
        var off = mute
        off.isEnabled = false
        let rules = [mute, idle, media, pdf, off]

        #expect(AutomationEngine.rules(firing: .pageLoaded(url: url("https://news.example/story")), in: rules).map(\.name) == ["Mute news"])
        #expect(AutomationEngine.rules(firing: .pageLoaded(url: url("https://other.example/")), in: rules).isEmpty)
        #expect(AutomationEngine.rules(firing: .tabIdle(url: url("https://a.b/"), idleMinutes: 29), in: rules).isEmpty)
        #expect(AutomationEngine.rules(firing: .tabIdle(url: url("https://a.b/"), idleMinutes: 30), in: rules).map(\.name) == ["Archive idle"])
        #expect(AutomationEngine.rules(firing: .mediaStarted(url: url("https://music.example/")), in: rules).map(\.name) == ["Pin players"])
        #expect(AutomationEngine.rules(firing: .mediaStarted(url: url("https://video.example/")), in: rules).isEmpty)
        #expect(AutomationEngine.rules(firing: .downloadFinished(fileURL: url("file:///tmp/a.PDF")), in: rules).map(\.name) == ["PDFs"])
        #expect(AutomationEngine.rules(firing: .downloadFinished(fileURL: url("file:///tmp/a.zip")), in: rules).isEmpty)
        // An empty extension is any download.
        let any = AutomationRule(name: "Any", trigger: .downloadFinished(fileExtension: " . "), actions: [.notify("x")])
        #expect(AutomationEngine.rules(firing: .downloadFinished(fileURL: url("file:///tmp/a.zip")), in: [any]).count == 1)
    }

    @Test("Rules round-trip through JSON, and empty ones are dropped")
    func storage() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "automations-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = AutomationStore(fileURL: file)
        #expect(store.load() == .empty)

        let space = UUID()
        let rules = AutomationRules(rules: [
            AutomationRule(name: "A", trigger: .tabIdle(minutes: 15, pattern: "x", match: .equalTo), actions: [.moveToSpace(space), .setZoom("1.25"), .runAppleScript("say \"{{title}}\"")]),
            AutomationRule(name: "Empty", trigger: .pageLoaded(pattern: "", match: .contains), actions: [])
        ])
        try store.save(rules)
        let loaded = store.load()
        #expect(loaded.rules.count == 1)
        #expect(loaded.rules.first == rules.rules.first)
        // Readable by a person: the file names its parts.
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("tabIdle"))
        #expect(text.contains("moveToSpace"))
        #expect(try AutomationStore.rules(from: Data(text.utf8)).rules.count == 1)
    }

    @Test("Summaries read as sentences and placeholders fill in")
    func summaries() {
        let rule = AutomationRule(name: "R", trigger: .tabIdle(minutes: 30, pattern: "docs.example", match: .contains), actions: [.archiveTab, .notify("bye")])
        #expect(rule.trigger.summary == "When a tab sits idle for 30 min, matching docs.example")
        #expect(AutomationTrigger.downloadFinished(fileExtension: "").summary == "When a download finishes of any kind")
        #expect(AutomationsSettingsViewController.summary(of: rule, spaces: []) == "When a tab sits idle for 30 min, matching docs.example: archive the tab, say “bye”")
        #expect(AutomationAction.moveToSpace(UUID()).summary(spaceName: { _ in nil }) == "move to a missing Space")
        #expect(AutomationPlaceholders.fill("{{title}} at {{url}} {{file}}", url: url("https://a.b/"), title: "T", file: nil) == "T at https://a.b/ ")
        #expect(AutomationAction.make(.runShortcut, parameter: "") == nil)
        #expect(AutomationAction.make(.setZoom, parameter: "") == .setZoom("1"))
        #expect(AutomationAction.make(.moveToSpace, parameter: "nope") == nil)
    }

    @Test("The service runs actions on the tab, moving it last, and skips tab actions for downloads")
    func service() {
        let file = FileManager.default.temporaryDirectory.appending(path: "automations-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let service = AutomationService(store: AutomationStore(fileURL: file))
        let (session, _) = TestSession.make()
        let performer = RecordingPerformer()
        service.start(session: session, performer: performer, idleCheckInterval: 3600)
        defer { service.stop() }

        let work = UUID()
        service.add(AutomationRule(name: "Work", trigger: .pageLoaded(pattern: "work.example", match: .contains), actions: [.moveToSpace(work), .muteTab, .notify("hi")]))
        service.add(AutomationRule(name: "Downloads", trigger: .downloadFinished(fileExtension: ""), actions: [.pinTab, .notify("done")]))
        #expect(service.rules.rules.count == 2)

        let tab = Tab(url: url("https://work.example/"), identity: .standard)
        #expect(service.handle(.pageLoaded(url: tab.url), tab: tab))
        #expect(performer.performed.map(\.0) == [.muteTab, .notify("hi"), .moveToSpace(work)], "the move comes last")
        #expect(performer.performed.allSatisfy { $0.1 === tab })

        performer.performed.removeAll()
        #expect(service.handle(.downloadFinished(fileURL: url("file:///tmp/x.zip")), tab: nil))
        #expect(performer.performed.map(\.0) == [.notify("done")], "pinning needs a tab")

        #expect(!service.handle(.mediaStarted(url: url("https://work.example/")), tab: tab))

        // The session's visit hook reaches the service.
        performer.performed.removeAll()
        session.onVisit?(tab, tab.url)
        #expect(performer.performed.count == 3)

        // Editing persists.
        service.remove(id: service.rules.rules[1].id)
        #expect(AutomationStore(fileURL: file).load().rules.count == 1)
        let exported = try? service.exportData()
        #expect(exported != nil)
        try? service.importRules(from: exported!)
        #expect(service.rules.rules.count == 1, "importing what is already there adds nothing")
    }

    @Test("Idle rules fire once per stretch of inactivity, never for the active tab")
    func idle() {
        let file = FileManager.default.temporaryDirectory.appending(path: "automations-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let service = AutomationService(store: AutomationStore(fileURL: file))
        let (session, _) = TestSession.make()
        let performer = RecordingPerformer()
        service.start(session: session, performer: performer, idleCheckInterval: 3600)
        defer { service.stop() }
        service.add(AutomationRule(name: "Idle", trigger: .tabIdle(minutes: 10, pattern: "", match: .contains), actions: [.notify("idle")]))

        let first = session.newTab(url: url("https://a.example/"))
        let second = session.newTab(url: url("https://b.example/"))
        #expect(session.activeTab === second)

        // A fresh session starts with one tab of its own, which is idle too.
        service.checkIdleTabs(now: .now.addingTimeInterval(11 * 60))
        let firedIDs = performer.performed.map { $0.1?.id }
        #expect(firedIDs.contains(first.id))
        #expect(!firedIDs.contains(second.id), "never the active tab")
        let firstRound = performer.performed.count
        service.checkIdleTabs(now: .now.addingTimeInterval(20 * 60))
        #expect(performer.performed.count == firstRound, "not again for the same stretch")
        first.markActive()
        service.checkIdleTabs(now: .now.addingTimeInterval(40 * 60))
        #expect(performer.performed.count == firstRound + 1, "used again, idle again, fires again")
        #expect(performer.performed.last?.1 === first)
    }

    @Test("The Automations pane lists routes and rules and edits routes in place")
    func pane() {
        let routingFile = FileManager.default.temporaryDirectory.appending(path: "routing-\(UUID().uuidString).json")
        let rulesFile = FileManager.default.temporaryDirectory.appending(path: "automations-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: routingFile); try? FileManager.default.removeItem(at: rulesFile) }
        let (session, _) = TestSession.make()
        let service = AutomationService(store: AutomationStore(fileURL: rulesFile))
        service.add(AutomationRule(name: "One", trigger: .pageLoaded(pattern: "", match: .contains), actions: [.pinTab]))
        session.routing.replace(with: SpaceRoutingRules(routes: [SpaceRoute(reference: "a.example", match: .contains, destination: .space(session.activeSpace.id))]))

        let pane = AutomationsSettingsViewController(session: session, automations: service)
        _ = pane.view
        #expect(pane.shownRuleCount == 1)
        #expect(pane.shownRouteCount == 1)

        let editor = AutomationEditorViewController(rule: service.rules.rules[0], spaces: session.spaces) { _ in }
        _ = editor.view
        let edited = editor.currentRule()
        #expect(edited.name == "One")
        #expect(edited.actions == [.pinTab])
        #expect(SettingsWindowController.Pane.allCases.contains(.automations))
        #expect(CommandCatalog.all.contains { $0.id == "automations" })
    }
}

@Suite("Custom commands")
@MainActor
struct CustomCommandTests {
    @Test("A manual rule never fires on events, shows in the palette, and runs on demand")
    func manual() {
        let file = FileManager.default.temporaryDirectory.appending(path: "automations-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let service = AutomationService(store: AutomationStore(fileURL: file))
        let (session, _) = TestSession.make()
        let performer = RecordingPerformer()
        service.start(session: session, performer: performer, idleCheckInterval: 3600)
        defer { service.stop() }

        let command = AutomationRule(name: "Tidy up", trigger: .manual, actions: [.muteTab, .notify("done {{title}}")])
        service.add(command)
        var off = AutomationRule(name: "Hidden", trigger: .manual, actions: [.pinTab])
        off.isEnabled = false
        service.add(off)

        #expect(!service.handle(.pageLoaded(url: URL(string: "https://a.example/")!), tab: nil))
        #expect(AutomationEngine.rules(firing: .mediaStarted(url: URL(string: "https://a.example/")!), in: service.rules.rules).isEmpty)
        #expect(AutomationTrigger.manual.summary == "When run from the command palette")

        let commands = service.paletteCommands
        #expect(commands.count == 1, "a disabled command is not offered")
        #expect(commands.first?.title == "Tidy up")
        #expect(commands.first?.keywords.contains("tidy") == true)
        let id = commands.first!.id
        #expect(id.hasPrefix(AutomationService.commandPrefix))

        let tab = Tab(url: URL(string: "https://a.example/")!, identity: .standard)
        #expect(service.runCommand(id: id, tab: tab))
        #expect(performer.performed.map(\.0) == [.muteTab, .notify("done {{title}}")])
        #expect(performer.performed.first?.1 === tab)
        #expect(!service.runCommand(id: "print-page", tab: tab), "other ids are the window's")
        #expect(!service.runCommand(id: AutomationService.commandPrefix + UUID().uuidString, tab: tab))

        // Round trip through the file keeps the trigger.
        let reloaded = AutomationStore(fileURL: file).load()
        #expect(reloaded.rules.first?.trigger == .manual)
    }
}
