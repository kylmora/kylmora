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

    /// The full row, and the pill drawn inside it.
    var rowHeight: CGFloat {
        switch self {
        case .compact: return 28
        // Two points taller than it was, which is a point at the top and a
        // point at the bottom of the pill drawn inside it -- the two device
        // pixels each way that the selected row was asked for. The row grows
        // with the pill rather than the pill eating into the row, so the
        // clear material between one pill and the next is untouched.
        case .regular: return 34
        case .roomy: return 38
        }
    }

    /// Three points of clear material above and below every pill, not two.
    ///
    /// A pill with a two-point margin nearly touches the pills above and below
    /// it, so a list of them reads as one segmented bar rather than as separate
    /// rows -- and the selected one, which now casts a shadow, had nowhere to
    /// cast it. Six points off the row is the largest margin a 28-point row can
    /// give and still leave a pill tall enough for a 16-point favicon.
    var pillHeight: CGFloat { rowHeight - 6 }
}

extension Notification.Name {
    static let sidebarDensityDidChange = Notification.Name("sidebarDensityDidChange")
    static let tabStripDidChange = Notification.Name("tabStripDidChange")
}
