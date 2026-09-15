import Foundation

/// Representation of a web link or bookmark sent from an iPhone, iPad, or external shortcut (F-35).
public struct IPhoneLink: Codable, Identifiable, Equatable, Sendable {
    public enum TargetMode: String, Codable, Sendable, CaseIterable {
        case tab
        case pinned
        case littleArc

        public var title: String {
            switch self {
            case .tab: return "New Tab"
            case .pinned: return "Pinned Tile"
            case .littleArc: return "Little Arc Window"
            }
        }
    }

    public var id: UUID
    public var url: URL
    public var title: String?
    public var spaceName: String?
    public var mode: TargetMode
    public var note: String?
    public var sender: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String? = nil,
        spaceName: String? = nil,
        mode: TargetMode = .tab,
        note: String? = nil,
        sender: String? = "iPhone",
        createdAt: Date = .now
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.spaceName = spaceName
        self.mode = mode
        self.note = note
        self.sender = sender
        self.createdAt = createdAt
    }

    /// User-facing label for the link.
    public var displayTitle: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let host = url.host(), !host.isEmpty {
            return host
        }
        return url.absoluteString
    }

    // MARK: - Ingestion Parsers

    /// Parses an incoming link from raw JSON data.
    /// Supports both strict schema and loose shortcut-friendly fields.
    public static func parse(jsonData: Data) -> IPhoneLink? {
        // Try strict decoding first
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(IPhoneLink.self, from: jsonData) {
            return decoded
        }

        // Try loose dictionary decoding for various iOS Shortcut output styles
        guard let jsonObject = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] else {
            return nil
        }

        let urlString = (jsonObject["url"] as? String)
            ?? (jsonObject["link"] as? String)
            ?? (jsonObject["address"] as? String)
            ?? (jsonObject["URL"] as? String)
        guard let urlString, let validURL = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              validURL.scheme?.hasPrefix("http") == true else {
            return nil
        }

        let title = (jsonObject["title"] as? String)
            ?? (jsonObject["name"] as? String)
            ?? (jsonObject["Title"] as? String)

        let space = (jsonObject["space"] as? String)
            ?? (jsonObject["spaceName"] as? String)
            ?? (jsonObject["targetSpace"] as? String)
            ?? (jsonObject["Space"] as? String)

        let modeRaw = (jsonObject["mode"] as? String)?.lowercased() ?? "tab"
        let mode: TargetMode
        switch modeRaw {
        case "pinned", "pin": mode = .pinned
        case "littlearc", "little_arc", "floating": mode = .littleArc
        default: mode = .tab
        }

        let note = (jsonObject["note"] as? String) ?? (jsonObject["comment"] as? String)
        let sender = (jsonObject["sender"] as? String) ?? (jsonObject["device"] as? String) ?? "iPhone"

        return IPhoneLink(
            url: validURL,
            title: title,
            spaceName: space,
            mode: mode,
            note: note,
            sender: sender,
            createdAt: .now
        )
    }

    /// Parses an incoming link from plain text or internet shortcut `.url` format.
    public static func parse(text: String) -> IPhoneLink? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return nil }

        var targetURL: URL?
        var title: String?
        var space: String?
        var mode: TargetMode = .tab

        for line in lines {
            if line.lowercased().starts(with: "url=") {
                let raw = String(line.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                if let u = URL(string: raw) { targetURL = u }
            } else if line.lowercased().hasPrefix("http://") || line.lowercased().hasPrefix("https://") {
                if targetURL == nil, let u = URL(string: line) { targetURL = u }
            } else if line.lowercased().starts(with: "space:") || line.lowercased().starts(with: "[space:") {
                let cleaned = line.replacingOccurrences(of: "[", with: "")
                    .replacingOccurrences(of: "]", with: "")
                let parts = cleaned.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    space = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else if line.lowercased().starts(with: "title:") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    title = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else if line.lowercased().starts(with: "mode:") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let m = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if m == "pinned" { mode = .pinned }
                    else if m == "littlearc" { mode = .littleArc }
                }
            } else if title == nil && targetURL != nil {
                title = line
            }
        }

        guard let targetURL, targetURL.scheme?.hasPrefix("http") == true else { return nil }

        return IPhoneLink(
            url: targetURL,
            title: title,
            spaceName: space,
            mode: mode,
            sender: "iPhone",
            createdAt: .now
        )
    }

    /// Parses an incoming link from a `kylmora://send` or `kylmora://add` deep-link URL scheme.
    public static func parse(urlScheme: URL) -> IPhoneLink? {
        guard let components = URLComponents(url: urlScheme, resolvingAgainstBaseURL: false) else {
            return nil
        }

        // Scheme must be kylmora
        guard components.scheme?.lowercased() == "kylmora" else { return nil }

        // Host or path should be send, add, open, or inbox
        let action = (components.host ?? components.path).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard action == "send" || action == "add" || action == "open" || action == "inbox" || action == "share" else {
            return nil
        }

        let queryItems = components.queryItems ?? []
        func queryValue(for keys: [String]) -> String? {
            for key in keys {
                if let match = queryItems.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame })?.value {
                    return match
                }
            }
            return nil
        }

        guard let targetString = queryValue(for: ["url", "link", "address", "target"]),
              let validURL = URL(string: targetString),
              validURL.scheme?.hasPrefix("http") == true else {
            return nil
        }

        let title = queryValue(for: ["title", "name"])
        let space = queryValue(for: ["space", "targetSpace"])
        let note = queryValue(for: ["note", "comment"])
        let sender = queryValue(for: ["sender", "device", "from"]) ?? "iPhone"

        let modeRaw = queryValue(for: ["mode"])?.lowercased() ?? "tab"
        let mode: TargetMode
        switch modeRaw {
        case "pinned", "pin": mode = .pinned
        case "littlearc", "little_arc", "floating": mode = .littleArc
        default: mode = .tab
        }

        return IPhoneLink(
            url: validURL,
            title: title,
            spaceName: space,
            mode: mode,
            note: note,
            sender: sender,
            createdAt: .now
        )
    }
}
