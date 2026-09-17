import AppKit

/// How a space is painted, as the Spaces pane offers it.
///
/// Shared rather than owned by that pane, because the New Space sheet asks the
/// same question while the space is being made, and it has to be the same
/// question: the same five choices under the same names. A sheet that invents
/// its own vocabulary -- a shorter list, or "Colour strength" for what the pane
/// calls Transparency -- teaches the user something they then have to unlearn.
/// The Appearance control's five choices. The first three are the plain,
/// untinted looks (a `neutral` space in that appearance); the fourth stands
/// for "this space has a colour of its own". Which one a space shows as is
/// read back from its state, so there is no separate flag to keep in sync.
enum SpaceAppearanceChoice: Int, CaseIterable {
    case automatic, light, dark, customized, website

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        case .customized: return "Customized"
        case .website: return "Website"
        }
    }

    /// The plain appearance a preset paints in. `nil` for Customized and
    /// Website, which follow the system rather than fixing light or dark.
    var presetAppearance: AppearancePreference? {
        switch self {
        case .automatic: return .system
        case .light: return .light
        case .dark: return .dark
        case .customized, .website: return nil
        }
    }

    /// Which segment a space currently reads as. Website wins when the
    /// space lets pages colour it; else a space with a colour of its own --
    /// a tint or a gradient -- is customised, and an untinted one is its
    /// plain appearance.
    @MainActor
    static func of(_ space: Space) -> SpaceAppearanceChoice {
        if space.look.allowsWebsiteThemeColor { return .website }
        guard space.look.gradient == nil, !space.theme.tintsChrome else { return .customized }
        switch space.look.appearance {
        case .system: return .automatic
        case .light: return .light
        case .dark: return .dark
        }
    }
}
