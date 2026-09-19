import AppKit
import Combine
import Testing
@testable import Kylmora

/// Every kind of icon against every kind of icon, for both things that can
/// wear one.
///
/// The interesting bugs in this feature are not in any single case -- they are
/// in the moves *between* cases. A picture replaced by an emoji has to delete
/// a file; a folder given a symbol has to forget the emoji it had; a space
/// restored from a session file has to come back wearing what it wore. Each of
/// those is one cell of a small grid, and a grid is worth walking.
@Suite("Icons, every way round", .serialized)
@MainActor
struct IconPermutationTests {
    /// The four shapes an icon can take, as values a test can loop over.
    private static let spaceIcons: [SpaceIcon] = [
        .automatic, .emoji("\u{1F680}"), .symbol("briefcase.fill"), .custom("picture.png")
    ]
    private static let folderIcons: [FolderIcon] = [
        .automatic, .emoji("\u{1F4DA}"), .symbol("book.fill"), .custom("picture.png")
    ]

    // MARK: - Storage

    @Test("A space icon survives being written and read back, whatever it is")
    func everySpaceIconRoundTripsThroughJSON() throws {
        for icon in Self.spaceIcons {
            let data = try JSONEncoder().encode(icon)
            #expect(try JSONDecoder().decode(SpaceIcon.self, from: data) == icon, "\(icon)")
        }
    }

    @Test("A space icon of every kind survives a relaunch")
    func everySpaceIconRoundTripsThroughTheSessionFile() {
        let (session, store) = TestSession.make()
        var expected: [String: SpaceIcon] = [:]
        for (index, icon) in Self.spaceIcons.enumerated() {
            let name = "Space \(index)"
            let space = index == 0 ? session.activeSpace : session.addSpace(named: name)
            if index == 0 { session.rename(space, to: name) }
            session.setIcon(icon, for: space)
            expected[name] = icon
        }
        try? store.save(session.snapshot())

        let settings = Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
        let reopened = BrowserSession(database: nil, sessionStore: store, settings: settings)
        for (name, icon) in expected {
            #expect(reopened.spaces.first { $0.name == name }?.icon == icon, "\(name)")
        }
    }

    @Test("A folder icon of every kind survives a relaunch")
    func everyFolderIconRoundTripsThroughTheSessionFile() {
        let (session, store) = TestSession.make()
        var expected: [String: FolderIcon] = [:]
        for (index, icon) in Self.folderIcons.enumerated() {
            let name = "Folder \(index)"
            let group = session.createGroup(named: name)
            session.setIcon(icon, for: group)
            expected[name] = icon
        }
        try? store.save(session.snapshot())

        let settings = Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
        let reopened = BrowserSession(database: nil, sessionStore: store, settings: settings)
        let groups = reopened.spaces.flatMap(\.groups)
        for (name, icon) in expected {
            #expect(groups.first { $0.name == name }?.icon == icon, "\(name)")
        }
    }

    @Test("A folder ends up wearing exactly one thing, whatever it wore before")
    func everyFolderTransitionLeavesOneField() {
        // The three fields are separate so an old session file still restores
        // its emoji, which means every move between kinds has to clear the two
        // it is not. Sixteen moves; all sixteen have to leave one field set.
        for from in Self.folderIcons {
            for to in Self.folderIcons {
                let group = TabGroup(name: "Folder", tint: .systemBlue)
                group.setIcon(from)
                group.setIcon(to)
                #expect(group.icon == to, "\(from) -> \(to)")

                let set = [group.emoji, group.symbolName, group.iconFileName].compactMap { $0 }
                #expect(set.count == (to == .automatic ? 0 : 1), "\(from) -> \(to) left \(set)")
            }
        }
    }

    // MARK: - Drawing

    @Test("Every icon draws at the size it was asked for, for a space and for a folder")
    func everyIconFillsItsWell() {
        let space = TestSession.make().0.activeSpace
        for icon in Self.spaceIcons {
            space.icon = icon
            for side in [CGFloat(10), 14, 16, 24, 28] {
                #expect(
                    space.dotImage(side: side).size == NSSize(width: side, height: side),
                    "\(icon) at \(side)"
                )
            }
        }
        for icon in Self.folderIcons {
            let drawn = icon.image(tint: .systemBlue)
            #expect(drawn.size == NSSize(width: FolderIcon.side, height: FolderIcon.side), "\(icon)")
        }
    }

    @Test("An icon nothing can draw falls back, rather than leaving a hole")
    func unresolvableIconsFallBack() throws {
        // A symbol a future macOS drops, and a picture the user deleted from
        // under us. Both degrade at draw time so the stored choice survives.
        //
        // Inside a store of its own because setting an icon over a picture
        // deletes that picture, and a test must never be able to reach into
        // the icons of the browser the person running it is using.
        try withTemporaryIconStore { _, _ in
        let session = TestSession.make().0
        let space = session.activeSpace
        let dot = space.dotImage(side: 16).tiffRepresentation
        for broken in [SpaceIcon.symbol("not.a.real.symbol"), .custom("gone.png"), .emoji("")] {
            session.setIcon(broken, for: space)
            #expect(space.dotImage(side: 16).tiffRepresentation == dot, "\(broken)")
        }

        let group = TabGroup(name: "Folder", tint: .systemBlue)
        let plate = group.icon.image(tint: .systemBlue).tiffRepresentation
        for broken in [FolderIcon.symbol("not.a.real.symbol"), .custom("gone.png"), .emoji("")] {
            group.setIcon(broken)
            #expect(group.icon.image(tint: .systemBlue).tiffRepresentation == plate, "\(broken)")
        }
        }
    }

    @Test("The well says what it is showing, for every kind")
    func theWellDescribesItself() {
        #expect(IconWell.describe(IconMenu.Current()) == "No icon")
        #expect(IconWell.describe(IconMenu.Current(emoji: "\u{1F680}")) == "\u{1F680}")
        #expect(IconWell.describe(IconMenu.Current(symbol: "briefcase.fill")) == "Briefcase")
        #expect(IconWell.describe(IconMenu.Current(isCustom: true)) == "Custom image")
    }

    @Test("The header's mark comes and goes as the icon does")
    func theHeaderMarkTogglesBothWays() {
        // Two constraints swap as the mark appears and disappears. Going one
        // way is half a test: it is the second switch that would break if both
        // were ever active at once.
        let button = MenuLabelButton()
        func marks() -> [NSImageView] {
            UITestSupport.descendants(of: button)
                .compactMap { $0 as? NSImageView }
                .filter { !$0.isHidden }
        }
        let mark = SpaceIcon.emoji("\u{1F680}").image(color: .systemBlue, title: "Work", side: 16)

        button.show(title: "Work", icon: nil, accessibilityLabel: "Space", tooltip: nil)
        #expect(marks().isEmpty)
        button.show(title: "Work", icon: mark, accessibilityLabel: "Space", tooltip: nil)
        #expect(marks().count == 1)
        button.show(title: "Work", icon: nil, accessibilityLabel: "Space", tooltip: nil)
        #expect(marks().isEmpty)
        button.show(title: "Work", icon: mark, accessibilityLabel: "Space", tooltip: nil)
        #expect(marks().count == 1)
        button.layoutSubtreeIfNeeded()
    }

    // MARK: - The menu

    @Test("The menu and the icons agree about what is chosen, both ways round")
    func choicesMapBothWays() {
        // The menu deals in `Choice` so one menu can serve both icons. Each
        // icon has to be able to say what it is in those terms and to come
        // back from them unchanged, or a tick lands on the wrong item and a
        // choice comes back as something else.
        for icon in Self.spaceIcons {
            #expect(SpaceIcon(icon.asChoiceForTesting) == icon, "\(icon)")
        }
        for icon in Self.folderIcons {
            #expect(FolderIcon(icon.asChoiceForTestingSupport) == icon, "\(icon)")
        }
    }

    @Test("What the thing wears now is what the menu ticks")
    func theMenuTicksWhatIsWorn() {
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        for icon in Self.spaceIcons {
            let items = IconMenu.items(
                current: icon.asMenuChoice,
                color: .systemBlue,
                symbols: ["briefcase.fill", "book.fill"],
                anchor: anchor
            ) { _ in }

            let emoji = items.first { $0.title.hasSuffix("Emoji\u{2026}") }
            let picture = items.first { $0.title == "Choose Image\u{2026}" }
            let remove = items.first { $0.title == "Remove Icon" }
            let symbols = items.first { $0.title == "Symbol" }?.submenu?.items ?? []

            switch icon {
            case .automatic:
                #expect(emoji?.state == .off)
                #expect(picture?.state == .off)
                #expect(symbols.allSatisfy { $0.state == .off })
                // Nothing to remove, so the item is there but inert: a menu
                // whose items come and go is one you cannot learn.
                #expect(remove?.isEnabled == false)
            case .emoji:
                #expect(emoji?.state == .on)
                #expect(emoji?.title == "Change Emoji\u{2026}")
                #expect(remove?.isEnabled == true)
            case .symbol(let name):
                #expect(symbols.first { $0.state == .on }?.title == IconMenu.title(forSymbol: name))
                #expect(remove?.isEnabled == true)
            case .custom:
                #expect(picture?.state == .on)
                #expect(remove?.isEnabled == true)
            }
        }
    }

    @Test("Every symbol the menu offers is a symbol that exists")
    func suggestedSymbolsResolve() {
        // An unresolvable name falls back to the dot at draw time, which would
        // make the menu offer a dozen identical dots and say nothing about it.
        for name in SpaceIcon.suggestedSymbols {
            #expect(
                NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                "\(name) is not an SF Symbol"
            )
            #expect(!IconMenu.title(forSymbol: name).isEmpty)
        }
    }

    @Test("Anything typed or pasted comes down to one glyph, or to nothing")
    func emojiAreCutToOneGlyph() {
        #expect(IconMenu.firstEmoji(of: "\u{1F680}") == "\u{1F680}")
        #expect(IconMenu.firstEmoji(of: "\u{1F680}\u{1F3E0}\u{1F4DA}") == "\u{1F680}")
        // Several scalars that mean one glyph stay whole: a flag, a skin-toned
        // hand, a family. Cutting by scalar would turn each into a different
        // emoji, or into half of one.
        #expect(IconMenu.firstEmoji(of: "\u{1F1EE}\u{1F1F3}") == "\u{1F1EE}\u{1F1F3}")
        #expect(IconMenu.firstEmoji(of: "\u{1F44D}\u{1F3FD}") == "\u{1F44D}\u{1F3FD}")
        #expect(IconMenu.firstEmoji(of: "  \u{1F680}  ") == "\u{1F680}")
        // Not an emoji, but not nothing either: whatever the palette inserted
        // is what the user asked for.
        #expect(IconMenu.firstEmoji(of: "abc") == "a")
        #expect(IconMenu.firstEmoji(of: "") == nil)
        #expect(IconMenu.firstEmoji(of: "   \n ") == nil)
    }

    @Test("Symbol names are turned into words")
    func symbolTitles() {
        #expect(IconMenu.title(forSymbol: "briefcase.fill") == "Briefcase")
        #expect(IconMenu.title(forSymbol: "music.note") == "Music Note")
        #expect(IconMenu.title(forSymbol: "gamecontroller.fill") == "Gamecontroller")
    }

    // MARK: - The files behind a picture

    @Test("Replacing a picture with anything else takes the file with it")
    func replacingAPictureDeletesIt() throws {
        try withTemporaryIconStore { store, directory in
            let session = TestSession.make().0
            let space = session.activeSpace

            for replacement in Self.spaceIcons {
                let name = try store.importIcon(from: try writePNG())
                session.setIcon(.custom(name), for: space)
                #expect(FileManager.default.fileExists(atPath: directory.appending(path: name).path))

                session.setIcon(replacement, for: space)
                let stillThere = FileManager.default.fileExists(atPath: directory.appending(path: name).path)
                if case .custom = replacement {
                    // Replaced by the same name it already had: nothing moved,
                    // so nothing may be deleted. This is the cell of the grid
                    // that deletes the picture it is about to draw.
                    #expect(space.icon == .custom("picture.png"))
                } else {
                    #expect(!stillThere, "replaced by \(replacement) and the file stayed")
                }
                session.setIcon(.automatic, for: space)
            }
        }
    }

    @Test("A picture is kept when the icon is set to the very same picture")
    func settingTheSamePictureKeepsIt() throws {
        try withTemporaryIconStore { store, directory in
            let session = TestSession.make().0
            let space = session.activeSpace
            let name = try store.importIcon(from: try writePNG())

            session.setIcon(.custom(name), for: space)
            session.setIcon(.custom(name), for: space)
            #expect(FileManager.default.fileExists(atPath: directory.appending(path: name).path))
            #expect(space.icon == .custom(name))
        }
    }

    @Test("Deleting a space or a folder takes its picture with it")
    func deletingTheWearerDeletesThePicture() throws {
        try withTemporaryIconStore { store, directory in
            let session = TestSession.make().0
            let spaceName = try store.importIcon(from: try writePNG())
            let folderName = try store.importIcon(from: try writePNG())

            let space = session.addSpace(named: "Going")
            session.setIcon(.custom(spaceName), for: space)
            let group = session.createGroup(named: "Going too")
            session.setIcon(.custom(folderName), for: group)

            _ = session.removeGroup(group)
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: folderName).path))

            session.removeSpace(space)
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: spaceName).path))
        }
    }

    @Test("A folder's picture and a space's picture live in the same place")
    func bothReadFromOneStore() throws {
        try withTemporaryIconStore { store, _ in
            let name = try store.importIcon(from: try writePNG())
            let space = TestSession.make().0.activeSpace
            space.icon = .custom(name)
            let group = TabGroup(name: "Folder", tint: .systemBlue)
            group.setIcon(.custom(name))

            // Both draw something, and neither draws the fallback.
            let dot = SpaceTheme.dotImage(color: space.color, title: "x", side: 16).tiffRepresentation
            #expect(space.dotImage(side: 16).tiffRepresentation != dot)
            let plate = FolderIcon.automatic.image(tint: .systemBlue).tiffRepresentation
            #expect(group.icon.image(tint: .systemBlue).tiffRepresentation != plate)
        }
    }

    // MARK: - Helpers

    /// Runs `body` with `SpaceIconStore.shared` pointed at a fresh directory,
    /// and puts the real one back afterwards. The suite is serialized so two
    /// of these can never be in flight at once.
    private func withTemporaryIconStore(
        _ body: (SpaceIconStore, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "kylmora.icons.\(UUID().uuidString)", directoryHint: .isDirectory)
        let previous = SpaceIconStore.shared
        let store = SpaceIconStore(directory: directory)
        SpaceIconStore.shared = store
        defer {
            SpaceIconStore.shared = previous
            try? FileManager.default.removeItem(at: directory)
        }
        try body(store, directory)
    }

    private func writePNG(side: CGFloat = 32) throws -> URL {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "kylmora.source.\(UUID().uuidString).png")
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: url)
        return url
    }
}

extension SpaceIcon {
    /// The menu choice this icon *is*, for the round trip test. Separate from
    /// `asMenuChoice`, which answers what the menu should tick and so cannot
    /// carry a picture's file name.
    var asChoiceForTesting: IconMenu.Choice {
        switch self {
        case .automatic: return .none
        case .emoji(let text): return .emoji(text)
        case .symbol(let name): return .symbol(name)
        case .custom(let file): return .custom(file)
        }
    }
}

