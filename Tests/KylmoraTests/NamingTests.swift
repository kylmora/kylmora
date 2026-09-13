import Foundation
import Testing
@testable import Kylmora

@Suite("Tab renaming")
@MainActor
struct NamingTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test("Whitespace is collapsed, not merely trimmed")
    func normalisationCollapsesWhitespace() {
        #expect(TabNaming.normalized("  Release   notes \n") == "Release notes")
        #expect(TabNaming.normalized("Docs") == "Docs")
    }

    @Test("An empty or blank value is not a name")
    func blankIsNotAName() {
        #expect(TabNaming.normalized("") == nil)
        #expect(TabNaming.normalized("   \t\n ") == nil)
    }

    @Test("A pasted paragraph is capped rather than stored whole")
    func longNamesAreCapped() {
        let name = TabNaming.normalized(String(repeating: "a", count: 500))
        #expect(name?.count == TabNaming.maximumLength)
    }

    @Test("A custom name wins over the page title")
    func customNameWins() {
        let title = TabNaming.displayTitle(
            customName: "Release notes",
            pageTitle: "(3) Pull requests · example/app",
            url: url("https://github.com/example/app/pulls")
        )
        #expect(title == "Release notes")
    }

    @Test("Without a name the ladder falls back exactly as the sidebar did")
    func fallbackLadder() {
        #expect(TabNaming.displayTitle(customName: nil, pageTitle: "Example", url: url("https://example.com")) == "Example")
        // An empty page title is not a title: WebKit reports one for a page
        // that has not set `<title>` at all.
        #expect(TabNaming.displayTitle(customName: nil, pageTitle: "", url: url("https://www.example.com")) == "example.com")
        #expect(TabNaming.displayTitle(customName: nil, pageTitle: nil, url: url("https://www.example.com/a")) == "example.com")
        #expect(TabNaming.displayTitle(customName: nil, pageTitle: nil, url: url("about:blank")) == "about:blank")
    }

    @Test("Renaming records the name and reports what happened")
    func renameStoresName() {
        let store = TabNameStore()
        let id = UUID()

        #expect(store.rename(id, to: "  Release  notes ") == .named("Release notes"))
        #expect(store.name(for: id) == "Release notes")
        // Committing the same text again is not a change, so nothing is announced.
        #expect(store.rename(id, to: "Release notes") == .unchanged)
    }

    @Test("Committing an empty field clears the name and restores the page title")
    func clearingRestoresTheTitle() {
        let store = TabNameStore()
        let id = UUID()
        store.rename(id, to: "Release notes")

        #expect(store.rename(id, to: "   ") == .cleared)
        #expect(store.name(for: id) == nil)
        #expect(
            TabNaming.displayTitle(customName: store.name(for: id), pageTitle: "Pull requests", url: url("https://github.com"))
                == "Pull requests"
        )
    }

    @Test("Clearing a tab that never had a name changes nothing")
    func clearingAnUnnamedTab() {
        let store = TabNameStore()
        #expect(store.rename(UUID(), to: "") == .unchanged)
    }

    @Test("Names are per tab, and a closed tab takes its name with it")
    func namesAreScopedToATab() {
        let store = TabNameStore()
        let first = UUID()
        let second = UUID()
        store.rename(first, to: "Work")
        store.rename(second, to: "Home")

        #expect(store.name(for: first) == "Work")
        store.forget(first)
        #expect(store.name(for: first) == nil)
        #expect(store.name(for: second) == "Home")
    }

    @Test("A restored name is taken as written, without being re-normalised")
    func restoringDoesNotRename() {
        let store = TabNameStore()
        let id = UUID()
        store.restore("Release notes", for: id)
        #expect(store.name(for: id) == "Release notes")

        store.restore(nil, for: id)
        #expect(store.isEmpty)
    }

    @Test("A rename is announced; an unchanged commit is not")
    func renameToasts() {
        #expect(Toast.rename(.named("Work"), restoredTitle: "Example")?.message == "Renamed to “Work”")
        #expect(Toast.rename(.cleared, restoredTitle: "Example")?.message == "Name cleared — showing “Example”")
        #expect(Toast.rename(.unchanged, restoredTitle: "Example") == nil)
    }
}
