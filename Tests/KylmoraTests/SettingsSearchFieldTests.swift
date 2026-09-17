import AppKit
import Testing
@testable import Kylmora

// The settings search box, which replaced the last stock `NSSearchField` in the
// window. Exercised as a view with no window behind it: what matters is that it
// still reports what a search field is supposed to report, since the list it
// filters is wired to nothing else.

@Suite("Settings search field")
@MainActor
struct SettingsSearchFieldTests {

    @Test("It starts empty, and says so")
    func startsEmpty() {
        let field = SettingsSearchField()
        #expect(field.text.isEmpty)
    }

    @Test("A query is reported to whatever is filtering on it")
    func reportsQueries() {
        let field = SettingsSearchField()
        var heard: [String] = []
        field.onChange = { heard.append($0) }
        field.text = "privacy"
        #expect(field.text == "privacy")
        #expect(heard == ["privacy"])
    }

    @Test("Clearing reports the empty query, so the list comes back")
    func clearingReports() {
        let field = SettingsSearchField()
        var heard: [String] = []
        field.onChange = { heard.append($0) }
        field.text = "privacy"
        field.clear()
        #expect(field.text.isEmpty)
        // The empty string is the signal that un-filters the list; a clear that
        // stayed silent would leave the spine showing one pane for ever.
        #expect(heard == ["privacy", ""])
    }

    @Test("Clearing an already-empty field says nothing")
    func clearingEmptyIsQuiet() {
        let field = SettingsSearchField()
        var heard: [String] = []
        field.onChange = { heard.append($0) }
        field.clear()
        #expect(heard.isEmpty)
    }

    @Test("Setting the same query again is not a change")
    func settingSameTextIsQuiet() {
        let field = SettingsSearchField()
        field.text = "spaces"
        var heard: [String] = []
        field.onChange = { heard.append($0) }
        field.text = "spaces"
        #expect(heard.isEmpty)
    }

    @Test("Beside the pane list it is exactly a row pill's height")
    func matchesTheRowsBelowIt() {
        let field = SettingsSearchField()
        field.layoutSubtreeIfNeeded()
        // The column reads as one stack only if the field and the pills under
        // it are the same shape; this is the constraint that says so.
        #expect(field.fittingSize.height == Style.SettingsUI.spineRowHeight)
    }

    /// The bug this guards: a field in a page header that carried the pane
    /// list's fixed 34 points could not be levelled with the pop-up and button
    /// beside it, and a search box sitting a few points shorter than its
    /// neighbours is exactly what "the search doesn't match" looked like.
    @Test("Beside the page's controls its height is only a floor, so it can be levelled")
    func controlSkinCanStretch() {
        let field = SettingsSearchField(skin: .control, placeholder: "Search shortcuts")
        let taller = NSLayoutConstraint(
            item: field, attribute: .height, relatedBy: .equal,
            toItem: nil, attribute: .notAnAttribute,
            multiplier: 1, constant: Style.SettingsUI.spineRowHeight + 8
        )
        taller.isActive = true
        field.layoutSubtreeIfNeeded()
        // A fixed height would make this unsatisfiable and AppKit would break
        // one of the two; a floor lets the neighbour's height win outright.
        #expect(field.frame.height == Style.SettingsUI.spineRowHeight + 8)
    }

    @Test("Both skins report queries the same way")
    func controlSkinReportsToo() {
        let field = SettingsSearchField(skin: .control, placeholder: "Search shortcuts")
        var heard: [String] = []
        field.onChange = { heard.append($0) }
        field.text = "tab"
        #expect(heard == ["tab"])
    }
}
