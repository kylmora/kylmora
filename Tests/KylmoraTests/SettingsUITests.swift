import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("The Settings rail")
@MainActor
struct SettingsRailTests {
    @Test("Every pane gets a row")
    func everyPaneHasARow() {
        let rail = SettingsSpineView()
        for pane in SettingsWindowController.Pane.allCases {
            #expect(rail.row(for: pane) != nil, "no row for \(pane.title)")
        }
    }

    @Test("Choosing a pane marks one row and unmarks the rest")
    func selectionIsExclusive() {
        let rail = SettingsSpineView()
        rail.select(.privacy)
        #expect(rail.isChosen(.privacy))
        rail.select(.about)
        #expect(rail.isChosen(.about))
        #expect(!rail.isChosen(.privacy))
    }

    @Test("The panes are in group order, so a heading is never repeated")
    func groupsAreContiguous() {
        // The rail draws a heading whenever the group changes. If the panes
        // were not sorted by group, "Privacy" would appear twice and the
        // headings would stop meaning anything.
        var seen: [SettingsWindowController.PaneGroup] = []
        for pane in SettingsWindowController.Pane.allCases where seen.last != pane.group {
            #expect(!seen.contains(where: { $0 == pane.group }), "\(pane.group.title) appears twice")
            seen.append(pane.group)
        }
    }

    @Test("Every pane names a symbol the system actually has")
    func symbolsExist() {
        // A missing symbol is an empty square in the rail, and nothing in the
        // build says so.
        for pane in SettingsWindowController.Pane.allCases {
            #expect(
                NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: nil) != nil,
                "\(pane.title) has no symbol \(pane.symbolName)"
            )
        }
    }

    @Test("Every pane says what it is for")
    func subtitlesArePresent() {
        for pane in SettingsWindowController.Pane.allCases {
            #expect(!pane.subtitle.isEmpty, "\(pane.title) has no subtitle")
            #expect(pane.subtitle.hasSuffix("."), "\(pane.title)'s subtitle is not a sentence")
        }
    }
}

@Suite("Settings rows")
@MainActor
struct SettingsFormTests {
    /// The toggles a form built, in the order it built them.
    private func switches(in view: NSView) -> [SettingsToggle] {
        view.subviews.flatMap { ($0 as? SettingsToggle).map { [$0] } ?? switches(in: $0) }
    }

    @Test("A checkbox is drawn as a switch, and its title becomes the label")
    func checkboxesBecomeSwitches() {
        let form = SettingsForm()
        let checkbox = NSButton(checkboxWithTitle: "Open safe files", target: nil, action: nil)
        form.addContinuation(checkbox)
        form.layoutSubtreeIfNeeded()
        #expect(switches(in: form).count == 1)
    }

    @Test("Setting the checkbox moves the switch, so a pane's reload still works")
    func switchFollowsTheCheckbox() {
        // Every pane sets `state` directly in `reload()`. The switch is only a
        // face for the checkbox, so it has to follow one that it never saw
        // being changed.
        let form = SettingsForm()
        let checkbox = NSButton(checkboxWithTitle: "Sync bookmarks", target: nil, action: nil)
        form.addContinuation(checkbox)
        guard let control = switches(in: form).first else {
            Issue.record("no switch was built")
            return
        }
        #expect(control.isOn == false)
        checkbox.state = .on
        #expect(control.isOn)
        checkbox.state = .off
        #expect(control.isOn == false)
    }

    @Test("A disabled checkbox disables its switch")
    func switchFollowsEnablement() {
        let form = SettingsForm()
        let checkbox = NSButton(checkboxWithTitle: "Use Touch ID", target: nil, action: nil)
        form.addContinuation(checkbox)
        guard let control = switches(in: form).first else {
            Issue.record("no switch was built")
            return
        }
        checkbox.isEnabled = false
        #expect(!control.isEnabled)
    }

    @Test("Flipping the switch tells the pane, exactly once")
    func flippingSendsTheAction() {
        let target = ActionCounter()
        let form = SettingsForm()
        let checkbox = NSButton(checkboxWithTitle: "Block ads", target: target, action: #selector(ActionCounter.fire))
        form.addContinuation(checkbox)
        guard let control = switches(in: form).first else {
            Issue.record("no switch was built")
            return
        }
        // Pressing the toggle is what a user does; it flips itself and then
        // tells the checkbox, which is the model.
        _ = control.accessibilityPerformPress()
        #expect(checkbox.state == .on, "the checkbox is the model and must carry the new state")
        #expect(target.count == 1)
    }

    @Test("A read-only value settles at the control width")
    func filledControlsShareAWidth() {
        // Written when every filled control was a plate at one width. A pop-up
        // is a dropdown now, sized to the longest option it has to show, and a
        // field you type into takes the whole row -- so the shared column is
        // what is left: the read-only values.
        let box = SettingsForm.fill(NSTextField(labelWithString: "WebKit"))
        box.layoutSubtreeIfNeeded()
        #expect(box.fittingSize.width == Style.SettingsUI.controlWidth)
    }

    @MainActor
    final class ActionCounter: NSObject {
        var count = 0
        @objc func fire() { count += 1 }
    }
}

@Suite("Settings cards")
@MainActor
struct SettingsCardTests {
    private func hairlines(in view: NSView) -> [SettingsHairlineView] {
        view.subviews.flatMap { ($0 as? SettingsHairlineView).map { [$0] } ?? hairlines(in: $0) }
    }

    @Test("Rows are divided from each other, and the first needs no divider")
    func hairlinesSitBetweenRows() {
        let card = SettingsCardView(rows: [row(), row(), row()])
        card.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        card.layoutSubtreeIfNeeded()
        let lines = hairlines(in: card)
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { !$0.isHidden })
    }

    @Test("A hidden row takes its divider with it")
    func hiddenRowsHideTheirHairline() {
        // Spaces folds whole groups of rows away. A divider left behind would
        // draw a line across a card with nothing on either side of it.
        let rows = [row(), row()]
        let card = SettingsCardView(rows: rows)
        card.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        rows[1].isHidden = true
        card.needsLayout = true
        card.layoutSubtreeIfNeeded()
        #expect(hairlines(in: card).allSatisfy { $0.isHiddenOrHasHiddenAncestor })
    }

    @Test("A card with every row hidden leaves no empty plate behind")
    func emptyCardHidesItself() {
        let rows = [row(), row()]
        let card = SettingsCardView(rows: rows)
        card.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        for row in rows { row.isHidden = true }
        card.needsLayout = true
        card.layoutSubtreeIfNeeded()
        #expect(card.isHidden)
    }

    @Test("A note is not divided from the control it explains")
    func notesAreAttached() {
        let form = SettingsForm()
        form.addRow("Homepage", NSTextField())
        form.addNote("Where the home button goes.")
        form.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        form.needsLayout = true
        form.layoutSubtreeIfNeeded()
        #expect(hairlines(in: form).allSatisfy { $0.isHiddenOrHasHiddenAncestor })
    }

    @Test("A separator starts a new card rather than drawing a line")
    func separatorsSplitCards() {
        let form = SettingsForm()
        form.addRow("One", NSTextField())
        form.addSeparator()
        form.addRow("Two", NSTextField())
        form.layoutSubtreeIfNeeded()
        let cards = form.subviews.flatMap(\.subviews).compactMap { $0 as? SettingsCardView }
        #expect(cards.count == 2)
    }

    private func row() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return row
    }
}

@Suite("Settings tiles")
@MainActor
struct SettingsTileTests {
    @Test("A tile is square at whatever size it is asked for")
    func tilesAreSquare() {
        let tile = SettingsSwitchRow.tileView(.symbol("hand.raised.fill", .systemRed), side: 28)
        #expect(tile.fittingSize == NSSize(width: 28, height: 28))
    }

    @Test("The switch carries the row's name, because it is what VoiceOver flips")
    func theControlIsNamed() {
        let control = NSSwitch()
        _ = SettingsSwitchRow(tile: .emoji("\u{1F36A}", .systemOrange), title: "Block cookie banners", control: control)
        #expect(control.accessibilityLabel() == "Block cookie banners")
    }
}

@Suite("Searching the settings")
@MainActor
struct SettingsSearchTests {
    @Test("An empty search shows everything")
    func emptySearchMatchesAll() {
        #expect(SettingsWindowController.Pane.allCases.allSatisfy { $0.matches("") })
        #expect(SettingsWindowController.Pane.allCases.allSatisfy { $0.matches("   ") })
    }

    @Test("What you type is the thing you want changed, not the heading it lives under", arguments: [
        ("cookies", SettingsWindowController.Pane.privacy),
        ("dark", .general),
        ("keyboard", .shortcuts),
        ("icloud", .sync),
        ("camera", .websites),
        ("gradient", .spaces)
    ])
    func termsFindTheirPane(term: String, expected: SettingsWindowController.Pane) {
        let matches = SettingsWindowController.Pane.allCases.filter { $0.matches(term) }
        #expect(matches.contains(expected), "\(term) did not find \(expected.title)")
    }

    @Test("Searching is case-insensitive and matches a pane's own name")
    func nameMatchesAnyCase() {
        #expect(SettingsWindowController.Pane.privacy.matches("PRIVACY"))
        #expect(SettingsWindowController.Pane.privacy.matches("priv"))
    }

    @Test("A search that finds nothing finds nothing, rather than everything")
    func nonsenseMatchesNothing() {
        let matches = SettingsWindowController.Pane.allCases.filter { $0.matches("zzzqqq") }
        #expect(matches.isEmpty)
    }

    @Test("Filtering the rail hides the rows and the headings left empty")
    func railHidesEmptyGroups() {
        let rail = SettingsSpineView()
        rail.show([.privacy])
        #expect(rail.row(for: .privacy)?.isHidden == false)
        #expect(rail.row(for: .general)?.isHidden == true)
    }
}

@Suite("The spine's colours")
@MainActor
struct SettingsAccentTests {
    @Test("No two panes share a hue")
    func accentsAreDistinct() {
        // The spine drops the labels, so the colour is doing the work a name
        // used to. Two panes the same colour is two panes with no name.
        let accents = SettingsWindowController.Pane.allCases.map(\.accent)
        let described = accents.map { colour -> String in
            let rgb = colour.usingColorSpace(.sRGB) ?? colour
            return String(format: "%.2f %.2f %.2f", rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        }
        #expect(Set(described).count == described.count)
    }

    @Test("Neighbouring tiles are far enough apart to tell apart")
    func neighboursAreDistinguishable() {
        // Adjacent tiles are the pair most often compared, so they are the pair
        // that has to survive a glance.
        let panes = SettingsWindowController.Pane.allCases
        for (first, second) in zip(panes, panes.dropFirst()) {
            let a = first.accent.usingColorSpace(.sRGB)!
            let b = second.accent.usingColorSpace(.sRGB)!
            let distance = abs(a.redComponent - b.redComponent)
                + abs(a.greenComponent - b.greenComponent)
                + abs(a.blueComponent - b.blueComponent)
            #expect(distance > 0.12, "\(first.title) and \(second.title) are too close")
        }
    }

    @Test("Every tile is reachable and named for VoiceOver, which has no colour")
    func tilesAreNamed() {
        let spine = SettingsSpineView()
        for pane in SettingsWindowController.Pane.allCases {
            #expect(spine.row(for: pane)?.accessibilityLabel() == pane.title)
        }
    }
}

@Suite("The Settings window opens")
@MainActor
struct SettingsWindowTests {
    private func make() -> SettingsWindowController {
        SettingsWindowController(
            session: TestSession.make().0,
            settings: Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
        )
    }

    @Test("The window has a content view with real size")
    func windowHasContent() {
        let controller = make()
        guard let window = controller.window, let content = window.contentView else {
            Issue.record("no window")
            return
        }
        content.layoutSubtreeIfNeeded()
        #expect(window.frame.width > 400)
        #expect(content.bounds.width > 400, "content collapsed to \(content.bounds.width)")
        #expect(content.bounds.height > 300, "content collapsed to \(content.bounds.height)")
    }

    @Test("The spine and the page both got room")
    func partsAreLaidOut() {
        let controller = make()
        guard let content = controller.window?.contentView else {
            Issue.record("no window")
            return
        }
        content.layoutSubtreeIfNeeded()
        let spine = content.subviews.compactMap { $0 as? SettingsSpineView }.first
        #expect(spine != nil, "no spine in the window")
        #expect(spine?.bounds.width == Style.SettingsUI.spineWidth)
        #expect(spine?.bounds.height ?? 0 > 100, "spine has no height")
        let scrolls = content.subviews.compactMap { $0 as? NSScrollView }
        #expect(scrolls.contains { $0.bounds.width > 300 }, "the page got no width")
    }

    @Test("Showing the window puts it on screen, at a size you can use")
    func showingPutsItOnScreen() {
        // "I cannot open Settings" looks exactly like a window that opened
        // off-screen, or one clamped to nothing.
        let controller = make()
        controller.showWindow(nil)
        guard let window = controller.window else {
            Issue.record("no window")
            return
        }
        #expect(window.isVisible)
        #expect(window.frame.width >= window.minSize.width)
        #expect(window.frame.height >= window.minSize.height)
        if let screen = NSScreen.main {
            #expect(
                window.frame.intersects(screen.visibleFrame),
                "window at \(window.frame) is off \(screen.visibleFrame)"
            )
        }
        window.close()
    }

    @Test("A pane is actually installed in the page")
    func aPaneIsShown() {
        let controller = make()
        guard let content = controller.window?.contentView else {
            Issue.record("no window")
            return
        }
        content.layoutSubtreeIfNeeded()
        // Walk down to whatever the pane put in: if nothing is installed the
        // window opens onto an empty canvas, which is what "I can't open
        // Settings" looks like from the outside.
        func hasForm(_ view: NSView) -> Bool {
            if view is SettingsForm { return true }
            return view.subviews.contains(where: hasForm)
        }
        #expect(hasForm(content), "no pane was installed")
    }
}

@Suite("A window left collapsed recovers")
@MainActor
struct SettingsWindowRecoveryTests {
    @Test("A saved frame smaller than the floor is thrown away, not restored")
    func collapsedFrameIsDiscarded() {
        // A window that cannot be seen cannot be dragged back out, so a bad
        // saved frame would be permanent.
        let defaults = UserDefaults.standard
        let key = "NSWindow Frame KylmoraSettings"
        let saved = defaults.string(forKey: key)
        defaults.set("0 0 120 80 0 0 1440 900 ", forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        let controller = SettingsWindowController(
            session: TestSession.make().0,
            settings: Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
        )
        guard let window = controller.window else {
            Issue.record("no window")
            return
        }
        #expect(window.frame.width >= window.minSize.width)
        #expect(window.frame.height >= window.minSize.height)
    }
}

@Suite("Drawing settles")
@MainActor
struct SettingsDrawLoopTests {
    /// Every view this window draws itself, anywhere in a built pane.
    ///
    /// Collected by walking the real thing rather than by listing the classes
    /// by hand. The hand-written list is how this bug shipped twice: the first
    /// time the card dirtied itself while drawing, and the list was updated to
    /// include cards; the second time the control plate did it, and the list
    /// had never heard of control plates.
    private func ourViews(in view: NSView) -> [NSView] {
        let mine = view is SettingsPlateView
            || view is SettingsFormRow
            || view is SettingsCanvasView
            || view is SettingsToggle
            || view is SettingsHairlineView
        return (mine ? [view] : []) + view.subviews.flatMap(ourViews(in:))
    }

    @Test("A full draw leaves nothing asking to be drawn again", arguments: SettingsWindowController.Pane.allCases)
    func drawingSettles(pane: SettingsWindowController.Pane) {
        // A view that dirties itself from inside its own draw spins the main
        // thread at a hundred per cent, and the window never finishes opening.
        // That is what "I cannot open Settings" looks like from the outside.
        let controller = SettingsWindowController(
            session: TestSession.make().0,
            settings: Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
        )
        controller.select(pane)
        guard let content = controller.window?.contentView else {
            Issue.record("no window")
            return
        }
        content.layoutSubtreeIfNeeded()

        // Drawn repeatedly, because one extra pass is not a bug -- a view may
        // legitimately invalidate itself once as the window settles. A loop is
        // a view that is still dirty however many times it has been drawn, and
        // that is what pegs the main thread.
        var dirty: [NSView] = []
        for _ in 0..<6 {
            content.display()
            dirty = ourViews(in: content).filter(\.needsDisplay)
            if dirty.isEmpty { break }
        }
        #expect(
            dirty.isEmpty,
            "\(pane.title): \(dirty.map { "\(type(of: $0))" }.joined(separator: ", ")) never stops asking to be drawn"
        )
    }

    @Test("Laying out does not ask to be laid out again", arguments: SettingsWindowController.Pane.allCases)
    func layoutSettles(pane: SettingsWindowController.Pane) {
        let controller = SettingsWindowController(
            session: TestSession.make().0,
            settings: Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
        )
        controller.select(pane)
        guard let content = controller.window?.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let pending = ourViews(in: content).filter(\.needsLayout)
        #expect(
            pending.isEmpty,
            "\(pane.title): \(pending.map { "\(type(of: $0))" }.joined(separator: ", ")) asked for another layout"
        )
    }
}

@Suite("Every pane lays out")
@MainActor
struct SettingsPaneLayoutTests {
    private func controller() -> SettingsWindowController {
        SettingsWindowController(
            session: TestSession.make().0,
            settings: Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
        )
    }

    /// The view a pane installed, laid out at the width it really gets.
    private func paneView(_ pane: SettingsWindowController.Pane, in controller: SettingsWindowController) -> NSView? {
        controller.select(pane)
        guard let content = controller.window?.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        func installed(_ view: NSView) -> NSView? {
            if view is SettingsForm || view is SettingsScrollingPane { return view }
            for child in view.subviews {
                if let found = installed(child) { return found }
            }
            return nil
        }
        return installed(content)
    }

    @Test("No pane's content spills out of the width it was given", arguments: SettingsWindowController.Pane.allCases)
    func contentFitsItsWidth(pane: SettingsWindowController.Pane) {
        // "The UI is totally broken" looks like this from the inside: a row
        // wider than the card it is in, running off the side of the window.
        let controller = controller()
        guard let view = paneView(pane, in: controller) else { return }
        let width = view.bounds.width
        guard width > 0 else {
            Issue.record("\(pane.title) was given no width")
            return
        }
        func overflow(_ view: NSView, limit: CGFloat) -> NSView? {
            for child in view.subviews where !child.isHidden {
                // Four points of slack. A stack view positions its children by
                // alignment rect, and an `NSTextField`'s frame sits two points
                // outside that on each side -- every label in the window is
                // "overflowing" by two points and always has been. Anything
                // genuinely broken is out by tens.
                if child.frame.maxX > limit + 4 { return child }
                // Stop at a control's own edge. What AppKit does inside one is
                // Apple's business, and on macOS 26 an `NSColorWell` draws its
                // press highlight through SwiftUI, in a layer deliberately
                // larger than and offset from the view hosting it. That is not
                // this window's layout, and the runner's OS version should not
                // decide whether these tests pass.
                if child is NSControl { continue }
                if let found = overflow(child, limit: child.bounds.width) { return found }
            }
            return nil
        }
        let spilled = overflow(view, limit: width)
        #expect(spilled == nil, "\(pane.title): \(spilled.map { "\(type(of: $0)) at \($0.frame)" } ?? "")")
    }

    @Test("No pane is empty or collapsed", arguments: SettingsWindowController.Pane.allCases)
    func paneHasHeight(pane: SettingsWindowController.Pane) {
        let controller = controller()
        guard let view = paneView(pane, in: controller) else { return }
        #expect(view.fittingSize.height > 40, "\(pane.title) laid out to nothing")
    }
}

@Suite("No stock AppKit chrome survives")
@MainActor
struct SettingsControlSkinTests {
    private func form(for pane: SettingsWindowController.Pane) -> NSView? {
        let controller = SettingsWindowController(
            session: TestSession.make().0,
            settings: Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
        )
        controller.select(pane)
        guard let content = controller.window?.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        func installed(_ view: NSView) -> NSView? {
            if view is SettingsForm || view is SettingsScrollingPane { return view }
            for child in view.subviews { if let found = installed(child) { return found } }
            return nil
        }
        return installed(content)
    }

    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? all(type, in: $0) }
    }

    @Test("No system pop-up ever draws itself", arguments: SettingsWindowController.Pane.allCases)
    func noVisiblePopUps(pane: SettingsWindowController.Pane) {
        // The grey bezel that hides its options behind a click is the most
        // recognisably Apple thing on a form. Every pop-up here is transparent
        // inside one of our dropdowns: it draws nothing and only catches the
        // click, so what is on screen is ours and what opens is AppKit's.
        guard let form = form(for: pane) else { return }
        for popUp in all(NSPopUpButton.self, in: form) {
            let isBehindOurDropdown = popUp.isTransparent
                && popUp.superview is SettingsChoiceControl
            let isDressed = !popUp.isBordered && popUp.enclosingControlPlate != nil
            #expect(
                isBehindOurDropdown || isDressed,
                "\(pane.title): a system pop-up is visible with \(popUp.numberOfItems) items"
            )
        }
    }

    @Test("A dropdown wears our chrome and keeps the pane's own menu")
    func choicesAreOurOwnDropdowns() {
        let popUp = NSPopUpButton()
        popUp.addItems(withTitles: ["Never", "After a day", "After a week"])
        let target = ChoiceCounter()
        popUp.target = target
        popUp.action = #selector(ChoiceCounter.fire)

        let form = SettingsForm()
        form.addRow("Archive", SettingsForm.fill(popUp))
        form.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        form.layoutSubtreeIfNeeded()

        let choices = all(SettingsChoiceControl.self, in: form)
        #expect(choices.count == 1)
        guard let choice = choices.first else { return }
        // The menu, its items, its target and its action are untouched: what
        // drops down when you click is the pane's own.
        #expect(popUp.superview === choice)
        #expect(popUp.numberOfItems == 3)
        #expect(popUp.target === target)
        // Transparent, not hidden. A hidden button takes no clicks, and the
        // click is the one thing we hand back to AppKit.
        #expect(popUp.isTransparent)
        #expect(!popUp.isHidden)
        #expect(popUp.frame.size == choice.frame.size, "the pop-up must catch the whole plate")

        // What the dropdown says is what the pop-up holds, pane-set selection
        // included -- there is no notification for it, so it is read on draw.
        let title = all(NSTextField.self, in: choice).first
        #expect(title?.stringValue == "Never")
        popUp.selectItem(at: 2)
        choice.viewWillDraw()
        #expect(title?.stringValue == "After a week")
    }

    @Test("A paragraph runs the width of the card, not the control column")
    func paragraphsFillTheRow() {
        // The About pane used to pin its paragraphs to the width of the control
        // column, which left two thirds of the card empty beside every line.
        let paragraph = NSTextField(
            wrappingLabelWithString: String(repeating: "a paragraph of real length ", count: 12)
        )
        let form = SettingsForm()
        form.addRow("About us", paragraph, alignment: .top)
        form.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        form.layoutSubtreeIfNeeded()

        // A text field's frame sits about two points outside its alignment
        // rect on each side, so the full width measures a little over.
        let full = 600 - Style.SettingsUI.cardPadding * 2
        #expect(
            abs(paragraph.frame.width - full) <= 5,
            "the paragraph is \(paragraph.frame.width) wide in a card with \(full) to give"
        )
    }

    @Test("The About pane's own paragraphs run the width of their cards")
    func aboutParagraphsFillTheirCards() {
        // The synthetic row above proves the rule; this proves the pane the
        // screenshot came from actually gets it.
        guard let form = form(for: .about) else { return }
        form.layoutSubtreeIfNeeded()
        let paragraphs = all(NSTextField.self, in: form).filter { $0.stringValue.count > 200 }
        #expect(paragraphs.count >= 3, "the About pane should have its three paragraphs")
        for paragraph in paragraphs {
            #expect(
                paragraph.frame.width > form.frame.width - 60,
                "a paragraph is \(paragraph.frame.width) wide in a pane \(form.frame.width) across"
            )
        }
    }

    @Test("A note with nothing above it is not given a card of its own")
    func lonelyNotesStayOffCards() {
        // The sync pane closes on a line of small print after a separator. In a
        // card it became a plate with text jammed against its top edge and a
        // band of empty below -- a box that looked broken because it was one.
        let form = SettingsForm()
        form.addRow("Backup", NSButton(title: "Export", target: nil, action: nil))
        form.addSeparator()
        let lonely = form.addNote("Zero-account architecture: nothing leaves your iCloud account.")
        form.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        form.layoutSubtreeIfNeeded()

        #expect(all(SettingsCardView.self, in: form).count == 1, "the note must not open a second card")
        #expect(lonely.enclosingCard == nil, "and must not be inside the first one")

        // Inside a card a note still tucks tight under the control it explains.
        let attached = SettingsForm()
        attached.addRow("Backup", NSButton(title: "Export", target: nil, action: nil))
        let tucked = attached.addNote("Restores the whole sidebar.")
        attached.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        attached.layoutSubtreeIfNeeded()
        #expect(tucked.enclosingCard != nil)
    }

    @Test("The shortcuts pane's header controls never draw over each other")
    func shortcutsHeaderDoesNotOverlap() {
        // A segmented control given less width than it needs does not shrink:
        // it draws over its neighbour. "Restore All Defaults" and "Appearance"
        // were printed on top of one another.
        let pane = ShortcutsSettingsViewController()
        let view = pane.view
        view.frame = NSRect(x: 0, y: 0, width: Style.SettingsUI.contentMaxWidth, height: 900)
        view.layoutSubtreeIfNeeded()

        guard let header = all(NSStackView.self, in: view).first else {
            Issue.record("the pane should lay its header out in a stack")
            return
        }
        let boxes = header.arrangedSubviews.filter { !$0.isHidden }.map(\.frame)
        #expect(boxes.count >= 3)
        for (first, second) in boxes.enumerated().flatMap({ index, box in
            boxes.dropFirst(index + 1).map { (box, $0) }
        }) {
            #expect(!first.intersects(second), "\(first) overlaps \(second)")
        }
    }

    @Test("The shortcuts list passes the wheel on to the page")
    func shortcutsTableDoesNotSwallowTheWheel() {
        // The table has no scroller of its own, but a scroll view takes the
        // wheel anyway: it handles the event, finds nowhere to go, and stops
        // there -- so the shortcuts list would not scroll at all.
        final class Catcher: NSView {
            var caught = 0
            override func scrollWheel(with event: NSEvent) { caught += 1 }
        }

        let pane = ShortcutsSettingsViewController()
        let view = pane.view
        view.layoutSubtreeIfNeeded()
        guard let scroller = all(NSTableView.self, in: view).first?.enclosingScrollView else {
            Issue.record("the pane should hold its table in a scroll view")
            return
        }

        let catcher = Catcher()
        catcher.addSubview(scroller)
        guard let wheel = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: -40,
            wheel2: 0,
            wheel3: 0
        ).flatMap(NSEvent.init(cgEvent:)) else {
            Issue.record("could not make a scroll event")
            return
        }
        scroller.scrollWheel(with: wheel)
        #expect(catcher.caught == 1, "the wheel must reach the view behind the table")
    }

    @Test("The websites pane's tables stand at their own height, with no scrollers of their own")
    func websitesTablesAreNotWindowsOntoEmptyRows() {
        // The sites table was tied to the height of the category list beside
        // it: one configured website, then three hundred points of empty
        // banded rows underneath it.
        let pane = WebsitesSettingsViewController()
        let view = pane.view
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 900)
        view.layoutSubtreeIfNeeded()

        let tables = all(NSTableView.self, in: view)
        #expect(tables.count == 2, "the categories and the configured sites")
        for table in tables {
            guard let scroller = table.enclosingScrollView else {
                Issue.record("a table with no scroll view around it")
                continue
            }
            #expect(!scroller.hasVerticalScroller, "the detail side is the only thing that scrolls")
            #expect(scroller is PassingScrollView, "and the wheel must reach it")
            #expect(!table.usesAlternatingRowBackgroundColors, "banding on rows that are not there")
            let rows = CGFloat(table.numberOfRows) * (table.rowHeight + table.intercellSpacing.height)
            #expect(
                scroller.frame.height <= rows + 100,
                "a table \(scroller.frame.height) tall holding \(rows) of rows"
            )
        }
    }

    @Test("Only one row in the spine is ever lit")
    func spineRowsDoNotStayHovered() {
        // Enter and exit do not come in pairs: a row the pointer leaves while
        // the app is in the background is never told, and after a few switches
        // half the list looked selected at once.
        let controller = SettingsWindowController(
            session: TestSession.make().0,
            settings: Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
        )
        controller.select(.general)
        guard let content = controller.window?.contentView else { return }
        content.layoutSubtreeIfNeeded()

        let rows = SettingsWindowController.Pane.allCases.compactMap { controller.spineRow(for: $0) }
        #expect(rows.count == SettingsWindowController.Pane.allCases.count)

        // Light every one of them the way a missed exit would.
        for row in rows { row.mouseEntered(with: NSEvent()) }
        // The window is not key in a test, so every row should put itself out.
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        content.layoutSubtreeIfNeeded()

        let lit = rows.filter(\.isLit)
        #expect(lit.isEmpty, "\(lit.count) rows left lit with no pointer on them")
    }

    @Test("Every pane begins in the same place", arguments: SettingsWindowController.Pane.allCases)
    func panesShareTheirMargins(pane: SettingsWindowController.Pane) {
        // Measured rather than declared. Each pane used to set its own insets
        // -- twenty here, eight there, ten more under a hero -- so no two
        // panes started at quite the same place and the window looked untidy
        // without it being obvious why.
        let controller = SettingsWindowController(
            session: TestSession.make().0,
            settings: Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
        )
        controller.window?.setContentSize(NSSize(width: 1000, height: 800))
        controller.select(pane)
        guard let content = controller.window?.contentView, let root = controller.shownPaneView else {
            Issue.record("\(pane.title): the pane did not open")
            return
        }
        content.layoutSubtreeIfNeeded()

        func visible(_ view: NSView) -> [NSView] {
            if view is SettingsCardView || view is NSTableView || view is SettingsPlateView
                || view is NSSearchField || view is NSTextField || view is NSImageView {
                return [view]
            }
            return view.subviews.flatMap(visible)
        }
        let boxes = visible(root)
            .filter { !$0.isHidden && $0.frame.width > 20 && $0.frame.height > 4 }
            .map { $0.convert($0.bounds, to: content) }
        guard let union = boxes.dropFirst().reduce(boxes.first, { $0?.union($1) }) else {
            Issue.record("\(pane.title): nothing on the pane to measure")
            return
        }

        let gutter = Style.SettingsUI.detailGutter
        #expect(
            abs(union.minX - Style.SettingsUI.spineWidth - gutter) <= 1,
            "\(pane.title) starts \(union.minX - Style.SettingsUI.spineWidth) from the spine"
        )
        #expect(
            abs(content.bounds.width - union.maxX - gutter) <= 1,
            "\(pane.title) ends \(content.bounds.width - union.maxX) from the edge"
        )
        // Measured from the page itself, so the test says what the rule is
        // rather than restating how the titlebar and the eyebrow add up.
        guard let page = root.enclosingScrollView else {
            Issue.record("\(pane.title): the pane is not on the scrolling page")
            return
        }
        let pageTop = page.convert(page.bounds, to: content).minY
        #expect(
            abs(union.minY - pageTop - Style.SettingsUI.paneTopGap) <= 1,
            "\(pane.title) begins \(union.minY - pageTop) below the page, not \(Style.SettingsUI.paneTopGap)"
        )
    }

    @Test("Anything under its label runs the width of the card", arguments: SettingsWindowController.Pane.allCases)
    func stackedControlsFillTheirRows(pane: SettingsWindowController.Pane) {
        // A control put under its label is a thing in its own right -- a list,
        // a paragraph, a field for a URL -- and it takes the width of the card.
        // The Spaces list stopped two thirds of the way across, so its selected
        // row ended in the middle of the card with dead space beside it.
        let controller = SettingsWindowController(
            session: TestSession.make().0,
            settings: Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
        )
        controller.window?.setContentSize(NSSize(width: 1000, height: 900))
        controller.select(pane)
        guard let content = controller.window?.contentView else { return }
        content.layoutSubtreeIfNeeded()

        for card in all(SettingsCardView.self, in: content) {
            let inner = card.frame.width - Style.SettingsUI.cardPadding * 2
            for table in all(NSTableView.self, in: card) {
                guard let list = table.enclosingScrollView else { continue }
                let width = list.convert(list.bounds, to: card).width
                #expect(
                    width >= inner - 2,
                    "\(pane.title): a list \(width) wide on a card with \(inner) to give"
                )
            }
        }
    }

    @Test("A control a pane hides takes its dressing with it")
    func hiddenControlsHideTheirPlates() {
        // Sync hides "Reset" while the location is the default one, About hides
        // "Download" until there is something to download. The pane knows
        // nothing about the plate around its button, so the plate stayed on the
        // card as an empty rounded box.
        let button = NSButton(title: "Reset", target: nil, action: nil)
        let plate = SettingsControlPlate(button, width: nil)
        #expect(!plate.isHidden)
        button.isHidden = true
        #expect(plate.isHidden, "the plate must go where its button goes")
        button.isHidden = false
        #expect(!plate.isHidden, "and come back with it")

        let popUp = NSPopUpButton()
        popUp.addItems(withTitles: ["One", "Two"])
        let choice = SettingsForm.fill(popUp)
        popUp.isHidden = true
        #expect(choice.isHidden)

        let segmented = NSSegmentedControl(
            labels: ["Solid", "Gradient"], trackingMode: .selectOne, target: nil, action: nil
        )
        let segments = SettingsForm.fill(segmented)
        #expect(!segments.isHidden, "the model is kept off screen without hiding it")
        segmented.isHidden = true
        #expect(segments.isHidden)
    }

    @Test("A light window has three surfaces you can tell apart")
    func lightModeHasContrast() {
        // The light palette had the ground at 0.96, the card at 0.975 and a
        // field at 0.99: three shades of white within three per cent of each
        // other, so nothing had an edge and every field vanished into its card.
        func brightness(_ colour: NSColor, over ground: CGFloat) -> CGFloat {
            guard let srgb = colour.usingColorSpace(.sRGB) else { return ground }
            let alpha = srgb.alphaComponent
            let white = srgb.brightnessComponent
            return white * alpha + ground * (1 - alpha)
        }

        var canvas: CGFloat = 0, card: CGFloat = 0, control: CGFloat = 0
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            canvas = brightness(Style.Colors.settingsCanvas, over: 1)
            card = brightness(Style.Colors.settingsGlass, over: canvas)
            control = brightness(Style.Colors.settingsControl, over: card)
        }
        #expect(card - canvas > 0.03, "a card at \(card) on a ground at \(canvas)")
        #expect(card - control > 0.02, "a control at \(control) in a card at \(card)")
    }

    @Test("A selected row keeps its own text colour")
    func selectedRowsDoNotGoWhite() {
        // AppKit hands a cell white text when the row says the selection is
        // emphasised. Over our own pale plate that made the selected category
        // in a light window disappear the moment you chose it.
        #expect(SettingsTableRow().interiorBackgroundStyle == .normal)
    }

    @Test("A list is never dressed as a control")
    func listsAreNotPlated() {
        // The Spaces list was handed to `fill`, which plates a control and pins
        // it to the control column: four spaces in a bezelled box 280 points
        // wide, a card inside a card, with the rest of the row empty.
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")))
        let scroller = NSScrollView()
        scroller.documentView = table

        #expect(SettingsForm.fill(scroller) === scroller, "a list must come back as itself")

        let form = SettingsForm()
        form.addRow("Spaces", scroller, alignment: .top)
        form.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        form.layoutSubtreeIfNeeded()
        #expect(scroller.enclosingControlPlate == nil, "and must not end up on a plate")
        #expect(
            scroller.frame.width > Style.SettingsUI.controlWidth,
            "a list \(scroller.frame.width) wide is still in the control column"
        )
    }

    @Test("Every list in the window wears our own selection", arguments: SettingsWindowController.Pane.allCases)
    func listsUseOurSelection(pane: SettingsWindowController.Pane) {
        // AppKit's selection is a grey slab edge to edge, and it greys out
        // again the moment the list loses focus.
        let controller = SettingsWindowController(
            session: TestSession.make().0,
            settings: Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
        )
        controller.select(pane)
        guard let content = controller.window?.contentView else { return }
        content.layoutSubtreeIfNeeded()

        for table in all(NSTableView.self, in: content) where table.numberOfRows > 0 {
            let row = table.delegate?.tableView?(table, rowViewForRow: 0)
            #expect(row is SettingsTableRow, "\(pane.title): a list with AppKit's own selection")
        }
    }

    @Test("A wide pane gets the whole detail side, a form keeps its reading width")
    func widePanesAreNotHeldToTheReadingWidth() {
        let controller = SettingsWindowController(
            session: TestSession.make().0,
            settings: Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
        )
        controller.window?.setContentSize(NSSize(width: 1200, height: 800))
        controller.select(.shortcuts)
        guard let content = controller.window?.contentView else { return }
        content.layoutSubtreeIfNeeded()

        let cap = Style.SettingsUI.contentMaxWidth
        // Found through the table itself: `all` stops recursing at the first
        // view of the type it wants, and the detail side's own scroll view
        // would be the one it stopped at.
        guard let table = all(NSTableView.self, in: content).first?.enclosingScrollView else {
            Issue.record("the shortcuts pane should be showing its table")
            return
        }
        #expect(
            table.frame.width > cap,
            "the table is \(table.frame.width) wide in a window with far more to give"
        )

        // The cap is lifted for the table, not abandoned: a form still reads at
        // one column however wide the window is pulled.
        controller.select(.general)
        content.layoutSubtreeIfNeeded()
        let cards = all(SettingsCardView.self, in: content)
        #expect(!cards.isEmpty)
        for card in cards {
            #expect(card.frame.width <= cap + 1, "a card is \(card.frame.width) wide")
        }
    }

    @Test("The shortcuts table has no scroller of its own")
    func shortcutsTableDoesNotScrollInsideTheScroller() {
        // The detail side already scrolls. A second scroll view inside it made
        // a short window onto a long list with empty pane underneath.
        let pane = ShortcutsSettingsViewController()
        let view = pane.view
        view.frame = NSRect(x: 0, y: 0, width: Style.SettingsUI.contentMaxWidth, height: 900)
        view.layoutSubtreeIfNeeded()

        guard let scroller = all(NSScrollView.self, in: view).first,
              let table = scroller.documentView as? NSTableView
        else {
            Issue.record("the pane should hold its table in a scroll view")
            return
        }
        #expect(!scroller.hasVerticalScroller)
        let rows = CGFloat(table.numberOfRows) * (table.rowHeight + table.intercellSpacing.height)
        #expect(table.numberOfRows > 10, "there should be plenty of shortcuts to show")
        #expect(
            scroller.frame.height >= rows,
            "the table is \(scroller.frame.height) tall for \(rows) of rows"
        )
    }

    @Test("A control a pane put in its own stack is dressed, not lost")
    func skinnedStackKeepsItsControls() {
        // "Set Default..." went missing this way: it was dressed in a plate,
        // and then taken straight back out of it, leaving an empty plate and a
        // row that said Kylmora was not the default browser with no way to
        // change it.
        let message = NSTextField(labelWithString: "Kylmora is not your default web browser.")
        let button = NSButton(title: "Set Default\u{2026}", target: nil, action: nil)
        let popUp = NSPopUpButton()
        popUp.addItems(withTitles: ["Personal", "Work"])

        let form = SettingsForm()
        form.addRow("Default browser", [message, button])
        form.addRow("Default space", [popUp, NSButton(title: "Manage", target: nil, action: nil)])
        form.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        form.layoutSubtreeIfNeeded()

        #expect(button.enclosingControlPlate != nil, "the button must be dressed in our own surface")
        #expect(all(NSButton.self, in: form).contains(button), "the button must still be on screen")
        #expect(button.frame.width > 0, "and must have been given a size")

        let choices = all(SettingsChoiceControl.self, in: form)
        #expect(choices.count == 1, "the pop-up inside the pane's own stack is a dropdown too")
        #expect(popUp.superview === choices.first)
    }

    @Test("A pop-up whose options arrive later is still a dropdown")
    func emptyMenusBecomeDropdownsToo() {
        // The Websites pane builds its pop-up empty and fills it when a
        // category is chosen. Refused as a dropdown, it kept the system bezel
        // inside one of our plates -- two chevrons side by side, and a plate
        // that stretched to the height of the card.
        let popUp = NSPopUpButton()
        let dressed = SettingsForm.fill(popUp)
        #expect(dressed is SettingsChoiceControl)

        popUp.addItems(withTitles: ["50%", "100%", "150%"])
        popUp.selectItem(at: 1)
        dressed.layoutSubtreeIfNeeded()
        dressed.viewWillDraw()

        let title = all(NSTextField.self, in: dressed).first
        #expect(title?.stringValue == "100%", "the dropdown must catch up with its menu")
        #expect(dressed.fittingSize.height <= 40, "a dropdown is one control tall")
    }

    @Test("A long menu is a dropdown too")
    func longMenusAreDropdownsAsWell() {
        // The list that drops is AppKit's, so length is its problem, not ours.
        let popUp = NSPopUpButton()
        popUp.addItems(withTitles: (1...20).map { "Option \($0)" })
        let form = SettingsForm()
        form.addRow("Many", SettingsForm.fill(popUp))
        form.layoutSubtreeIfNeeded()
        #expect(all(SettingsChoiceControl.self, in: form).count == 1)
        #expect(popUp.numberOfItems == 20)
    }

    @MainActor
    final class ChoiceCounter: NSObject {
        var count = 0
        @objc func fire() { count += 1 }
    }

    @Test("No system switch is left anywhere", arguments: SettingsWindowController.Pane.allCases)
    func noSystemSwitches(pane: SettingsWindowController.Pane) {
        // `NSSwitch` paints itself in the user's macOS accent, which is how a
        // window built from the space's palette grows a magenta control.
        guard let form = form(for: pane) else { return }
        #expect(all(NSSwitch.self, in: form).isEmpty, "\(pane.title) still has a system switch")
    }

    @Test("A toggle takes the pane's colour, not the system's")
    func togglesWearThePaneColour() {
        let form = SettingsForm()
        form.addContinuation(NSButton(checkboxWithTitle: "Block ads", target: nil, action: nil))
        form.accent = SettingsWindowController.Pane.privacy.accent
        let toggles = all(SettingsToggle.self, in: form)
        #expect(toggles.count == 1)
        #expect(toggles.first?.tint == SettingsWindowController.Pane.privacy.accent)
    }
}


@Suite("The Settings window's own appearance")
@MainActor
struct SettingsWindowAppearanceTests {
    private func make() -> (SettingsWindowController, Settings) {
        let settings = Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
        return (SettingsWindowController(session: TestSession.make().0, settings: settings), settings)
    }

    @Test("Automatic by default, so the window follows the application")
    func automaticByDefault() {
        let (controller, settings) = make()
        #expect(settings.settingsWindowAppearance == .system)
        #expect(controller.window?.appearance == nil, "no override until one is chosen")
        #expect(controller.spineRow(for: .general) != nil)
    }

    @Test("Choosing dark or light sets the window, not the application", arguments: [
        AppearancePreference.dark, .light
    ])
    func choiceSetsTheWindow(preference: AppearancePreference) {
        let (controller, settings) = make()
        let before = NSApp.appearance
        settings.settingsWindowAppearance = preference
        controller.applyAppearance()
        #expect(controller.window?.appearance?.name == preference.appearanceName)
        #expect(NSApp.appearance == before, "the application's appearance is the General pane's business")
        // Back to Automatic lifts the override rather than pinning the
        // current system look.
        settings.settingsWindowAppearance = .system
        controller.applyAppearance()
        #expect(controller.window?.appearance == nil)
    }

    @Test("The choice survives a relaunch")
    func choicePersists() {
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
        Settings(defaults: defaults).settingsWindowAppearance = .dark
        #expect(Settings(defaults: defaults).settingsWindowAppearance == .dark)
    }
}
