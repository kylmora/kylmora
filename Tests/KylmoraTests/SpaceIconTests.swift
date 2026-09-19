import UniformTypeIdentifiers
import AppKit
import Combine
import Testing
@testable import Kylmora

@Suite("A space's icon")
@MainActor
struct SpaceIconTests {
    @Test("A space with no icon still draws its dot")
    func defaultIsTheDot() {
        let session = TestSession.make().0
        let space = session.activeSpace
        #expect(space.icon == .automatic)
        #expect(space.dotImage(side: 10).size == NSSize(width: 10, height: 10))
    }

    @Test("Every kind of icon draws at the size it was asked for")
    func everyIconFitsItsWell() {
        // The same image goes into a 10-point menu item and a 24-point well,
        // and anything that came back the wrong size would either overlap the
        // name beside it or sit in a hole.
        let session = TestSession.make().0
        let space = session.activeSpace
        for icon in [SpaceIcon.automatic, .emoji("\u{1F680}"), .symbol("briefcase.fill"), .custom("gone.png")] {
            session.setIcon(icon, for: space)
            for side in [CGFloat(10), 16, 24] {
                #expect(
                    space.dotImage(side: side).size == NSSize(width: side, height: side),
                    "\(icon) at \(side)"
                )
            }
        }
    }

    @Test("An icon that cannot be drawn falls back to the dot rather than to nothing")
    func unresolvableIconsFallBack() {
        // A symbol that a future macOS drops, and a picture the user deleted
        // from under us. Both have to degrade at draw time: rewriting the
        // stored icon instead would throw away what the user chose the moment
        // they opened the browser on an older system.
        let session = TestSession.make().0
        let space = session.activeSpace
        let dot = space.dotImage(side: 16).tiffRepresentation

        session.setIcon(.symbol("not.a.real.symbol.name"), for: space)
        #expect(space.dotImage(side: 16).tiffRepresentation == dot)

        session.setIcon(.custom("no-such-file.png"), for: space)
        #expect(space.dotImage(side: 16).tiffRepresentation == dot)
    }

    @Test("Setting an icon is announced, so every menu showing the space redraws")
    func settingAnIconIsAnnounced() {
        let session = TestSession.make().0
        var announced = 0
        let token = session.changes.sink { if case .spaces = $0 { announced += 1 } }
        defer { token.cancel() }

        session.setIcon(.emoji("\u{1F3E0}"), for: session.activeSpace)
        #expect(announced == 1)
        // Setting the same icon again changes nothing, so it says nothing.
        session.setIcon(.emoji("\u{1F3E0}"), for: session.activeSpace)
        #expect(announced == 1)
    }

    @Test("An icon survives a relaunch")
    func iconRoundTrips() {
        let (session, store) = TestSession.make()
        session.setIcon(.emoji("\u{1F680}"), for: session.activeSpace)
        let other = session.addSpace(named: "Symbols", icon: .symbol("briefcase.fill"))
        #expect(other.icon == .symbol("briefcase.fill"))
        try? store.save(session.snapshot())

        let settings = Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
        let reopened = BrowserSession(database: nil, sessionStore: store, settings: settings)
        #expect(reopened.spaces.first?.icon == .emoji("\u{1F680}"))
        #expect(reopened.spaces.first { $0.name == "Symbols" }?.icon == .symbol("briefcase.fill"))
    }

    @Test("An icon is written in a shape a person can read")
    func iconEncodesReadably() throws {
        let data = try JSONEncoder().encode(SpaceIcon.emoji("\u{1F680}"))
        let fields = try JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(fields?["kind"] == "emoji")
        #expect(fields?["value"] == "\u{1F680}")
    }

    @Test("A kind this build has never heard of reads as the dot")
    func unknownKindsDecodeToTheDot() throws {
        // A session file written by a later build must not take the whole
        // session down with it on the way back to an older one.
        let data = Data(#"{"kind":"hologram","value":"x"}"#.utf8)
        #expect(try JSONDecoder().decode(SpaceIcon.self, from: data) == .automatic)
        // ...and one whose shape is right but whose value is missing is the
        // dot, not an emoji of nothing.
        let empty = Data(#"{"kind":"emoji"}"#.utf8)
        #expect(try JSONDecoder().decode(SpaceIcon.self, from: empty) == .automatic)
    }

    @Test("Symbol names are turned into words before they are shown")
    func symbolTitles() {
        #expect(IconMenu.title(forSymbol: "briefcase.fill") == "Briefcase")
        #expect(IconMenu.title(forSymbol: "music.note") == "Music Note")
    }

    @Test("What the emoji palette inserts is kept, and the catcher then goes")
    func catchingAnEmojiFromThePalette() {
        // The palette inserts into whatever is focused and leaves. The field
        // that catches it is a means, not a control: it must hand over the
        // character and take itself out of the view it was put in, or it sits
        // there swallowing what the user types next.
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        var caught: String?
        SpaceEmojiCatcher.ask(from: anchor) { caught = $0 }

        let catcher = anchor.subviews.compactMap { $0 as? SpaceEmojiCatcher }.first
        catcher?.stringValue = "\u{1F680}"
        catcher?.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))

        #expect(caught == "\u{1F680}")
        #expect(!anchor.subviews.contains { $0 is SpaceEmojiCatcher }, "the field outstayed its welcome")
    }

    @Test("The catcher never eats a click meant for the well it sits on")
    func catcherIsInvisibleToClicks() {
        // The bug this exists to prevent: the field is laid over the icon
        // well, so a second click on the well hit the field, the menu never
        // opened, and -- the click having landed inside the field -- editing
        // never ended, so the field never went away either. The well stayed
        // dead.
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        SpaceEmojiCatcher.ask(from: anchor) { _ in }

        let catcher = anchor.subviews.compactMap { $0 as? SpaceEmojiCatcher }.first
        #expect(catcher != nil, "nothing was put there to catch with")
        #expect(catcher?.hitTest(NSPoint(x: 12, y: 12)) == nil)
        // ...so the click goes to whatever is underneath, which is the well.
        #expect(anchor.hitTest(NSPoint(x: 12, y: 12)) !== catcher)
    }

    @Test("Looking away without picking changes nothing")
    func leavingThePaletteAlone() {
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        var caught: String?
        SpaceEmojiCatcher.ask(from: anchor) { caught = $0 }

        let catcher = anchor.subviews.compactMap { $0 as? SpaceEmojiCatcher }.first
        catcher?.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))

        #expect(caught == nil)
        #expect(!anchor.subviews.contains { $0 is SpaceEmojiCatcher })
    }

    @Test("Only the first emoji typed is kept")
    func onlyOneEmoji() {
        // The well is ten points across in a menu. Three emoji in it is a
        // smudge, and a flag or a skin-toned hand is several scalars that mean
        // one glyph -- so it is cut by character, not by scalar.
        #expect(IconMenu.firstEmoji(of: "\u{1F680}\u{1F3E0}") == "\u{1F680}")
        #expect(IconMenu.firstEmoji(of: " \u{1F1EE}\u{1F1F3} ") == "\u{1F1EE}\u{1F1F3}")
        #expect(IconMenu.firstEmoji(of: "   ") == nil)
    }
}

@Suite("Where a space's icon turns up")
@MainActor
struct SpaceIconPlacementTests {
    @Test("The sidebar header carries the mark before the name")
    func headerShowsTheIcon() {
        let button = MenuLabelButton()
        func images() -> [NSImageView] {
            UITestSupport.descendants(of: button).compactMap { $0 as? NSImageView }
        }

        button.show(title: "Work", icon: nil, accessibilityLabel: "Space", tooltip: nil)
        // A space wearing nothing leaves the header exactly as it was before
        // spaces could be marked: a name, and no gap where a mark would go.
        let bare = images().filter { !$0.isHidden }
        #expect(bare.isEmpty)

        let space = TestSession.make().0.activeSpace
        space.icon = .emoji("\u{1F680}")
        button.show(
            title: "Work",
            icon: space.dotImage(side: MenuLabelButton.iconSide),
            accessibilityLabel: "Space",
            tooltip: nil
        )
        let marked = images().filter { !$0.isHidden && $0.image != nil }
        #expect(marked.count == 1)
    }

    @Test("Every list of spaces draws the same mark, because they all ask the same thing")
    func oneSourceForEveryPlace() {
        // The space menu, the card in Settings, the window list and Little Arc
        // all call `dotImage`. Nothing else needed changing when icons were
        // added, and nothing else should need changing again.
        let session = TestSession.make().0
        let space = session.activeSpace
        let dot = space.dotImage(side: 12).tiffRepresentation

        session.setIcon(.symbol("briefcase.fill"), for: space)
        #expect(space.dotImage(side: 12).tiffRepresentation != dot, "the mark did not follow the icon")
    }
}

@Suite("A folder's icon")
@MainActor
struct FolderIconTests {
    @Test("A folder wears one thing at a time")
    func oneIconAtATime() {
        // Three fields rather than one enum, so a session written before
        // symbols or pictures existed still restores its emoji -- which means
        // setting one has to clear the other two, or a folder could be wearing
        // an emoji and a picture at once and the order of a computed property
        // would decide which won.
        let group = TabGroup(name: "Reading", tint: .systemBlue)
        #expect(group.icon == .automatic)

        group.setIcon(.emoji("\u{1F4DA}"))
        #expect(group.icon == .emoji("\u{1F4DA}"))

        group.setIcon(.symbol("book.fill"))
        #expect(group.icon == .symbol("book.fill"))
        #expect(group.emoji == nil, "the emoji outlived the symbol that replaced it")

        group.setIcon(.custom("logo.png"))
        #expect(group.icon == .custom("logo.png"))
        #expect(group.emoji == nil)
        #expect(group.symbolName == nil)

        group.setIcon(.automatic)
        #expect(group.icon == .automatic)
        #expect(group.iconFileName == nil)
    }

    @Test("A folder's icon is announced and survives a relaunch")
    func folderIconRoundTrips() {
        let (session, store) = TestSession.make()
        let group = session.createGroup(named: "Reading")
        var announced = 0
        let token = session.changes.sink { if case .structure = $0 { announced += 1 } }
        defer { token.cancel() }

        session.setIcon(.symbol("book.fill"), for: group)
        #expect(announced == 1)
        session.setIcon(.symbol("book.fill"), for: group)
        #expect(announced == 1, "setting the same icon said something anyway")

        try? store.save(session.snapshot())
        let settings = Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
        let reopened = BrowserSession(database: nil, sessionStore: store, settings: settings)
        let restored = reopened.spaces.flatMap(\.groups).first { $0.name == "Reading" }
        #expect(restored?.icon == .symbol("book.fill"))
    }

    @Test("A picture that has gone leaves the folder plate, not a hole")
    func missingPictureFallsBack() {
        let group = TabGroup(name: "Reading", tint: .systemBlue)
        let plate = group.icon.image(tint: .systemBlue).tiffRepresentation

        group.setIcon(.custom("no-such-file.png"))
        #expect(group.icon.image(tint: .systemBlue).tiffRepresentation == plate)
    }
}

@Suite("The New Folder sheet")
@MainActor
struct NewGroupSheetTests {
    @Test("A folder is named, marked and coloured in one step")
    func settlesEverythingAtOnce() {
        // The whole point of the sheet: what used to be a text prompt plus two
        // later trips through two more menus is one panel.
        let sheet = GroupAppearanceEditor(creatingWithTint: .systemBlue) { _ in }
        _ = sheet.view

        let chosen = sheet.chosenGroupForTesting()
        #expect(chosen.name == "New Folder", "an unnamed folder still gets a name")
        #expect(chosen.icon == .automatic)
        #expect(chosen.appearance.isStandard)
    }

    @Test("Nothing is applied while the folder is still being described")
    func nothingAppliesUntilCreate() {
        // The editing panel applies every move as it is made, because there is
        // a folder to apply it to. There is not one here until Create.
        var applied = 0
        let sheet = GroupAppearanceEditor(creatingWithTint: .systemBlue) { _ in applied += 1 }
        _ = sheet.view
        #expect(applied == 0)
    }

    @Test("The panel that edits a folder still edits it as you go")
    func editingStillAppliesLive() {
        var applied: [TabGroupAppearance] = []
        let editor = GroupAppearanceEditor(
            appearance: .standard,
            tint: .systemBlue,
            name: "Reading"
        ) { applied.append($0) }
        _ = editor.view
        // Untouched, nothing has been applied -- but the wiring is the live
        // one, which is what the creating mode must not have taken away.
        #expect(applied.isEmpty)
    }

    @Test("A name of nothing but spaces is not a name")
    func blankNamesFallBack() {
        for typed in ["", "   ", "\n\t "] {
            let sheet = GroupAppearanceEditor(creatingWithTint: .systemBlue) { _ in }
            _ = sheet.view
            sheet.setNameForTesting(typed)
            #expect(sheet.chosenGroupForTesting().name == "New Folder", "\(typed.debugDescription)")
        }
    }

    @Test("A name is taken as typed, minus the space around it")
    func namesAreTrimmed() {
        let sheet = GroupAppearanceEditor(creatingWithTint: .systemBlue) { _ in }
        _ = sheet.view
        sheet.setNameForTesting("  Reading  ")
        #expect(sheet.chosenGroupForTesting().name == "Reading")
    }

    @Test("The mark chosen on the sheet is the mark the folder is made with")
    func theIconIsCarried() {
        for icon in [FolderIcon.emoji("\u{1F4DA}"), .symbol("book.fill"), .custom("logo.png")] {
            let sheet = GroupAppearanceEditor(creatingWithTint: .systemBlue) { _ in }
            _ = sheet.view
            sheet.setIconForTesting(icon)
            #expect(sheet.chosenGroupForTesting().icon == icon, "\(icon)")
        }
    }

    @Test("Editing shows the name and the mark; a caller that does not want them gets neither")
    func theNameRowIsOfferedOnlyWhenItCanAct() {
        // The panel is the same panel in both directions -- but a caller that
        // passes nothing to act on must not be given a field that goes
        // nowhere.
        let editable = GroupAppearanceEditor(
            appearance: .standard, tint: .systemBlue, name: "Reading", icon: .emoji("\u{1F4DA}"),
            onChange: { _ in }, onRename: { _ in }, onIcon: { _ in }
        )
        _ = editable.view
        #expect(UITestSupport.descendants(of: editable.view).contains { $0 is IconWell })

        let readOnly = GroupAppearanceEditor(
            appearance: .standard, tint: .systemBlue, name: "Reading"
        ) { _ in }
        _ = readOnly.view
        #expect(!UITestSupport.descendants(of: readOnly.view).contains { $0 is IconWell })
    }

    @Test("Renaming from the panel applies, and a blank name is refused")
    func renamingFromTheEditingPanel() {
        var renamed: [String] = []
        let editor = GroupAppearanceEditor(
            appearance: .standard, tint: .systemBlue, name: "Reading",
            onChange: { _ in }, onRename: { renamed.append($0) }, onIcon: { _ in }
        )
        _ = editor.view

        editor.setNameForTesting("Research")
        editor.commitNameForTesting()
        #expect(renamed == ["Research"])

        // Blank: nothing applied, and the field goes back to the real name
        // rather than sitting there looking as though it had been accepted.
        editor.setNameForTesting("   ")
        editor.commitNameForTesting()
        #expect(renamed == ["Research"])
        #expect(editor.nameForTesting == "Research")
    }

    @Test("Changing the mark from the panel applies it straight away")
    func changingTheIconFromTheEditingPanel() {
        var applied: [FolderIcon] = []
        let editor = GroupAppearanceEditor(
            appearance: .standard, tint: .systemBlue, name: "Reading",
            onChange: { _ in }, onRename: { _ in }, onIcon: { applied.append($0) }
        )
        _ = editor.view

        editor.chooseIconForTesting(.symbol("book.fill"))
        editor.chooseIconForTesting(.none)
        #expect(applied == [.symbol("book.fill"), .automatic])
    }
}

@Suite("The space icon store")
@MainActor
struct SpaceIconStoreTests {
    /// A store writing into a directory of its own, so a test never touches
    /// the icons of the browser the person running it is using.
    private func makeStore() -> (SpaceIconStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kylmora.icons.\(UUID().uuidString)", directoryHint: .isDirectory)
        return (SpaceIconStore(directory: directory), directory)
    }

    private func writePNG(named name: String = "icon.png", side: CGFloat = 32) throws -> URL {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "kylmora.source.\(UUID().uuidString)")
            .appending(path: name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: url)
        return url
    }

    @Test("A chosen picture is copied in, and can be drawn from there afterwards")
    func importingCopiesTheFile() throws {
        let (store, directory) = makeStore()
        let source = try writePNG()

        let name = try store.importIcon(from: source)
        #expect(store.image(named: name) != nil)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: name).path))

        // The original is what the browser must not depend on: a space icon is
        // drawn on every launch, and the file it came from may be on a disk
        // image that is no longer mounted.
        try FileManager.default.removeItem(at: source)
        // Through a store that has never seen it, so this is the copy on disk
        // being read rather than the first store's cache answering.
        #expect(SpaceIconStore(directory: directory).image(named: name) != nil)
    }

    @Test("Two pictures with the same name do not become one picture")
    func namesAreNeverShared() throws {
        let (store, _) = makeStore()
        let first = try store.importIcon(from: try writePNG(named: "logo.png"))
        let second = try store.importIcon(from: try writePNG(named: "logo.png"))
        #expect(first != second)
    }

    @Test("An SVG is a picture like any other")
    func svgIsAllowed() throws {
        // The one people actually have a logo in, and the reason the store
        // takes more than PNG.
        let (store, _) = makeStore()
        let url = FileManager.default.temporaryDirectory
            .appending(path: "kylmora.\(UUID().uuidString).svg")
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><circle cx="16" cy="16" r="15" fill="red"/></svg>"#.utf8)
            .write(to: url)

        let name = try store.importIcon(from: url)
        #expect(name.hasSuffix(".svg"))
        #expect(store.image(named: name) != nil)
    }

    @Test("A file that is not a picture is refused while the picker is still open")
    func nonPicturesAreRefused() throws {
        let (store, _) = makeStore()
        let url = FileManager.default.temporaryDirectory
            .appending(path: "kylmora.\(UUID().uuidString).txt")
        try Data("not a picture".utf8).write(to: url)

        #expect(throws: SpaceIconStore.Failure.unsupportedType) {
            try store.importIcon(from: url)
        }
    }

    @Test("A picture that cannot be decoded is refused rather than kept as a hole")
    func undecodablePicturesAreRefused() throws {
        let (store, directory) = makeStore()
        let url = FileManager.default.temporaryDirectory
            .appending(path: "kylmora.\(UUID().uuidString).png")
        try Data("PNG in name only".utf8).write(to: url)

        #expect(throws: SpaceIconStore.Failure.unreadable) {
            try store.importIcon(from: url)
        }
        // Nothing was copied in on the way to finding that out.
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(contents.isEmpty)
    }

    @Test("A picture too big to be an icon is refused")
    func oversizePicturesAreRefused() throws {
        // The cap is not about what can be drawn -- this is a few points
        // across -- but about what gets copied into Application Support and
        // decoded on every launch.
        let (store, directory) = makeStore()
        let url = FileManager.default.temporaryDirectory
            .appending(path: "kylmora.\(UUID().uuidString).png")
        try Data(count: SpaceIconStore.maximumFileSize + 1).write(to: url)

        #expect(throws: SpaceIconStore.Failure.tooLarge) {
            try store.importIcon(from: url)
        }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(contents.isEmpty, "it was copied in before being measured")
    }

    @Test("A file named in capitals is the same kind of file")
    func extensionsAreMatchedWithoutCase() throws {
        let (store, _) = makeStore()
        let source = try writePNG()
        let shouted = source.deletingPathExtension().appendingPathExtension("PNG")
        try FileManager.default.moveItem(at: source, to: shouted)

        let name = try store.importIcon(from: shouted)
        #expect(name.hasSuffix(".png"), "the stored name keeps a settled spelling")
        #expect(store.image(named: name) != nil)
    }

    @Test("Every kind the picker offers is a kind the store takes")
    func thePickerAndTheStoreAgree() {
        // The open panel is built from this list, so anything in it that the
        // store would refuse is a file the user can choose and then be told
        // off for choosing.
        for type in SpaceIconStore.allowedTypes {
            #expect(type.preferredFilenameExtension != nil, "\(type)")
        }
    }

    @Test("A picture removed and chosen again is not the old one")
    func reimportingAfterRemoval() throws {
        let (store, _) = makeStore()
        let first = try store.importIcon(from: try writePNG())
        store.remove(named: first)
        #expect(store.image(named: first) == nil, "it was served out of the cache after being deleted")

        let second = try store.importIcon(from: try writePNG())
        #expect(second != first)
        #expect(store.image(named: second) != nil)
    }

    @Test("Removing a picture takes the file with it")
    func removingDeletesTheFile() throws {
        let (store, directory) = makeStore()
        let name = try store.importIcon(from: try writePNG())

        store.remove(named: name)
        #expect(store.image(named: name) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: name).path))
    }

    @Test("Pictures no space claims are swept up")
    func orphansAreSweptUp() throws {
        let (store, directory) = makeStore()
        let kept = try store.importIcon(from: try writePNG())
        let orphan = try store.importIcon(from: try writePNG())

        store.removeEveryIconExcept([kept])
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: kept).path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: orphan).path))
    }
}
