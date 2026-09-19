import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("A space is an identity")
@MainActor
struct SpaceIdentityTests {
    @Test("A fresh session has one space, on WebKit's default store")
    func firstSpaceKeepsTheDefaultStore() {
        let session = TestSession.make().0
        #expect(session.spaces.count == 1)
        #expect(session.activeSpace.identity == .standard)
        #expect(session.activeSpace.isPrivate == false)
        #expect(session.activeSpace.theme == .blue)
    }

    @Test("Every new space gets a store of its own")
    func newSpacesAreSeparate() {
        let session = TestSession.make().0
        let work = session.addSpace(named: "Work")
        let research = session.addSpace(named: "Research")

        #expect(work.identity != .standard)
        #expect(work.identity != research.identity)
        guard case .isolated = work.identity else {
            Issue.record("a new space should keep its data on disk")
            return
        }
    }

    @Test("A private space keeps nothing")
    func privateSpaceIsEphemeral() {
        let session = TestSession.make().0
        let incognito = session.addSpace(named: "Private", isPrivate: true)
        #expect(incognito.isPrivate)
        #expect(WebEnvironment.shared.dataStore(for: incognito.identity).isPersistent == false)
    }

    @Test("Each identity maps to a distinct website data store")
    func distinctDataStores() {
        let session = TestSession.make().0
        let work = session.addSpace(named: "Work")
        let incognito = session.addSpace(named: "Private", isPrivate: true)

        let environment = WebEnvironment.shared
        let standardStore = environment.dataStore(for: session.spaces[0].identity)
        let workStore = environment.dataStore(for: work.identity)
        let privateStore = environment.dataStore(for: incognito.identity)

        #expect(standardStore !== workStore)
        #expect(workStore !== privateStore)
        #expect(standardStore.isPersistent)
        #expect(workStore.isPersistent)
        #expect(privateStore.isPersistent == false)
    }

    @Test("Two private spaces do not see each other's cookies")
    func privateSpacesAreSeparateToo() {
        let session = TestSession.make().0
        let one = session.addSpace(named: "One", isPrivate: true)
        let two = session.addSpace(named: "Two", isPrivate: true)
        #expect(one.identity != two.identity)
        #expect(WebEnvironment.shared.dataStore(for: one.identity) !== WebEnvironment.shared.dataStore(for: two.identity))
    }

    @Test("One space means one data store, however often it is asked for")
    func dataStoresAreCached() {
        let session = TestSession.make().0
        let work = session.addSpace(named: "Work")
        let first = WebEnvironment.shared.dataStore(for: work.identity)
        let second = WebEnvironment.shared.dataStore(for: work.identity)
        #expect(first === second)
    }

    @Test("A tab browses under its space's identity")
    func tabsCarryTheSpaceIdentity() {
        let session = TestSession.make().0
        let work = session.addSpace(named: "Work")
        session.newTab(url: URL(string: "https://example.com")!)
        #expect(work.tabs.allSatisfy { $0.identity == work.identity })
        #expect(session.spaces[0].tabs.allSatisfy { $0.identity == .standard })
    }

    @Test("New spaces take the next colour nobody is using")
    func newSpacesGetFreshColours() {
        let session = TestSession.make().0
        let work = session.addSpace(named: "Work")
        #expect(work.theme != session.spaces[0].theme)
        #expect(work.theme != .neutral)
        let research = session.addSpace(named: "Research")
        #expect(research.theme != work.theme)
        #expect(research.theme != session.spaces[0].theme)
    }

    @Test("Deleting a space takes its identity with it")
    func deletingASpace() {
        let session = TestSession.make().0
        let work = session.addSpace(named: "Work")
        session.removeSpace(work)
        #expect(session.spaces.count == 1)
        #expect(session.activeSpace.identity == .standard)
    }

    @Test("The last space cannot be deleted")
    func lastSpaceIsPermanent() {
        let session = TestSession.make().0
        session.removeSpace(session.activeSpace)
        #expect(session.spaces.count == 1)
    }

    @Test("Identities and colours survive a relaunch")
    func identitiesRoundTrip() {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "kylmora-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = SessionStore(fileURL: file)
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!

        let first = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        let work = first.addSpace(named: "Work", theme: .amber)
        first.saveNow()

        let second = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        #expect(second.spaces.map(\.name) == ["Personal", "Work"])
        #expect(second.spaces[0].identity == .standard)
        // The isolated store keeps its identifier, or the saved logins are orphaned.
        #expect(second.spaces[1].identity == work.identity)
        #expect(second.spaces[1].theme == .amber)
    }

    @Test("A private space comes back private, with nothing it browsed")
    func privateSpacesRestoreEmpty() {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "kylmora-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = SessionStore(fileURL: file)
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!

        let first = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        first.addSpace(named: "Private", isPrivate: true)
        first.newTab(url: URL(string: "https://secret.example")!)
        first.saveNow()

        let written = String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self)
        #expect(!written.contains("secret.example"))

        let second = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        #expect(second.spaces.count == 2)
        #expect(second.spaces[1].isPrivate)
        // One fresh tab rather than an empty list, so the space is usable.
        #expect(second.spaces[1].tabs.count == 1)
    }

    @Test("A session saved while profiles were separate migrates")
    func legacyProfilesMigrate() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "kylmora-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let standardID = UUID()
        let workID = UUID()
        let workStore = UUID()
        let legacy = """
            {"spaces":[
              {"name":"Personal","symbolName":"person","tint":"#0091ff","tabs":[{"url":"https://a.example"}],"activeTabIndex":0,"profileID":"\(standardID)"},
              {"name":"Research","symbolName":"book","tint":"#0091ff","tabs":[{"url":"https://b.example"}],"activeTabIndex":0,"profileID":"\(standardID)"},
              {"name":"Work","symbolName":"case","tint":"#0091ff","tabs":[{"url":"https://c.example"}],"activeTabIndex":0,"profileID":"\(workID)"}
            ],"activeSpaceIndex":0,
            "profiles":[
              {"id":"\(standardID)","name":"Default","kind":{"standard":{}},"theme":"purple"},
              {"id":"\(workID)","name":"Work","kind":{"isolated":{"_0":"\(workStore)"}},"theme":"green"}
            ]}
            """
        try Data(legacy.utf8).write(to: file)

        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
        let session = BrowserSession(
            database: nil,
            sessionStore: SessionStore(fileURL: file),
            settings: Settings(defaults: defaults)
        )
        #expect(session.spaces.map(\.name) == ["Personal", "Research", "Work"])
        // The first space on the default profile keeps the default store and
        // its logins; the second one that shared it starts afresh.
        #expect(session.spaces[0].identity == .standard)
        #expect(session.spaces[1].identity != .standard)
        #expect(session.spaces[1].isPrivate == false)
        // A space with its own profile keeps that profile's store.
        #expect(session.spaces[2].identity == .isolated(workStore))
        // Colours come across from the profiles.
        #expect(session.spaces[0].theme == .purple)
        #expect(session.spaces[1].theme == .purple)
        #expect(session.spaces[2].theme == .green)
    }

    @Test("A session saved before profiles existed still restores")
    func legacySessionRestores() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "kylmora-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let legacy = """
            {"spaces":[{"name":"Personal","symbolName":"person","tint":"#0091ff",
            "tabs":[{"url":"https://example.com"}],"activeTabIndex":0}],"activeSpaceIndex":0}
            """
        try Data(legacy.utf8).write(to: file)

        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
        let session = BrowserSession(
            database: nil,
            sessionStore: SessionStore(fileURL: file),
            settings: Settings(defaults: defaults)
        )
        #expect(session.spaces.count == 1)
        #expect(session.activeSpace.tabs.count == 1)
        #expect(session.activeSpace.identity == .standard)
    }
}

@Suite("Space colours")
@MainActor
struct SpaceThemeTests {
    @Test("The neutral theme washes nothing, every other one does")
    func neutralOptsOut() {
        #expect(SpaceTheme.neutral.wash == nil)
        for theme in SpaceTheme.allCases where theme != .neutral {
            #expect(theme.wash != nil, "\(theme.title) should tint the chrome")
        }
    }

    @Test("The wash is translucent, so the material underneath survives")
    func washIsTranslucent() {
        for theme in SpaceTheme.allCases {
            guard let wash = theme.wash?.usingColorSpace(.sRGB) else { continue }
            #expect(wash.alphaComponent > 0)
            #expect(wash.alphaComponent < 0.5)
        }
    }

    @Test("An unknown stored colour restores as the default, not as a failure")
    func toleratesUnknownStoredValue() {
        #expect(SpaceTheme(storedValue: nil) == .default)
        #expect(SpaceTheme(storedValue: "chartreuse") == .default)
        #expect(SpaceTheme(storedValue: "green") == .green)
    }

    @Test("Only the first nine spaces get a switching shortcut")
    func shortcutsRunOut() {
        #expect(SpaceTheme.shortcut(forIndex: 0) == "1")
        #expect(SpaceTheme.shortcut(forIndex: 8) == "9")
        #expect(SpaceTheme.shortcut(forIndex: 9) == nil)
        #expect(SpaceTheme.shortcut(forIndex: -1) == nil)
    }

    @Test("A recolour survives a relaunch")
    func themeRoundTrips() {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "kylmora-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = SessionStore(fileURL: file)
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!

        let first = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        first.setTheme(.purple, for: first.spaces[0])
        first.saveNow()

        let second = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        #expect(second.spaces[0].theme == .purple)
    }

    @Test("Recolouring a space reports it, so every window repaints")
    func recolourReportsChange() {
        let session = TestSession.make().0
        var reported = 0
        let token = session.changes.sink { if case .spaces = $0 { reported += 1 } }
        defer { token.cancel() }

        session.setTheme(.red, for: session.activeSpace)
        #expect(reported == 1)
        // Setting the colour it already has is not a change, and repainting
        // every window for it would be a needless flicker.
        session.setTheme(.red, for: session.activeSpace)
        #expect(reported == 1)
    }
}

@Suite("Space theme picker")
@MainActor
struct SpaceThemePickerTests {
    @Test("Clicking a swatch reports the colour it stands for")
    func reportsSelection() {
        let picker = SpaceThemePicker()
        var chosen: [SpaceTheme] = []
        picker.onSelect = { chosen.append($0) }

        let swatches = UITestSupport.descendants(of: picker)
            .filter { $0.accessibilityRole() == .radioButton }
        // One swatch per fixed colour; the custom colour is a well, not a swatch.
        #expect(swatches.count == SpaceTheme.palette.count)
        #expect(UITestSupport.descendants(of: picker).contains { $0.accessibilityLabel() == "Custom colour" })

        let green = swatches.first { $0.accessibilityLabel() == SpaceTheme.green.title }
        #expect(green?.accessibilityPerformPress() == true)
        #expect(chosen == [.green])
        #expect(picker.selected == .green)
    }

    @Test("Loading a space moves the ring without reporting a choice")
    func showIsSilent() {
        let picker = SpaceThemePicker()
        var chosen: [SpaceTheme] = []
        picker.onSelect = { chosen.append($0) }

        picker.show(.orange)
        #expect(picker.selected == .orange)
        #expect(chosen.isEmpty)
    }
}

// A space's id used to be made fresh at every launch, so "Default space" --
// stored in Settings as that id -- quietly fell back to the first space on the
// next launch, and "Open external links in: Default space" went with it.

@Suite("A space keeps its identifier")
@MainActor
struct SpaceIdentifierTests {
    @Test("The id a space is given is the id it keeps")
    func theIdIsTheOneGiven() {
        let id = UUID()
        #expect(Space(id: id, name: "Work", identity: .standard).id == id)
    }

    @Test("Two spaces made without one are still told apart")
    func idsAreStillUnique() {
        #expect(Space(name: "A", identity: .standard).id != Space(name: "B", identity: .standard).id)
    }

    @Test("A saved session brings every space's id back")
    func theIdSurvivesASave() {
        let spaces = [
            Space(name: "Personal", identity: .standard),
            Space(name: "Work", identity: .makeIsolated())
        ]
        let snapshot = SessionSnapshot(
            spaces: spaces.map { SessionSnapshot.Space(id: $0.id, name: $0.name, identity: $0.identity) },
            activeSpaceIndex: 0
        )
        let data = try! JSONEncoder().encode(snapshot)
        let read = try! JSONDecoder().decode(SessionSnapshot.self, from: data)
        let restored = BrowserSession.spaces(from: read) ?? []
        #expect(restored.map(\.id) == spaces.map(\.id))
    }

    @Test("A session written before ids were saved gets new ones rather than colliding")
    func olderSessionsStillRestore() {
        let snapshot = SessionSnapshot(
            spaces: [
                SessionSnapshot.Space(name: "Personal", identity: .standard),
                SessionSnapshot.Space(name: "Work", identity: .makeIsolated())
            ],
            activeSpaceIndex: 0
        )
        let restored = BrowserSession.spaces(from: snapshot) ?? []
        #expect(restored.count == 2)
        #expect(restored[0].id != restored[1].id)
    }
}
