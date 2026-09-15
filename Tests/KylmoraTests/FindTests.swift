import Testing
import WebKit
import AppKit
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

    @Test("Toggling regex mode invalidates the previous search outcome")
    func regexToggleInvalidates() {
        var state = FindState()
        state.setQuery("func.*\\(")
        state.record(matchFound: true)
        #expect(state.outcome == .found)

        state.isRegex = true
        #expect(state.outcome == .pending)
        #expect(state.isRegex == true)
    }

    @Test("Invalid regex expression is reported with failing status")
    func invalidRegexReporting() {
        var state = FindState()
        state.setQuery("[unclosed-bracket")
        state.isRegex = true
        state.recordInvalidRegex("Invalid regex")

        #expect(state.outcome == .invalidRegex(message: "Invalid regex"))
        #expect(state.isFailing == true)
        #expect(state.statusMessage == "Invalid regex")
    }

    @Test("Match counts and active index stepping format cleanly")
    func matchCountingAndStepping() {
        var state = FindState()
        state.setQuery("test")
        state.record(matchFound: true, current: 1, total: 5, positions: [0.1, 0.3, 0.5, 0.7, 0.9])

        #expect(state.currentMatchIndex == 1)
        #expect(state.totalMatches == 5)
        #expect(state.statusMessage == "1 of 5")
        #expect(state.matchPositions.count == 5)

        // Step forward
        let next = state.stepMatch(direction: .forward)
        #expect(next == 2)
        #expect(state.statusMessage == "2 of 5")

        // Step backward from 2 goes to 1
        let prev = state.stepMatch(direction: .backward)
        #expect(prev == 1)
        #expect(state.statusMessage == "1 of 5")

        // Step backward from 1 wraps to 5
        let wrapped = state.stepMatch(direction: .backward)
        #expect(wrapped == 5)
        #expect(state.statusMessage == "5 of 5")
    }

    @Test("Zero matches with total count records not found")
    func zeroMatchesWithCount() {
        var state = FindState()
        state.setQuery("missing")
        state.record(matchFound: false, current: 0, total: 0, positions: [])

        #expect(state.isFailing == true)
        #expect(state.statusMessage == "Not found")
        #expect(state.matchPositions.isEmpty)
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
        let configuration = WKFindConfiguration()
        #expect(configuration.backwards == false)
        #expect(configuration.caseSensitive == false)
        #expect(configuration.wraps == true)
    }
}

@Suite("Scrollbar match highlights")
@MainActor
struct FindScrollbarMarksViewTests {
    @Test("Initial state is hidden with no positions")
    func initialState() {
        let ruler = FindScrollbarMarksView(frame: NSRect(x: 0, y: 0, width: 12, height: 600))
        #expect(ruler.positions.isEmpty)
        #expect(ruler.activeIndex == 0)
    }

    @Test("Updating positions unhides and updates internal data")
    func updatePositions() {
        let ruler = FindScrollbarMarksView(frame: NSRect(x: 0, y: 0, width: 12, height: 600))
        ruler.update(positions: [0.15, 0.45, 0.85], activeIndex: 2)

        #expect(ruler.positions.count == 3)
        #expect(ruler.activeIndex == 2)
        #expect(ruler.isHidden == false)

        ruler.clear()
        #expect(ruler.positions.isEmpty)
        #expect(ruler.activeIndex == 0)
        #expect(ruler.isHidden == true)
    }
}
