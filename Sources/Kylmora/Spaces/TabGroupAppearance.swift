import AppKit

/// How one tab group paints the plate behind it: the sidebar's flat default, a
/// solid colour, or a gradient with a direction and an optional raised rim.
///
/// A group is a cluster the user assembled on purpose, so letting them colour
/// it is the same idea as a space's colour one level down: a glance says which
/// block a tab belongs to without reading a name. The colour lives here rather
/// than on `TabGroup.tint` (which is only the header dot) because the plate is
/// what the eye actually groups by.
///
/// A value type of strings and enums so a `TabGroup` stays cheap to copy and
/// the whole thing drops straight into the session JSON. Colours are hex, the
/// same convention the space tint uses; the `NSColor` views are computed.
///
/// `elevation` stands in for a drop shadow. The sidebar draws a group's plate
/// as slices of the table's rows (`FolderPlatePlan`), and AppKit clips each
/// row's drawing to its own bounds, so a blurred shadow cast below the plate is
/// cut off at the last row. A crisp rim strokes the plate's own outline, which
/// each slice can draw its part of, so elevation is a rim rather than a blur.
struct TabGroupAppearance: Codable, Hashable, Sendable {
    enum Fill: String, Codable, Sendable {
        /// The sidebar's default plate. The group is not customised.
        case standard
        /// One colour across the whole plate.
        case solid
        /// `start` to `end`, along `direction`.
        case gradient
    }

    /// The line a gradient runs along. Shared with a space's wash, so it lives
    /// as `GradientDirection`; this alias keeps the group's own spelling.
    typealias Direction = GradientDirection

    /// A raised rim, standing in for a drop shadow (see the type's note).
    enum Elevation: String, Codable, CaseIterable, Sendable {
        case none, soft, bold

        var title: String {
            switch self {
            case .none: return "Flat"
            case .soft: return "Soft"
            case .bold: return "Bold"
            }
        }

        /// The rim: a light stroke just inside the plate's edge. Nil for `none`,
        /// which strokes nothing.
        var rim: (alpha: CGFloat, width: CGFloat)? {
            switch self {
            case .none: return nil
            case .soft: return (0.22, 1)
            case .bold: return (0.42, 1.5)
            }
        }
    }

    var fill: Fill
    /// The solid colour, or the gradient's first colour. Nil falls back to the
    /// group's own tint so a half-set appearance still draws something.
    var startColorHex: String?
    /// The gradient's second colour. Nil (or a solid fill) means one colour.
    var endColorHex: String?
    var direction: Direction
    var elevation: Elevation

    init(
        fill: Fill = .standard,
        startColorHex: String? = nil,
        endColorHex: String? = nil,
        direction: Direction = .down,
        elevation: Elevation = .none
    ) {
        self.fill = fill
        self.startColorHex = startColorHex
        self.endColorHex = endColorHex
        self.direction = direction
        self.elevation = elevation
    }

    /// The untouched default: the plate the sidebar has always drawn.
    static let standard = TabGroupAppearance()

    /// True when nothing has been customised, so the plate draws exactly as it
    /// did before this type existed. The renderer leans on this to keep default
    /// groups pixel-for-pixel unchanged.
    var isStandard: Bool { fill == .standard && elevation == .none }

    // MARK: - Colours

    /// The colour a `solid` fill paints, or a gradient's first stop.
    func startColor(fallback: NSColor) -> NSColor {
        startColorHex.flatMap(NSColor.init(hexString:)) ?? fallback
    }

    /// A gradient's second stop. A gradient with no end colour, or a solid
    /// fill, resolves to the start colour, so both stops are always defined.
    func endColor(fallback: NSColor) -> NSColor {
        endColorHex.flatMap(NSColor.init(hexString:)) ?? startColor(fallback: fallback)
    }

    /// The colours the plate is filled with, at the alpha that lets the
    /// sidebar's material still read through. Nil when the fill is `standard`.
    func gradient(fallback: NSColor) -> NSGradient? {
        guard fill != .standard else { return nil }
        let start = startColor(fallback: fallback).withAlphaComponent(Self.fillAlpha)
        let end = (fill == .gradient ? endColor(fallback: fallback) : startColor(fallback: fallback))
            .withAlphaComponent(Self.fillAlpha)
        return NSGradient(starting: start, ending: end)
    }

    /// How opaque a coloured plate is. Below one so it composites with the
    /// material underneath rather than reading as a flat rectangle, the same
    /// reasoning as `SpaceTheme.wash`, but stronger because a group card is
    /// meant to be seen as a card.
    static let fillAlpha: CGFloat = 0.85

    // MARK: - Convenience for the editor

    var startColorValue: NSColor? {
        get { startColorHex.flatMap(NSColor.init(hexString:)) }
        set { startColorHex = newValue?.hexString }
    }

    var endColorValue: NSColor? {
        get { endColorHex.flatMap(NSColor.init(hexString:)) }
        set { endColorHex = newValue?.hexString }
    }

    // MARK: - Tolerant decoding

    /// Each field falls back on its own, so a session written by a build with
    /// more or fewer of them still restores rather than refusing to open.
    private enum CodingKeys: String, CodingKey {
        case fill, startColorHex, endColorHex, direction, elevation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = TabGroupAppearance.standard
        fill = (try? container.decodeIfPresent(String.self, forKey: .fill)).flatMap(Fill.init(rawValue:)) ?? fallback.fill
        startColorHex = try? container.decodeIfPresent(String.self, forKey: .startColorHex)
        endColorHex = try? container.decodeIfPresent(String.self, forKey: .endColorHex)
        direction = (try? container.decodeIfPresent(String.self, forKey: .direction)).flatMap(Direction.init(rawValue:)) ?? fallback.direction
        elevation = (try? container.decodeIfPresent(String.self, forKey: .elevation)).flatMap(Elevation.init(rawValue:)) ?? fallback.elevation
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fill.rawValue, forKey: .fill)
        try container.encodeIfPresent(startColorHex, forKey: .startColorHex)
        try container.encodeIfPresent(endColorHex, forKey: .endColorHex)
        try container.encode(direction.rawValue, forKey: .direction)
        try container.encode(elevation.rawValue, forKey: .elevation)
    }
}
