import Foundation

/// The display mode of the sidebar.
public enum SidebarMode: String, Codable, CaseIterable, Sendable {
    /// Always visible at full width (~260 pt).
    case expanded = "expanded"
    /// Narrow icons-only strip (~60 pt) that smoothly expands to full width on hover.
    case iconsOnly = "iconsOnly"
    /// Fully hidden offscreen; slides in as a floating overlay on edge hover.
    case compact = "compact"
    /// Hidden until explicitly toggled.
    case hidden = "hidden"

    public var title: String {
        switch self {
        case .expanded: return "Always Expanded"
        case .iconsOnly: return "Icons Only (Expand on Hover)"
        case .compact: return "Compact (Slide in on Hover)"
        case .hidden: return "Hidden"
        }
    }
}

/// Docking edge of the sidebar.
public enum SidebarPosition: String, Codable, CaseIterable, Sendable {
    case leading = "left"
    case trailing = "right"

    public var title: String {
        switch self {
        case .leading: return "Left"
        case .trailing: return "Right"
        }
    }
}

/// Hover delay preset before the sidebar expands or reveals.
public enum SidebarHoverDelayPreset: Double, CaseIterable, Sendable {
    case instant = 0.0
    case quick = 0.15
    case balanced = 0.25
    case deliberate = 0.40

    public var title: String {
        switch self {
        case .instant: return "Instant (0 ms)"
        case .quick: return "Quick (150 ms)"
        case .balanced: return "Balanced (250 ms)"
        case .deliberate: return "Deliberate (400 ms)"
        }
    }

    public static func preset(for seconds: Double) -> SidebarHoverDelayPreset {
        allCases.min(by: { abs($0.rawValue - seconds) < abs($1.rawValue - seconds) }) ?? .balanced
    }
}

extension Notification.Name {
    public static let sidebarModeDidChange = Notification.Name("com.kylmora.Kylmora.sidebarModeDidChange")
    public static let sidebarPositionDidChange = Notification.Name("com.kylmora.Kylmora.sidebarPositionDidChange")
    public static let sidebarHoverDelayDidChange = Notification.Name("com.kylmora.Kylmora.sidebarHoverDelayDidChange")
    public static let zenModeDidChange = Notification.Name("com.kylmora.Kylmora.zenModeDidChange")
}
