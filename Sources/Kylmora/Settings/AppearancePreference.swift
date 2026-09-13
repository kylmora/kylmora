import AppKit

/// Which appearance the browser draws in.
///
/// Kept as its own type, and as pure a one as AppKit allows, because "follow the
/// system" is not the absence of a choice -- it is a third choice that has to be
/// stored, restored and shown as selected like the other two.
enum AppearancePreference: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    /// What the user sees in the menu and in Settings.
    var title: String {
        switch self {
        case .system: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The appearance to apply, or nil to stop overriding and let the system
    /// decide. `nil` is the whole reason this is not just an `NSAppearance`:
    /// there is no appearance object meaning "whatever the Mac is set to".
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    var appearance: NSAppearance? {
        appearanceName.flatMap(NSAppearance.init(named:))
    }

    /// Menu items identify their preference by tag rather than by
    /// `representedObject`. A tag is an `Int` and crosses into Objective-C
    /// unchanged; a Swift enum in an `Any?` has to survive being boxed and cast
    /// back, and when that fails it fails silently -- the menu item simply does
    /// nothing, which is a miserable thing to debug.
    var menuTag: Int {
        (Self.allCases.firstIndex(of: self) ?? 0) + 1
    }

    static func fromMenuTag(_ tag: Int) -> AppearancePreference? {
        let index = tag - 1
        return allCases.indices.contains(index) ? allCases[index] : nil
    }

    /// Tolerates a stored value from a future or corrupted build rather than
    /// refusing to launch over a preference.
    init(storedValue: String?) {
        self = AppearancePreference(rawValue: storedValue ?? "") ?? .system
    }
}
