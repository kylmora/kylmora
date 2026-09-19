import AppKit

/// What a space draws where its coloured dot goes: in the sidebar header, in
/// the space menu, on its card in Settings, in the window list.
///
/// Four cases rather than an optional emoji, because the four render
/// genuinely differently -- the same reasoning as `FolderIcon`, one level up.
/// An emoji is glyph art the system already colours; a symbol is a template
/// tinted with the space's own colour, so it still says which identity is in
/// front; a picture the user chose is drawn as it is and tinted by nothing;
/// and the dot has to exist, because a space nobody decorated must still read
/// as a space rather than as a gap.
///
/// The dot is the default and stays the default. It is the one thing in this
/// list that is guaranteed to mean "this space and not that one" at ten
/// points, which is the size most of these are drawn at.
enum SpaceIcon: Equatable, Sendable {
    /// The coloured dot, as every space had before icons existed.
    case automatic
    case emoji(String)
    /// An SF Symbol name. An unresolvable name falls back to the dot at draw
    /// time rather than at assignment, so a symbol that disappears in some
    /// future macOS degrades instead of being quietly rewritten in the
    /// session file.
    case symbol(String)
    /// A picture the user chose, by its file name in `SpaceIconStore`. A file
    /// that has gone falls back to the dot for the same reason.
    case custom(String)

    /// Whether this is something the user picked, which is what a "Remove
    /// Icon" item needs to know to be enabled.
    var isCustomized: Bool { self != .automatic }

    /// The name of the file this icon owns, if it owns one. What the store
    /// deletes when the icon is replaced or the space is.
    var customFileName: String? {
        if case .custom(let name) = self { return name }
        return nil
    }

    /// What the icon menu should show as chosen.
    var asMenuChoice: IconMenu.Current {
        switch self {
        case .automatic: return IconMenu.Current()
        case .emoji(let text): return IconMenu.Current(emoji: text)
        case .symbol(let name): return IconMenu.Current(symbol: name)
        case .custom: return IconMenu.Current(isCustom: true)
        }
    }

    /// What the menu settled on, as a space's icon.
    init(_ choice: IconMenu.Choice) {
        switch choice {
        case .none: self = .automatic
        case .emoji(let text): self = .emoji(text)
        case .symbol(let name): self = .symbol(name)
        case .custom(let fileName): self = .custom(fileName)
        }
    }
}

extension SpaceIcon {
    /// The image for a well of `side` points, in the space's colour.
    ///
    /// Drawn per call rather than cached, like `FolderIcon.image(tint:)`: the
    /// colours are semantic and have to be re-resolved when the appearance
    /// changes, and these are built once per menu or per sidebar rebuild, not
    /// per frame. The picture behind `.custom` *is* cached -- by the store,
    /// because decoding a PNG is not the same order of work as filling an
    /// oval.
    @MainActor
    func image(color: NSColor, title: String, side: CGFloat) -> NSImage {
        switch self {
        case .emoji(let text) where !text.isEmpty:
            return Self.glyphImage(text, side: side, title: title)
        case .symbol(let name):
            if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: title) {
                return Self.symbolImage(symbol, color: color, side: side, title: title)
            }
            return SpaceTheme.dotImage(color: color, title: title, side: side)
        case .custom(let fileName):
            if let picture = SpaceIconStore.shared.image(named: fileName) {
                return Self.fitted(picture, side: side, title: title)
            }
            return SpaceTheme.dotImage(color: color, title: title, side: side)
        case .emoji, .automatic:
            return SpaceTheme.dotImage(color: color, title: title, side: side)
        }
    }

    /// An emoji drawn to fill the well.
    ///
    /// The font is sized from the well rather than fixed, because the same
    /// icon is asked for at ten points in a menu and at twenty-two on a card,
    /// and an emoji that ignored the second would be a speck in the middle of
    /// it. Slightly under the full side: emoji glyphs carry their own padding,
    /// and one drawn at the full height overhangs a dot of the same height.
    @MainActor
    private static func glyphImage(_ text: String, side: CGFloat, title: String) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: side * 0.92)
        ]
        let string = text as NSString
        let size = string.size(withAttributes: attributes)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            string.draw(
                at: NSPoint(
                    x: rect.midX - size.width / 2,
                    y: rect.midY - size.height / 2
                ),
                withAttributes: attributes
            )
            return true
        }
        image.accessibilityDescription = title
        return image
    }

    /// A symbol in the space's own colour.
    ///
    /// Not a template. A template is tinted by whatever draws it, which in a
    /// menu means the menu's text colour -- and a space icon that comes out
    /// the same colour as every other space's icon has given up the one job
    /// the dot was doing.
    @MainActor
    private static func symbolImage(
        _ symbol: NSImage,
        color: NSColor,
        side: CGFloat,
        title: String
    ) -> NSImage {
        let configured = symbol.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: side * 0.9, weight: .medium)
        ) ?? symbol
        let drawn = fitted(configured, side: side, title: title)
        let tinted = NSImage(size: drawn.size, flipped: false) { rect in
            drawn.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.accessibilityDescription = title
        return tinted
    }

    /// The picture at the biggest size that fits the well without distorting
    /// it. Shared with `FolderIcon`, which takes pictures from the same store
    /// and has to draw them the same way.
    @MainActor
    static func fitted(_ picture: NSImage, side: CGFloat, title: String) -> NSImage {
        let box = NSSize(width: side, height: side)
        let source = picture.size
        guard source.width > 0, source.height > 0 else { return picture }
        let scale = min(box.width / source.width, box.height / source.height)
        let drawn = NSSize(width: source.width * scale, height: source.height * scale)
        let image = NSImage(size: box, flipped: false) { rect in
            picture.draw(
                in: NSRect(
                    x: rect.midX - drawn.width / 2,
                    y: rect.midY - drawn.height / 2,
                    width: drawn.width,
                    height: drawn.height
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
        image.accessibilityDescription = title
        return image
    }
}

// MARK: - Storage

extension SpaceIcon: Codable {
    /// Written as `{"kind": "emoji", "value": "\u{1F680}"}` rather than as the
    /// shape Swift synthesises for an enum with associated values.
    ///
    /// The session file is pretty-printed with sorted keys because it is meant
    /// to be readable by a person looking for what went wrong; `{"emoji":
    /// {"_0": "..."}}` is not that. An unknown kind -- one written by a later
    /// build -- decodes as the dot instead of throwing, which would take the
    /// whole session file down with it.
    private enum CodingKeys: String, CodingKey { case kind, value }

    private enum Kind: String, Codable {
        case automatic, emoji, symbol, custom
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The kind comes back as a plain string and is matched afterwards, so
        // a word this build does not know becomes the dot. Decoding it as the
        // enum would throw, and a throw here does not lose an icon -- it loses
        // the session file it was written in.
        let name = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        let kind = Kind(rawValue: name) ?? .automatic
        let value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        switch kind {
        case .automatic: self = .automatic
        case .emoji: self = value.isEmpty ? .automatic : .emoji(value)
        case .symbol: self = value.isEmpty ? .automatic : .symbol(value)
        case .custom: self = value.isEmpty ? .automatic : .custom(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic:
            try container.encode(Kind.automatic, forKey: .kind)
        case .emoji(let value):
            try container.encode(Kind.emoji, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .symbol(let value):
            try container.encode(Kind.symbol, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .custom(let value):
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

// MARK: - Suggestions

extension SpaceIcon {
    /// The symbols offered in the icon menu.
    ///
    /// A short list rather than the whole SF Symbols catalogue. Spaces are
    /// named for what they are for -- work, home, reading, money, a project --
    /// and a picker with six thousand symbols in it is a worse way to find
    /// "briefcase" than a dozen guesses at what people actually name spaces.
    /// Anything outside the list is what "Choose Image" is for.
    static let suggestedSymbols = [
        "briefcase.fill",
        "house.fill",
        "book.fill",
        "cart.fill",
        "creditcard.fill",
        "graduationcap.fill",
        "gamecontroller.fill",
        "music.note",
        "camera.fill",
        "hammer.fill",
        "leaf.fill",
        "star.fill"
    ]
}
