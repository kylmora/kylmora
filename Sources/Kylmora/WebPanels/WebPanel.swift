import Foundation

/// A pinned side web app (e.g. ChatGPT, Claude, Quick Notes, WhatsApp, DeepL, Google Keep, etc.).
public struct WebPanel: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var url: URL
    public var symbolName: String
    public var customUserAgent: String?
    public var isPinned: Bool
    public var order: Int

    public init(
        id: UUID = UUID(),
        title: String,
        url: URL,
        symbolName: String = "sidebar.right",
        customUserAgent: String? = nil,
        isPinned: Bool = true,
        order: Int = 0
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.symbolName = symbolName
        self.customUserAgent = customUserAgent
        self.isPinned = isPinned
        self.order = order
    }

    /// True if the panel represents the built-in offline scratchpad.
    public var isScratchpad: Bool {
        url.scheme == "kylmora" && (url.host == "scratchpad" || url.host == "notes")
    }

    // MARK: - Built-in Presets

    public static let scratchpadURL = URL(string: "kylmora://scratchpad")!

    public static let scratchpad = WebPanel(
        title: "Quick Notes",
        url: scratchpadURL,
        symbolName: "square.and.pencil",
        isPinned: true,
        order: 0
    )

    public static let chatGPT = WebPanel(
        title: "ChatGPT",
        url: URL(string: "https://chatgpt.com")!,
        symbolName: "sparkles",
        isPinned: true,
        order: 1
    )

    public static let claude = WebPanel(
        title: "Claude",
        url: URL(string: "https://claude.ai")!,
        symbolName: "brain",
        isPinned: false,
        order: 2
    )

    public static let googleKeep = WebPanel(
        title: "Google Keep",
        url: URL(string: "https://keep.google.com")!,
        symbolName: "note.text",
        isPinned: true,
        order: 3
    )

    public static let deepl = WebPanel(
        title: "DeepL Translate",
        url: URL(string: "https://www.deepl.com/translator")!,
        symbolName: "character.book.closed",
        isPinned: true,
        order: 4
    )

    public static let whatsApp = WebPanel(
        title: "WhatsApp Web",
        url: URL(string: "https://web.whatsapp.com")!,
        symbolName: "bubble.left.and.bubble.right",
        isPinned: false,
        order: 5
    )

    public static let gitHub = WebPanel(
        title: "GitHub",
        url: URL(string: "https://github.com")!,
        symbolName: "chevron.left.forwardslash.chevron.right",
        isPinned: false,
        order: 6
    )

    /// All preset choices available for quick addition.
    public static let presets: [WebPanel] = [
        scratchpad,
        chatGPT,
        claude,
        googleKeep,
        deepl,
        whatsApp,
        gitHub
    ]

    /// The default panels installed on a fresh profile.
    public static let defaultPanels: [WebPanel] = [
        scratchpad,
        chatGPT,
        deepl,
        googleKeep
    ]
}
