import Foundation

/// The two things about toasts a user may reasonably want to change.
///
/// On `UserDefaults`, like `Settings`, and for the same reason: macOS already
/// has atomic, sandbox-aware preference storage. These live here rather than in
/// `Settings` so the toast layer has no reason to reach into the rest of the
/// app; the Settings window reads them through this type.
@MainActor
final class ToastPreferences {
    static let shared = ToastPreferences()

    private enum Key {
        static let showsRoutedTabToast = "toastsShowRoutedTab"
        static let dismissSeconds = "toastDismissSeconds"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.showsRoutedTabToast: true,
            Key.dismissSeconds: Toast.defaultDuration
        ])
    }

    /// Whether a tab that space routing sent somewhere else announces itself.
    /// Off means routing still happens; it just happens quietly.
    var showsRoutedTabToast: Bool {
        get { defaults.bool(forKey: Key.showsRoutedTabToast) }
        set { defaults.set(newValue, forKey: Key.showsRoutedTabToast) }
    }

    /// Choices offered in Settings, in seconds.
    static let dismissChoices: [TimeInterval] = [2, 4, 8]

    /// How long a toast stays up. Clamped rather than trusted: a zero here
    /// would make every toast unreadable, and the value is in a plist a user
    /// can edit by hand.
    var dismissInterval: TimeInterval {
        get { min(max(defaults.double(forKey: Key.dismissSeconds), 1), 30) }
        set { defaults.set(newValue, forKey: Key.dismissSeconds) }
    }
}
