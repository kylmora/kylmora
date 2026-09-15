import AppKit
import Foundation
import UniformTypeIdentifiers

/// A Space's look as a file: its colour, gradient, appearance, fonts, bars
/// and window border, so a setup can be sent to someone or carried to
/// another Mac. Nothing about the tabs or the identity travels with it.
struct SpaceThemeFile: Codable, Equatable {
    static let currentVersion = 1
    static let fileExtension = "kylmoratheme"
    static var contentType: UTType { UTType(exportedAs: "com.kylmora.theme", conformingTo: .json) }

    var version: Int
    var name: String
    var theme: SpaceTheme
    var look: SpaceLook
    var border: WindowBorder

    init(name: String, theme: SpaceTheme, look: SpaceLook, border: WindowBorder) {
        self.version = Self.currentVersion
        self.name = name
        self.theme = theme
        self.look = look
        self.border = border
    }

    /// The look `space` has now, named after it.
    @MainActor
    init(space: Space) {
        self.init(name: space.name, theme: space.theme, look: space.look, border: space.border)
    }

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    init(data: Data) throws {
        self = try JSONDecoder().decode(SpaceThemeFile.self, from: data)
    }

    /// Puts this look on `space`. The space keeps its name, tabs and
    /// identity; only how it paints the window changes.
    @MainActor
    func apply(to space: Space, in session: BrowserSession) {
        session.setTheme(theme, for: space)
        session.setLook(look, for: space)
        session.setBorder(border, for: space)
    }

    /// A file name for the Save panel: the theme's name, made safe.
    var suggestedFileName: String {
        let safe = name.map { "/\\:*?\"<>|".contains($0) ? "-" : $0 }
        let stem = String(safe).trimmingCharacters(in: .whitespaces)
        return (stem.isEmpty ? "Theme" : stem) + "." + Self.fileExtension
    }
}

/// How tall the sidebar's rows are.
enum SidebarDensity: String, CaseIterable, Codable, Sendable {
    case compact, regular, roomy

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .regular: return "Regular"
        case .roomy: return "Roomy"
        }
    }

    /// The full row, and the pill drawn inside it: the pill keeps the same
    /// 2-point margin above and below at every density.
    var rowHeight: CGFloat {
        switch self {
        case .compact: return 28
        case .regular: return 32
        case .roomy: return 38
        }
    }

    var pillHeight: CGFloat { rowHeight - 4 }
}

extension Notification.Name {
    static let sidebarDensityDidChange = Notification.Name("sidebarDensityDidChange")
    static let tabStripDidChange = Notification.Name("tabStripDidChange")
}
