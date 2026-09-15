import Foundation

/// Defines the display scope for tabs in the Safari-style Tab Overview grid.
enum TabOverviewScope: Int, CaseIterable, Sendable {
    /// Show only tabs in the currently active space.
    case currentSpace = 0
    /// Show all tabs across all spaces in the browser.
    case allSpaces = 1

    var title: String {
        switch self {
        case .currentSpace:
            return "Current Space"
        case .allSpaces:
            return "All Spaces"
        }
    }
}
