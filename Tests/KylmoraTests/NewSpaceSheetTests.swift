import AppKit
import Testing
@testable import Kylmora

// The sheet that makes a space. It settled a name, a private flag and a
// colour; everything else about the space had to be found afterwards on the
// Spaces pane, which is a strange place to send someone who is in the middle
// of making the thing.

@Suite("What the New Space sheet settles")
@MainActor
struct NewSpaceSheetTests {
    private func options(
        appearance: SpaceAppearanceChoice = .customized,
        washOpacity: Double = 1,
        showsBookmarksBar: Bool = false
    ) -> NewSpaceOptions {
        NewSpaceOptions(
            name: "Work",
            isPrivate: false,
            wash: .solid(.systemTeal),
            appearance: appearance,
            washOpacity: washOpacity,
            showsBookmarksBar: showsBookmarksBar
        )
    }

    @Test("The sheet's answers become the space's look")
    func optionsBecomeALook() {
        let look = options(
            appearance: .dark, washOpacity: 0.33, showsBookmarksBar: true
        ).look(from: SpaceLook())
        #expect(look.appearance == .dark)
        #expect(look.washOpacity == 0.33)
        #expect(look.showsBookmarksBar)
    }

    @Test("It offers the pane's choices, under the pane's names", arguments: SpaceAppearanceChoice.allCases)
    func everyChoiceIsThePanes(choice: SpaceAppearanceChoice) {
        // The sheet used to offer three of the five under shortened names, and
        // called Transparency "Colour strength". Both lists come from one type
        // now, so they cannot drift apart again.
        #expect(!choice.title.isEmpty)
        let look = options(appearance: choice).look(from: SpaceLook())
        switch choice {
        case .automatic, .light, .dark:
            #expect(look.appearance == choice.presetAppearance)
            #expect(!look.allowsWebsiteThemeColor)
        case .customized:
            #expect(look.appearance == .system)
            #expect(!look.allowsWebsiteThemeColor)
        case .website:
            #expect(look.appearance == .system)
            #expect(look.allowsWebsiteThemeColor, "the page supplies the colour")
        }
    }

    @Test("Only Customized keeps a colour of its own")
    func onlyCustomisedIsTinted() {
        // What the caller reads to decide whether the chosen wash is applied at
        // all, exactly as the pane sets `neutral` for everything else.
        for choice in SpaceAppearanceChoice.allCases {
            #expect(options(appearance: choice).keepsItsOwnColour == (choice == .customized))
        }
    }

    @Test("It changes only what it was asked about")
    func everythingElseIsLeftAlone() {
        // The colour is set through the session's own setters, because each
        // clears the other's fill; the sheet must not undo that on its way past.
        var existing = SpaceLook()
        existing.gradient = SpaceGradient(
            startHex: "#ff0000", endHex: "#0000ff", direction: .down
        )
        existing.customColorHex = "#ff0000"
        existing.isOpaqueInFullScreen = false
        existing.fonts = .webKitDefaults

        let look = options().look(from: existing)
        #expect(look.gradient == existing.gradient)
        #expect(look.customColorHex == existing.customColorHex)
        #expect(look.isOpaqueInFullScreen == false)
    }

    @Test("Its defaults are the defaults a space has anyway")
    func defaultsMatchAPlainSpace() {
        // So a person who fills in a name and presses Create gets exactly what
        // they got before these controls existed.
        let plain = SpaceLook()
        let look = options().look(from: plain)
        #expect(look == plain)
    }

    @Test("The colour rows belong to Customized, as they do on the pane")
    func colourRowsFollowTheChoice() {
        let sheet = NewSpaceSheet(suggestedColor: .systemTeal) { _ in }
        let view = sheet.view
        view.layoutSubtreeIfNeeded()

        func section(_ caption: String) -> NSView? {
            func search(_ view: NSView) -> NSView? {
                if let stack = view as? NSStackView,
                   let label = stack.arrangedSubviews.first as? NSTextField,
                   label.stringValue.caseInsensitiveCompare(caption) == .orderedSame {
                    return stack
                }
                for child in view.subviews {
                    if let found = search(child) { return found }
                }
                return nil
            }
            return search(view)
        }

        // Customized is where a new space starts: it is the only choice with a
        // colour to pick, and picking one is what the sheet is for.
        #expect(section("Fill")?.isHidden == false)
        #expect(section("Transparency")?.isHidden == false)

        sheet.chooseAppearanceForTesting(.light)
        view.layoutSubtreeIfNeeded()
        #expect(section("Fill")?.isHidden == true, "a plain window has no fill to choose")
        #expect(section("Transparency")?.isHidden == true, "and no wash to fade")
    }

    @Test("The preview says the name being typed, not a grey bar")
    func previewCarriesTheName() {
        // Two bars on a coloured card read as something that failed to load.
        let preview = ThemePreview()
        preview.frame = NSRect(x: 0, y: 0, width: 240, height: 92)
        #expect(preview.labels == nil, "a group's editor keeps the bars")

        preview.labels = ("Reading Room", "New Tab")
        #expect(preview.labels?.title == "Reading Room")
    }
}

@Suite("Five choices on one line")
@MainActor
struct SegmentedPillsWidthTests {
    private let titles = SpaceAppearanceChoice.allCases.map(\.title)

    private func laidOut(_ pills: SegmentedPills, width: CGFloat) -> SegmentedPills {
        pills.frame = NSRect(x: 0, y: 0, width: width, height: 28)
        pills.layout()
        return pills
    }

    @Test("The sheet is as wide as its widest row needs")
    func sheetFitsThePills() {
        // The card is made to fit the words, not the words squeezed into the
        // card. If a choice is ever renamed to something longer, the sheet
        // grows with it rather than clipping.
        #expect(NewSpaceSheet.width >= SegmentedPills.width(forTitles: titles) + 18 * 2)
    }

    @Test("At the sheet's width all five sit on one line, each holding its word")
    func fiveFitOnOneLine() {
        let available = NewSpaceSheet.width - 18 * 2
        let pills = laidOut(SegmentedPills(titles: titles), width: available)
        let frames = pills.segmentFramesForTesting

        #expect(Set(frames.map { $0.minY.rounded() }).count == 1, "one line")
        let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        for (title, frame) in zip(titles, frames) {
            let needed = (title as NSString).size(withAttributes: [.font: font]).width
            #expect(frame.width >= needed, "\(title) needs \(needed) and has \(frame.width)")
        }
        #expect(frames.last.map { $0.maxX <= available + 0.5 } == true, "and none runs off the card")
    }

    @Test("Drawn, every word actually reaches the screen")
    func pillsAreDrawn() {
        // Guarding a mistake already made once: the control's `draw` was
        // deleted while its layout was being rewritten, and the geometry stayed
        // perfectly correct while the sheet showed two empty rows.
        let available = NewSpaceSheet.width - 18 * 2
        let pills = laidOut(SegmentedPills(titles: titles), width: available)
        guard let rep = pills.bitmapImageRepForCachingDisplay(in: pills.bounds) else {
            Issue.record("the control should be able to draw itself offscreen")
            return
        }
        pills.cacheDisplay(in: pills.bounds, to: rep)

        // Ink anywhere across the middle of each pill, where its word is.
        let scale = CGFloat(rep.pixelsWide) / pills.bounds.width
        for (title, frame) in zip(titles, pills.segmentFramesForTesting) {
            let band = (Int(frame.minX * scale)..<Int(frame.maxX * scale))
            let inked = band.contains { x in
                (0..<rep.pixelsHigh).contains { y in
                    (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05
                }
            }
            #expect(inked, "\(title) drew nothing at all")
        }
    }

    @Test("Three short words still share the width evenly, as they always did")
    func threeShareTheWidth() {
        // The group panel's controls are unchanged: a share each, so the pills
        // read as one control rather than as three separate buttons.
        let pills = laidOut(SegmentedPills(titles: ["Auto", "Solid", "Gradient"]), width: 264)
        let widths = Set(pills.segmentFramesForTesting.map { $0.width.rounded() })
        #expect(widths.count == 1, "equal shares")
        #expect(pills.segmentFramesForTesting.last?.maxX.rounded() == 264)
    }
}

@Suite("Fill belongs to Customized")
@MainActor
struct NewSpaceFillTests {
    private func sheet() -> NewSpaceSheet {
        let sheet = NewSpaceSheet(suggestedColor: .systemTeal) { _ in }
        sheet.view.layoutSubtreeIfNeeded()
        return sheet
    }

    private func section(_ caption: String, in view: NSView) -> NSStackView? {
        if let stack = view as? NSStackView,
           let label = stack.arrangedSubviews.first as? NSTextField,
           label.stringValue.caseInsensitiveCompare(caption) == .orderedSame {
            return stack
        }
        for child in view.subviews {
            if let found = section(caption, in: child) { return found }
        }
        return nil
    }

    /// Where a section sits among its siblings, top to bottom.
    private func order(of caption: String, in sheet: NewSpaceSheet) -> Int? {
        guard let row = section(caption, in: sheet.view),
              let stack = row.superview as? NSStackView
        else { return nil }
        return stack.arrangedSubviews.firstIndex(of: row)
    }

    @Test("Fill comes after the Appearance that decides whether it shows at all")
    func fillFollowsAppearance() {
        let sheet = self.sheet()
        guard let appearance = order(of: "Appearance", in: sheet),
              let fill = order(of: "Fill", in: sheet)
        else {
            Issue.record("the sheet should have both rows")
            return
        }
        #expect(fill > appearance)
    }

    @Test("Fill offers what the pane offers: Solid or Gradient")
    func fillHasTwoChoices() {
        // It had a third, "Auto", which the pane has no notion of: a new space
        // starts on the colour the palette would have given it, so Solid on
        // that colour is the same thing under a name that already exists.
        let sheet = self.sheet()
        guard let fill = section("Fill", in: sheet.view),
              let pills = fill.arrangedSubviews.last as? SegmentedPills
        else {
            Issue.record("the Fill row should hold the pills")
            return
        }
        pills.frame = NSRect(x: 0, y: 0, width: 300, height: 28)
        pills.layout()
        #expect(pills.segmentFramesForTesting.count == 2)
    }

    @Test("A space made without touching the colours still gets one")
    func defaultFillIsTheSuggestedColour() {
        // What "Auto" used to mean, without a third pill to mean it.
        let sheet = NewSpaceSheet(suggestedColor: .systemTeal) { _ in }
        sheet.view.layoutSubtreeIfNeeded()

        guard case .solid(let colour) = sheet.chosenOptions().wash else {
            Issue.record("a new space should start on a solid colour")
            return
        }
        #expect(colour.hexString == NSColor.systemTeal.hexString)
    }
}
