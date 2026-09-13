import AppKit

/// The coloured rim a space draws around the window while it is in front.
///
/// A second identity marker, next to the colour wash: the wash tells you
/// which space you are in from the sidebar, the border tells you from any
/// corner of the screen, including while a page is covering everything else.
/// It is per space rather than one setting for the window because that is
/// what makes it a marker at all -- a rim that looks the same in Work and
/// Personal says nothing.
///
/// Orion sells this as part of its paid plan. Here it is a plain setting on
/// every space, private ones included.
struct WindowBorder: Codable, Hashable, Sendable {
    enum Style: String, CaseIterable, Codable, Sendable {
        case none
        case solid
        case glass
        case gradient

        var title: String {
            switch self {
            case .none: return "No Border"
            case .solid: return "Solid"
            case .glass: return "Glass"
            case .gradient: return "Gradient"
            }
        }
    }

    /// Three stops rather than a free number: a rim is either a hairline you
    /// notice, a line you see, or a frame, and nothing between those reads
    /// as a different choice.
    enum Thickness: String, CaseIterable, Codable, Sendable {
        case thin
        case medium
        case thick

        var title: String {
            switch self {
            case .thin: return "Thin"
            case .medium: return "Medium"
            case .thick: return "Thick"
            }
        }

        /// In points, drawn inside the window's edge.
        var points: CGFloat {
            switch self {
            case .thin: return 2
            case .medium: return 4
            case .thick: return 7
            }
        }
    }

    /// How fast a gradient travels around the rim. Still, or two speeds: the
    /// slow one is a glow that drifts, the fast one is a ring that visibly
    /// turns. Faster than that is a distraction on every page.
    enum Animation: String, CaseIterable, Codable, Sendable {
        case still
        case slow
        case fast

        var title: String {
            switch self {
            case .still: return "Still"
            case .slow: return "Slow"
            case .fast: return "Fast"
            }
        }

        /// Seconds for one trip around the window. Zero means no motion.
        var secondsPerRevolution: TimeInterval {
            switch self {
            case .still: return 0
            case .slow: return 14
            case .fast: return 5
            }
        }
    }

    /// A named run of colours. The gradient style sweeps the run around the
    /// rim; the solid style takes the run's middle colour, so switching
    /// between the two keeps the same choice rather than resetting it.
    enum Palette: String, CaseIterable, Codable, Sendable {
        case glow
        case dark
        case flare
        case deepSpace
        case horizon
        case mint
        case cosmic
        case ocean
        case rainbow
        case fireAndIce
        case silver
        case gold

        var title: String {
            switch self {
            case .glow: return "Kylmora Glow"
            case .dark: return "Kylmora Dark"
            case .flare: return "Flare"
            case .deepSpace: return "Deep Space"
            case .horizon: return "Horizon"
            case .mint: return "Mint"
            case .cosmic: return "Cosmic"
            case .ocean: return "Ocean"
            case .rainbow: return "Rainbow"
            case .fireAndIce: return "Fire & Ice"
            case .silver: return "Silver"
            case .gold: return "Gold"
            }
        }

        /// The colours in order, as sRGB. Literal rather than semantic: a
        /// border is a chosen colour, and one that changed with the system
        /// appearance would be a different choice in the evening.
        var stops: [NSColor] {
            func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
                NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
            }
            switch self {
            case .glow: return [rgb(168, 85, 247), rgb(217, 70, 239), rgb(139, 92, 246)]
            case .dark: return [rgb(88, 28, 135), rgb(109, 40, 217), rgb(67, 56, 202)]
            case .flare: return [rgb(239, 68, 68), rgb(249, 115, 22), rgb(245, 158, 11)]
            case .deepSpace: return [rgb(15, 15, 20), rgb(55, 55, 70), rgb(20, 20, 28)]
            case .horizon: return [rgb(71, 85, 105), rgb(148, 163, 184), rgb(226, 214, 178)]
            case .mint: return [rgb(20, 184, 166), rgb(52, 211, 153), rgb(163, 230, 53)]
            case .cosmic: return [rgb(120, 90, 80), rgb(150, 120, 110), rgb(88, 28, 65)]
            case .ocean: return [rgb(56, 189, 248), rgb(34, 211, 238), rgb(14, 165, 233)]
            case .rainbow: return [rgb(239, 68, 68), rgb(250, 204, 21), rgb(34, 197, 94), rgb(34, 211, 238), rgb(59, 130, 246), rgb(217, 70, 239)]
            case .fireAndIce: return [rgb(239, 68, 68), rgb(251, 146, 60), rgb(255, 255, 255), rgb(125, 211, 252), rgb(59, 130, 246)]
            case .silver: return [rgb(148, 163, 184), rgb(226, 232, 240), rgb(148, 163, 184)]
            case .gold: return [rgb(202, 138, 4), rgb(253, 224, 71), rgb(202, 138, 4)]
            }
        }

        /// The one colour the solid style paints.
        var solidColor: NSColor { stops[stops.count / 2] }
    }

    var style: Style
    var thickness: Thickness
    var animation: Animation
    var palette: Palette

    /// What every space starts with: nothing drawn. The border is an
    /// addition the user makes, not a default to turn off.
    static let none = WindowBorder(style: .none, thickness: .thin, animation: .still, palette: .glow)

    /// A border that draws something, for a preview or a first switch-on.
    static let sample = WindowBorder(style: .gradient, thickness: .thin, animation: .still, palette: .flare)

    init(style: Style, thickness: Thickness, animation: Animation, palette: Palette) {
        self.style = style
        self.thickness = thickness
        self.animation = animation
        self.palette = palette
    }

    /// Whether there is anything to draw.
    var isVisible: Bool { style != .none }

    /// Whether the rim moves: only a gradient has anything to sweep.
    var isAnimated: Bool { style == .gradient && animation.secondsPerRevolution > 0 }

    // MARK: - Tolerant decoding

    /// Every field falls back on its own: a session written by a build with
    /// a palette this one lacks, or a field this one has not heard of, still
    /// restores as a border rather than as a failure to open the session.
    private enum CodingKeys: String, CodingKey {
        case style, thickness, animation, palette
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: RawRepresentable>(_ key: CodingKeys, default fallback: T) -> T where T.RawValue == String {
            (try? container.decodeIfPresent(String.self, forKey: key)).flatMap { $0 }.flatMap(T.init(rawValue:)) ?? fallback
        }
        style = read(.style, default: Self.none.style)
        thickness = read(.thickness, default: Self.none.thickness)
        animation = read(.animation, default: Self.none.animation)
        palette = read(.palette, default: Self.none.palette)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(style.rawValue, forKey: .style)
        try container.encode(thickness.rawValue, forKey: .thickness)
        try container.encode(animation.rawValue, forKey: .animation)
        try container.encode(palette.rawValue, forKey: .palette)
    }
}
