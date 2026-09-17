import AppKit
import Testing
@testable import Kylmora

// The Spaces pane's list of spaces, which is a wrapping grid rather than a
// single column, and the limit on how long a space's name may be -- which is
// what makes a card's width a knowable number rather than a guess.

@Suite("The spaces grid")
@MainActor
struct SpaceGridTests {
    /// Roughly what the card has to offer at the window's opening width: the
    /// detail side less the form's gutters and the card's own padding.
    private let cardWidth: CGFloat = 600

    @Test("Three across on the pane, the way the pinned tiles wrap")
    func threeAcross() {
        let plan = SpaceGrid.plan(itemCount: 11, availableWidth: cardWidth)
        #expect(plan.columns == 3)
        #expect(plan.rows == 4, "eleven spaces are four rows of three")
    }

    @Test("Every space is on the card, with no scroller")
    func everySpaceIsPlaced() {
        // The old list was a table 130 points tall: ten spaces and the eleventh
        // was behind a scroller nobody could see.
        for count in [1, 3, 4, 11, 30] {
            let plan = SpaceGrid.plan(itemCount: count, availableWidth: cardWidth)
            #expect(plan.columns * plan.rows >= count, "\(count) spaces need \(plan.columns * plan.rows) cells")
        }
    }

    @Test("A narrow pane wraps rather than shrinking the cards away")
    func narrowPaneWraps() {
        let wide = SpaceGrid.plan(itemCount: 9, availableWidth: cardWidth)
        let narrow = SpaceGrid.plan(itemCount: 9, availableWidth: 320)
        #expect(narrow.columns < wide.columns)
        #expect(narrow.rows > wide.rows)
        #expect(narrow.cellWidth >= SpaceGrid.minimumCellWidth - 0.5)
    }

    @Test("One space does not become a card the width of the pane")
    func oneSpaceIsStillACard() {
        let plan = SpaceGrid.plan(itemCount: 1, availableWidth: cardWidth)
        #expect(plan.columns == 1)
        #expect(plan.cellWidth <= SpaceGrid.maximumCellWidth)
    }

    @Test("A card is never wider than the longest name it could ever hold")
    func cellStopsAtTheLongestName() {
        // This is the tie between the two halves of the change: the name limit
        // is what makes "wide enough" a number rather than a taste.
        let plan = SpaceGrid.plan(itemCount: 2, availableWidth: 4000)
        #expect(plan.cellWidth == SpaceGrid.maximumCellWidth)

        let longest = NSAttributedString(
            string: String(repeating: "M", count: Space.maximumNameLength),
            attributes: [.font: Style.Fonts.settingsRow]
        ).size().width
        #expect(plan.cellWidth >= longest, "the longest legal name has to fit in a card")
    }

    @Test("No width at all still returns something placeable")
    func zeroWidth() {
        // The first layout pass happens before the pane has been given a width.
        let plan = SpaceGrid.plan(itemCount: 5, availableWidth: 0)
        #expect(plan.columns == 1)
        #expect(plan.rows == 5)
        #expect(plan.height > 0)
    }
}

@Suite("How long a space's name may be")
@MainActor
struct SpaceNameLengthTests {
    @Test("A name is trimmed and cut to the limit")
    func clamped() {
        let long = String(repeating: "a", count: Space.maximumNameLength + 20)
        #expect(Space.clampName(long).count == Space.maximumNameLength)
        #expect(Space.clampName("  Work  ") == "Work")
        #expect(Space.clampName("Work") == "Work")
    }

    @Test("Counted the way a person counts characters")
    func countsGraphemes() {
        // Not UTF-16 units: a flag is one character to whoever typed it, and
        // cutting it in half produces something that is not a character at all.
        let flags = String(repeating: "\u{1F3F4}\u{200D}\u{2620}\u{FE0F}", count: Space.maximumNameLength + 5)
        #expect(Space.clampName(flags).count == Space.maximumNameLength)
    }

    @Test("Every way a space is made holds to it")
    func sessionClamps() {
        // The limit lives in the session rather than in a text field, because a
        // name also arrives from the companion iPhone and from the menu bar.
        let session = TestSession.make().0
        let long = String(repeating: "b", count: 80)
        let space = session.addSpace(named: long)
        #expect(space.name.count == Space.maximumNameLength)

        session.rename(space, to: String(repeating: "c", count: 80))
        #expect(space.name.count == Space.maximumNameLength)
    }

    @Test("A renamed space keeps its name when the new one is only whitespace")
    func renameRejectsEmpty() {
        let session = TestSession.make().0
        let space = session.addSpace(named: "Work")
        session.rename(space, to: "   ")
        #expect(space.name == "Work")
    }

    @Test("The field refuses the character past the limit")
    func formatterStopsTyping() {
        // Rather than taking a long name and quietly storing a short one.
        let formatter = LimitedLengthFormatter(limit: Space.maximumNameLength)
        let atLimit = String(repeating: "a", count: Space.maximumNameLength)
        #expect(formatter.isPartialStringValid(atLimit, newEditingString: nil, errorDescription: nil))
        #expect(!formatter.isPartialStringValid(atLimit + "a", newEditingString: nil, errorDescription: nil))
    }
}

@Suite("The Spaces pane shows its spaces as a grid")
@MainActor
struct SpacesPaneGridTests {
    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? all(type, in: $0) }
    }

    @Test("Not a one-column table")
    func paneUsesTheGrid() {
        let session = TestSession.make().0
        for name in ["Studio", "Research", "Development"] { session.addSpace(named: name) }

        let pane = SpacesSettingsViewController(session: session)
        let view = pane.view
        view.frame = NSRect(x: 0, y: 0, width: Style.SettingsUI.contentMaxWidth, height: 1400)
        view.layoutSubtreeIfNeeded()

        guard let grid = all(SpaceGridView.self, in: view).first else {
            Issue.record("the pane should show its spaces in a grid")
            return
        }
        #expect(grid.spaces.count == session.spaces.count, "every space is on the card")
        #expect(all(SpaceCardView.self, in: grid).count == session.spaces.count)
    }

    @Test("The cards are laid out in rows, not stacked in one column")
    func cardsSitSideBySide() {
        let session = TestSession.make().0
        for name in ["Studio", "Research", "Development"] { session.addSpace(named: name) }

        let pane = SpacesSettingsViewController(session: session)
        let view = pane.view
        view.frame = NSRect(x: 0, y: 0, width: Style.SettingsUI.contentMaxWidth, height: 1400)
        view.layoutSubtreeIfNeeded()

        guard let grid = all(SpaceGridView.self, in: view).first else {
            Issue.record("the pane should show its spaces in a grid")
            return
        }
        let cards = all(SpaceCardView.self, in: grid)
        #expect(cards.count == 4)
        let tops = Set(cards.map { $0.frame.minY })
        #expect(tops.count < cards.count, "cards should share rows")
    }
}

@Suite("What a card says about a space")
@MainActor
struct SpaceBadgeTests {
    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? all(type, in: $0) }
    }

    /// The chips a card is actually showing.
    private func shown(on card: SpaceCardView) -> [SpaceBadge] {
        all(SpaceBadgeView.self, in: card).filter { !$0.isHidden }.map(\.badge)
    }

    @Test("Active is the space in front, not the card you are editing")
    func activeIsNotSelected() {
        // You can stand in Personal while editing Work, and the grid has to
        // say which is which: the plate is the one you are editing, the chip
        // is the one you are browsing in.
        let session = TestSession.make().0
        let first = session.activeSpace
        let second = session.addSpace(named: "Work")
        session.selectSpace(first)

        let grid = SpaceGridView()
        grid.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        grid.show(session.spaces, selected: second, active: session.activeSpace)
        grid.layoutSubtreeIfNeeded()

        let cards = all(SpaceCardView.self, in: grid)
        #expect(cards.count == 2)
        #expect(shown(on: cards[0]) == [.active], "the space in front wears the chip")
        #expect(shown(on: cards[1]).isEmpty, "the card being edited is not the active one")
    }

    @Test("Private wears its own chip, whether or not it is active")
    func privateIsMarked() {
        let session = TestSession.make().0
        let secret = session.addSpace(named: "Secret", isPrivate: true)
        session.selectSpace(secret)

        let grid = SpaceGridView()
        grid.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        grid.show(session.spaces, selected: secret, active: session.activeSpace)
        grid.layoutSubtreeIfNeeded()

        guard let card = all(SpaceCardView.self, in: grid).first(where: {
            $0.accessibilityLabel()?.hasPrefix("Secret") == true
        }) else {
            Issue.record("the private space should be on the grid")
            return
        }
        #expect(Set(shown(on: card)) == [.active, .isPrivate])
        // Spelled out, because a letter in a box is nothing to VoiceOver.
        #expect(card.accessibilityLabel() == "Secret, active, private")
    }

    @Test("A plain space wears nothing at all")
    func plainSpaceIsBare() {
        let session = TestSession.make().0
        let other = session.addSpace(named: "Work")
        session.selectSpace(session.spaces[0])

        let grid = SpaceGridView()
        grid.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        grid.show(session.spaces, selected: other, active: session.activeSpace)
        grid.layoutSubtreeIfNeeded()

        guard let card = all(SpaceCardView.self, in: grid).first(where: {
            $0.accessibilityLabel() == "Work"
        }) else {
            Issue.record("Work should be on the grid")
            return
        }
        #expect(shown(on: card).isEmpty)
    }

    @Test("Every badge is in the key, with its word beside it")
    func keyExplainsEveryBadge() {
        // A letter in a box means nothing on its own. The key is built from
        // `allCases`, so a badge added later cannot be left out of it.
        let key = SpaceBadgeKeyView()
        key.layoutSubtreeIfNeeded()
        let chips = all(SpaceBadgeView.self, in: key).map(\.badge)
        #expect(Set(chips) == Set(SpaceBadge.allCases))
        let words = all(NSTextField.self, in: key).map(\.stringValue)
        for badge in SpaceBadge.allCases {
            #expect(words.contains(badge.title), "the key should spell out \(badge.title)")
        }
    }

    @Test("The letters tell each other apart")
    func lettersAreDistinct() {
        let letters = SpaceBadge.allCases.map(\.letter)
        #expect(Set(letters).count == letters.count)
        #expect(letters.allSatisfy { $0.count == 1 }, "a chip holds one character")
    }

    @Test("A card is wide enough for the longest name and its chips at once")
    func widthAllowsForBadges() {
        // The two halves of this have to agree: the name limit sets the width,
        // and the chips sit in the same card.
        let longest = NSAttributedString(
            string: String(repeating: "M", count: Space.maximumNameLength),
            attributes: [.font: Style.Fonts.settingsRow]
        ).size().width
        let chips = CGFloat(SpaceBadge.allCases.count) * (SpaceBadgeView.side + SpaceGrid.badgeGap)
        #expect(SpaceGrid.maximumCellWidth >= longest + chips)
    }
}
