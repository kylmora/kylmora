import AppKit
import Foundation

/// The sheet after an update: which version this now is, and where its notes
/// are. Shown once per version, and never on a first launch, which has no
/// "before" to compare with.
enum WhatsNew {
    static let releasesPage = URL(string: "https://github.com/kylmora/kylmora/releases")!

    /// Whether to show: a previous version is known and it differs.
    static func shouldShow(previous: String?, current: String) -> Bool {
        guard let previous, !previous.isEmpty, !current.isEmpty, current != "0" else { return false }
        return AppVersion(previous) != AppVersion(current)
    }

    /// The notes for a version live on the release the tag made.
    static func releaseNotesURL(for version: String) -> URL {
        releasesPage.appending(path: "tag/v\(version)")
    }

    /// Runs the once-per-version check and shows the sheet if due.
    @MainActor
    static func presentIfNeeded(on window: NSWindow?, settings: Settings = .shared) {
        let current = AppInfo.version
        let previous = settings.lastLaunchedVersion
        settings.lastLaunchedVersion = current
        guard shouldShow(previous: previous, current: current), let window else { return }
        let alert = NSAlert()
        alert.messageText = "Kylmora was updated to \(current)"
        alert.informativeText = "You were on \(previous ?? "an earlier version"). The release notes list what changed."
        alert.addButton(withTitle: "Read the Release Notes")
        alert.addButton(withTitle: "Continue")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.open(releaseNotesURL(for: current))
        }
    }
}
