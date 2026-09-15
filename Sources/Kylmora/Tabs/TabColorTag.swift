import AppKit

/// A colour a tab can be tagged with, drawn as a dot on its favicon. It
/// means whatever the user wants it to mean; the browser only keeps it.
enum TabColorTag: String, CaseIterable, Codable, Sendable {
    case red, orange, yellow, green, blue, purple, gray

    var title: String { rawValue == "gray" ? "Grey" : rawValue.capitalized }

    var nsColor: NSColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .gray: return .systemGray
        }
    }

    /// A menu swatch.
    func dotImage(side: CGFloat = 12) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}
