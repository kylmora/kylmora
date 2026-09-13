import Testing
import WebKit
@testable import Kylmora

@Suite("Find state")
@MainActor
struct FindStateTests {
    @Test("A fresh find has nothing to repeat and nothing to say")
    func initiallyEmpty() {
        let state = FindState()
        #expect(state.query.isEmpty)
        #expect(state.canRepeat == false)
        #expect(state.statusMessage == nil)
        #expect(state.isFailing == false)
    }

    @Test("Typing a term asks for a search; retyping the same term does not")
    func queryChanges() {
        var state = FindState()
        #expect(state.setQuery("webkit") == true)
        #expect(state.setQuery("webkit") == false)
        #expect(state.canRepeat)
    }

    @Test("Clearing the field asks for no search and leaves nothing to repeat")
    func emptyQuery() {
        var state = FindState()
        state.setQuery("webkit")
        #expect(state.setQuery("") == false)
        #expect(state.canRepeat == false)
    }

    @Test("A new term invalidates the previous answer")
    func newQueryClearsOutcome() {
        var state = FindState()
        state.setQuery("webkit")
        state.record(matchFound: false)
        #expect(state.isFailing)
        state.setQuery("webkitten")
        #expect(state.outcome == .pending)
        #expect(state.statusMessage == nil)
    }

    @Test("A failed search says so")
    func notFound() {
        var state = FindState()
        state.setQuery("webkit")
        state.record(matchFound: false)
        #expect(state.statusMessage == "Not found")
        #expect(state.isFailing)
    }

    @Test("A successful search claims no count, because WebKit reports none")
    func foundClaimsNothing() {
        var state = FindState()
        state.setQuery("webkit")
        state.record(matchFound: true)
        #expect(state.statusMessage == nil)
        #expect(state.isFailing == false)
    }

    @Test("Changing case sensitivity invalidates the answer it was found under")
    func caseToggleInvalidates() {
        var state = FindState()
        state.setQuery("WebKit")
        state.record(matchFound: true)
        state.matchesCase = true
        #expect(state.outcome == .pending)
        // Setting it to the value it already had changes nothing.
        state.record(matchFound: true)
        state.matchesCase = true
        #expect(state.outcome == .found)
    }

    @Test("Closing the bar keeps the term so Cmd-G still has something to repeat")
    func clearOutcomeKeepsQuery() {
        var state = FindState()
        state.setQuery("webkit")
        state.record(matchFound: true)
        state.clearOutcome()
        #expect(state.query == "webkit")
        #expect(state.canRepeat)
        #expect(state.statusMessage == nil)
    }
}

@Suite("Find configuration")
@MainActor
struct FindConfigurationTests {
    @Test("Direction maps to WebKit's backwards flag")
    func direction() {
        let state = FindState()
        #expect(state.configuration(for: .forward).backwards == false)
        #expect(state.configuration(for: .backward).backwards == true)
    }

    @Test("The Aa toggle is WebKit's caseSensitive flag and nothing else")
    func caseSensitivity() {
        var state = FindState()
        #expect(state.configuration(for: .forward).caseSensitive == false)
        state.matchesCase = true
        #expect(state.configuration(for: .forward).caseSensitive == true)
        #expect(state.configuration(for: .backward).caseSensitive == true)
    }

    @Test("Searching always wraps, in both directions")
    func wrapping() {
        var state = FindState()
        state.matchesCase = true
        #expect(state.configuration(for: .forward).wraps == true)
        #expect(state.configuration(for: .backward).wraps == true)
    }

    @Test("WebKit's own defaults are the ones this design assumes")
    func webKitDefaults() {
        // If a future WebKit changed these, the find bar would silently start
        // behaving differently, so the assumption is pinned here.
        let configuration = WKFindConfiguration()
        #expect(configuration.backwards == false)
        #expect(configuration.caseSensitive == false)
        #expect(configuration.wraps == true)
    }
}
