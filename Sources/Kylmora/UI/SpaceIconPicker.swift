import AppKit
import UniformTypeIdentifiers

/// Choosing what a space or a folder wears.
///
/// A menu rather than a panel of its own, for two reasons. The choice has
/// exactly four shapes -- an emoji, one of a dozen symbols, a picture, or
/// nothing -- and a menu says all four in one glance where a panel would need
/// tabs. And the same choice is offered from places that look nothing alike:
/// the New Space sheet, the Spaces pane in Settings, and the right-click menu
/// on a folder in the sidebar. A menu is the one control all of them can show
/// without agreeing on a layout.
///
/// It deals in `Choice` rather than in `SpaceIcon` or `FolderIcon` because the
/// two icons draw their "nothing chosen" case differently -- a coloured dot
/// for a space, a folder squircle for a folder -- and that is the only way
/// they differ. The caller maps the choice back onto its own type.
@MainActor
enum IconMenu {
    /// What the menu hands back.
    enum Choice: Equatable {
        /// Take the icon off: back to the dot, or to the folder plate.
        case none
        case emoji(String)
        case symbol(String)
        /// A picture, already copied into `SpaceIconStore` by the time this
        /// arrives -- the menu does the importing, so a file that cannot be
        /// used is refused while the picker is still open.
        case custom(String)
    }

    /// What the thing wears now: what gets the tick, and what decides whether
    /// Remove has anything to remove.
    struct Current: Equatable {
        var emoji: String?
        var symbol: String?
        var isCustom: Bool
        /// Whether anything at all was chosen.
        var isCustomized: Bool { emoji != nil || symbol != nil || isCustom }

        init(emoji: String? = nil, symbol: String? = nil, isCustom: Bool = false) {
            self.emoji = emoji
            self.symbol = symbol
            self.isCustom = isCustom
        }
    }

    /// The items, ready to be a menu of their own or a submenu inside one.
    ///
    /// - Parameters:
    ///   - color: the colour symbols are drawn in, so what the menu shows is
    ///     what the chosen icon will look like.
    ///   - symbols: the short list on offer. A picker with six thousand SF
    ///     Symbols in it is a worse way to find "briefcase" than a dozen
    ///     guesses at what people actually name things.
    ///   - anchor: the view the emoji palette is opened over, and that the
    ///     menu was opened from.
    ///   - onChange: called with the new choice. Never called with what was
    ///     already there.
    static func items(
        current: Current,
        color: NSColor,
        symbols: [String] = SpaceIcon.suggestedSymbols,
        anchor: NSView,
        onChange: @escaping (Choice) -> Void
    ) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        let emoji = item(title: current.emoji == nil ? "Choose Emoji\u{2026}" : "Change Emoji\u{2026}") {
            SpaceEmojiCatcher.ask(from: anchor) { onChange(.emoji($0)) }
        }
        emoji.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: nil)
        emoji.state = current.emoji != nil ? .on : .off
        items.append(emoji)

        let symbolMenu = NSMenu()
        for name in symbols {
            let symbolItem = item(title: title(forSymbol: name)) { onChange(.symbol(name)) }
            symbolItem.image = SpaceIcon.symbol(name).image(color: color, title: name, side: 16)
            if current.symbol == name { symbolItem.state = .on }
            symbolMenu.addItem(symbolItem)
        }
        let symbolsItem = NSMenuItem(title: "Symbol", action: nil, keyEquivalent: "")
        symbolsItem.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        symbolsItem.submenu = symbolMenu
        items.append(symbolsItem)

        let picture = item(title: "Choose Image\u{2026}") {
            guard let url = chooseFile() else { return }
            do {
                onChange(.custom(try SpaceIconStore.shared.importIcon(from: url)))
            } catch {
                present(error)
            }
        }
        picture.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        picture.state = current.isCustom ? .on : .off
        items.append(picture)

        items.append(.separator())

        let remove = item(title: "Remove Icon") { onChange(.none) }
        remove.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        // Nothing to remove leaves the item visible but inert: a menu whose
        // items come and go is a menu whose shape you cannot learn.
        remove.isEnabled = current.isCustomized
        items.append(remove)

        return items
    }

    /// The same items as a menu of their own.
    static func menu(
        current: Current,
        color: NSColor,
        symbols: [String] = SpaceIcon.suggestedSymbols,
        anchor: NSView,
        onChange: @escaping (Choice) -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        for item in items(current: current, color: color, symbols: symbols, anchor: anchor, onChange: onChange) {
            menu.addItem(item)
        }
        return menu
    }

    // MARK: - Pieces

    /// The first emoji in whatever was typed or inserted, or nil for nothing
    /// usable.
    ///
    /// By character rather than by scalar: a flag, a skin-toned hand and a
    /// family are each several scalars that mean one glyph, and cutting by
    /// scalar would turn them into different emoji entirely.
    static func firstEmoji(of typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }
        return String(first)
    }

    /// "briefcase.fill" as "Briefcase". The symbol names are the API's, and
    /// the API's names are not a menu.
    static func title(forSymbol name: String) -> String {
        let words = name
            .replacingOccurrences(of: ".fill", with: "")
            .split(separator: ".")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.joined(separator: " ")
    }

    private static func item(title: String, run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.fire(_:)), keyEquivalent: "")
        let action = MenuAction(run: run)
        item.target = action
        item.representedObject = action
        return item
    }

    private static func chooseFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SpaceIconStore.allowedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a picture to use as the icon."
        panel.prompt = "Use Image"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private static func present(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}

/// A closure a menu item can hold on to.
///
/// `NSMenuItem` takes a target and a selector, and the three places this menu
/// is shown from have no business each growing a set of `@objc` methods for
/// items they did not build. The item retains this through
/// `representedObject`, which is what keeps it alive for as long as the menu
/// it is in.
@MainActor
private final class MenuAction: NSObject {
    private let run: () -> Void

    init(run: @escaping () -> Void) {
        self.run = run
        super.init()
    }

    @objc func fire(_ sender: Any?) { run() }
}

/// The square that shows what a space or a folder wears, and opens the menu
/// that changes it.
///
/// Beside the name field in the New Space sheet, in the Spaces pane, and in
/// the New Group sheet. It knows nothing about either icon type: it is handed
/// a picture to show and hands back what the menu settled on.
@MainActor
final class IconWell: NSButton {
    /// Called with whatever the menu settled on.
    var onChange: ((IconMenu.Choice) -> Void)?
    /// The symbols the menu offers. Left alone unless a caller wants its own.
    var symbols: [String] = SpaceIcon.suggestedSymbols

    /// Big enough to see what a picture actually is -- an emoji or a logo at
    /// ten points is a guess -- and no bigger than the text field it stands
    /// beside, so the row still reads as one row.
    static let side: CGFloat = 24

    private var current = IconMenu.Current()
    private var color: NSColor = .controlAccentColor
    private let glyph = NSImageView()

    init() {
        super.init(frame: .zero)
        title = ""
        imagePosition = .noImage
        isBordered = false
        bezelStyle = .accessoryBarAction
        target = self
        action = #selector(openMenu)
        setAccessibilityLabel("Icon")
        toolTip = "The emoji, symbol or picture shown wherever this is named."

        glyph.imageScaling = .scaleProportionallyDown
        glyph.setAccessibilityElement(false)
        // The glyph is the button's face, not a thing of its own: a click that
        // landed on it rather than on the button would go nowhere.
        glyph.isEnabled = false
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: Self.side),
            glyph.heightAnchor.constraint(equalToConstant: Self.side)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("IconWell is created in code only")
    }

    /// - Parameters:
    ///   - image: what to draw, already rendered by whichever icon type the
    ///     caller holds.
    ///   - current: what the menu should show as chosen.
    ///   - color: the colour symbols in the menu are drawn in.
    func show(image: NSImage, current: IconMenu.Current, color: NSColor) {
        self.current = current
        self.color = color
        glyph.image = image
        setAccessibilityValue(Self.describe(current))
    }

    /// What VoiceOver says the well is showing, since the picture itself says
    /// nothing to it.
    static func describe(_ current: IconMenu.Current) -> String {
        if let emoji = current.emoji { return emoji }
        if let symbol = current.symbol { return IconMenu.title(forSymbol: symbol) }
        return current.isCustom ? "Custom image" : "No icon"
    }

    @objc private func openMenu() {
        let menu = IconMenu.menu(current: current, color: color, symbols: symbols, anchor: self) { [weak self] choice in
            self?.onChange?(choice)
        }
        // Under the well rather than at the pointer, so the menu reads as
        // belonging to the square that opened it.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }
}


/// Opens the system's emoji palette and keeps whatever it inserts.
///
/// macOS already has an emoji picker: it searches, it has the whole set, it
/// remembers what you used last, and everyone already knows it. Offering our
/// own grid in front of it only made the user choose a picker before choosing
/// an emoji, so the grid is gone and this goes straight there.
///
/// The palette inserts into whatever is focused, which is the one thing it
/// needs and a menu item does not have. So a field is put where the icon well
/// is, focused, and left to catch what the palette sends -- one character
/// wide, all but invisible, and gone again the moment it has caught something
/// or the user has looked away.
@MainActor
final class SpaceEmojiCatcher: NSTextField, NSTextFieldDelegate {
    private var onEmoji: ((String) -> Void)?

    /// The one in flight, if any. A second menu must not leave the first
    /// field sitting in a view swallowing keystrokes.
    private static weak var open: SpaceEmojiCatcher?

    static func ask(from anchor: NSView, onEmoji: @escaping (String) -> Void) {
        open?.finish()

        let catcher = SpaceEmojiCatcher(frame: anchor.bounds)
        catcher.onEmoji = onEmoji
        catcher.isBordered = false
        catcher.drawsBackground = false
        catcher.focusRingType = .none
        // Not hidden and not zero-sized: the palette puts itself beside the
        // insertion point, and a field with neither position nor size sends it
        // to the corner of the screen. Transparent and exactly where the well
        // is, so the palette comes up over the control that asked for it.
        catcher.alphaValue = 0.01
        catcher.delegate = catcher
        anchor.addSubview(catcher)
        Self.open = catcher

        anchor.window?.makeFirstResponder(catcher)
        NSApp.orderFrontCharacterPalette(nil)
    }

    /// The palette inserts and leaves. Taking the character as it arrives is
    /// what makes picking an emoji one click; waiting for Return would put
    /// back the confirmation step this replaced.
    func controlTextDidChange(_ notification: Notification) {
        guard let emoji = IconMenu.firstEmoji(of: stringValue) else { return }
        let keep = onEmoji
        finish()
        keep?(emoji)
    }

    /// Clicked away from without picking: the field goes, and nothing changes.
    func controlTextDidEndEditing(_ notification: Notification) {
        finish()
    }

    /// Never takes a click, whoever it is sitting on top of.
    ///
    /// This field is laid over the icon well, and while the palette is open it
    /// is the frontmost thing there. Without this, clicking the well again
    /// hits the field instead of the button -- so the menu does not open, and
    /// because the click landed *inside* the field, editing never ends and the
    /// field never takes itself away either. The control stayed dead until the
    /// window was clicked somewhere else entirely.
    ///
    /// Refusing every click also means a click on the well always reaches the
    /// well, which ends the field's editing and cleans it up on the way.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func finish() {
        onEmoji = nil
        if Self.open === self { Self.open = nil }
        // Back to the window rather than to the well: the well is a button and
        // may refuse first responder, which would leave a field that is no
        // longer in any view still holding the keyboard.
        if let window, window.firstResponder === currentEditor() || window.firstResponder === self {
            window.makeFirstResponder(nil)
        }
        removeFromSuperview()
    }
}
