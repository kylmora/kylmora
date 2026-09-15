import AppKit

/// The colour a space paints the window with.
///
/// A space is an identity, and the reason to give one a colour is not
/// decoration: it is so that a glance at the window answers "which space am I
/// in, and so who am I signed in as" before anything is read. That only works if the colour is on the chrome
/// itself rather than on a badge in a corner, which is why this type exposes a
/// `wash` for the whole surface and not just a dot.
///
/// A fixed palette rather than a colour well. Eight colours that are known to
/// survive being washed over a dark material are worth more than a picker that
/// lets a user choose one that does not -- and a fixed set is what makes the
/// swatch row in Settings a row of swatches.
enum SpaceTheme: String, CaseIterable, Codable, Sendable {
    case neutral
    case green
    case blue
    case purple
    case amber
    case pink
    case red
    case orange
    /// A colour the user picked from the wheel. The colour itself lives on
    /// the space (`SpaceLook.customColor`); this case only says to use it.
    case custom

    /// The fixed swatches, in the order the picker shows them. `custom` is
    /// not a swatch.
    static let palette: [SpaceTheme] = allCases.filter { $0 != .custom }

    /// The colour the first space starts on.
    static let `default` = SpaceTheme.blue

    /// Tolerant of anything: a session file naming a colour this build does not
    /// have restores onto the default rather than refusing to open.
    init(storedValue: String?) {
        self = storedValue.flatMap(SpaceTheme.init(rawValue:)) ?? .default
    }

    var title: String {
        switch self {
        case .neutral: return "None"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .amber: return "Amber"
        case .pink: return "Pink"
        case .red: return "Red"
        case .orange: return "Orange"
        case .custom: return "Custom"
        }
    }

    /// The swatch, and the dot beside the space's name.
    ///
    /// Deliberately not the system accent colours: those follow the user's
    /// system-wide accent setting, so two spaces set to different colours
    /// would come out the same. A space colour that changes when a system
    /// preference changes is not an identity marker.
    var color: NSColor {
        switch self {
        case .neutral: return NSColor(srgbRed: 0.92, green: 0.92, blue: 0.93, alpha: 1)
        case .green: return NSColor(srgbRed: 0.05, green: 0.65, blue: 0.42, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.02, green: 0.48, blue: 0.73, alpha: 1)
        case .purple: return NSColor(srgbRed: 0.45, green: 0.37, blue: 0.78, alpha: 1)
        case .amber: return NSColor(srgbRed: 0.83, green: 0.62, blue: 0.05, alpha: 1)
        case .pink: return NSColor(srgbRed: 0.80, green: 0.40, blue: 0.54, alpha: 1)
        case .red: return NSColor(srgbRed: 0.85, green: 0.25, blue: 0.33, alpha: 1)
        case .orange: return NSColor(srgbRed: 0.85, green: 0.35, blue: 0.16, alpha: 1)
        // Only a stand-in: a space resolves `custom` to its own colour.
        case .custom: return SpaceTheme.default.color
        }
    }

    /// Whether the colour is strong enough to be worth washing the chrome with.
    /// `neutral` is the opt-out: a space that wants the plain window back.
    var tintsChrome: Bool { self != .neutral }

    /// Painted over the sidebar's and the page card's material.
    ///
    /// Translucent on purpose, not opaque. The material underneath is what makes
    /// the chrome look like part of macOS -- it picks up the desktop behind the
    /// window and dims with the window's active state -- and a flat opaque
    /// rectangle would throw all of that away. The tint is bold enough to be
    /// unmistakable while the material still shows through; the Transparency
    /// control fades it from there down to nothing.
    var wash: NSColor? {
        guard tintsChrome else { return nil }
        return Self.wash(of: color)
    }

    /// Any colour at wash strength: a custom colour, or a website's own.
    ///
    /// `opacity` (0...1) is the space's own wash strength, the Transparency
    /// control turned around (0% transparent is 1 here). At full strength the
    /// tint is bold and unmistakable -- a clearly coloured sidebar, the way Arc
    /// paints one -- and the material still shows through, so the chrome keeps
    /// its depth. 0 fades it out entirely, back to the plain material.
    ///
    /// Light mode gets a touch less than dark: the same alpha over a near-white
    /// surface reads louder than over a dark one.
    ///
    /// These numbers were nearly three times higher, and that single fact was
    /// most of what made the window look cheap. A saturated hue laid over the
    /// sidebar material at 0.42 stops being a tint: it covers the material
    /// completely, so the chrome loses the desktop showing through it and the
    /// depth that comes with that, and every surface drawn on top -- the
    /// selected pill, a folder's plate -- has to fight a flat block of colour
    /// instead of sitting on a neutral one. At this strength the hue is still
    /// unmistakable at a glance, which is the whole job of a space colour,
    /// while the material and everything layered over it still read.
    static func wash(of base: NSColor, opacity: CGFloat = 1) -> NSColor {
        let opacity = max(0, min(1, opacity))
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return base.withAlphaComponent((isDark ? 0.20 : 0.15) * opacity)
        }
    }

    /// A filled circle of the colour, for a menu item or a list row.
    ///
    /// Drawn rather than tinted from a symbol: `circle.fill` at a small point
    /// size carries antialiasing that reads as a soft edge next to the crisp
    /// swatches in Settings, and the two are meant to be the same dot.
    func dotImage(side: CGFloat = 10) -> NSImage {
        Self.dotImage(color: color, title: title, side: side)
    }

    static func dotImage(color fill: NSColor, title: String, side: CGFloat = 10) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.accessibilityDescription = title
        return image
    }

    /// Control-1 through Control-9, in sidebar order. Spaces past the ninth
    /// get no shortcut rather than a wrong one.
    static func shortcut(forIndex index: Int) -> String? {
        guard (0..<9).contains(index) else { return nil }
        return String(index + 1)
    }
}
