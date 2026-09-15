import Foundation

/// A cardinal stroke direction in a mouse gesture.
public enum MouseGestureDirection: String, Sendable, CaseIterable, Equatable {
    case left = "L"
    case right = "R"
    case up = "U"
    case down = "D"

    public var symbol: String {
        switch self {
        case .left: return "←"
        case .right: return "→"
        case .up: return "↑"
        case .down: return "↓"
        }
    }
}

/// An action performed in response to a recognized mouse gesture.
public enum MouseGestureAction: String, Sendable, CaseIterable, Equatable {
    case back = "back"
    case forward = "forward"
    case newTab = "new-tab"
    case closeTab = "close-tab"
    case reload = "reload"
    case reopenClosedTab = "reopen-closed-tab"
    case scrollToTop = "scroll-to-top"
    case nextTab = "next-tab"
    case previousTab = "previous-tab"

    public var title: String {
        switch self {
        case .back: return "Back"
        case .forward: return "Forward"
        case .newTab: return "New Tab"
        case .closeTab: return "Close Tab"
        case .reload: return "Reload Page"
        case .reopenClosedTab: return "Reopen Closed Tab"
        case .scrollToTop: return "Scroll to Top"
        case .nextTab: return "Next Tab"
        case .previousTab: return "Previous Tab"
        }
    }

    public var symbolName: String {
        switch self {
        case .back: return "arrow.left"
        case .forward: return "arrow.right"
        case .newTab: return "plus"
        case .closeTab: return "xmark"
        case .reload: return "arrow.clockwise"
        case .reopenClosedTab: return "arrow.uturn.backward"
        case .scrollToTop: return "arrow.up"
        case .nextTab: return "arrow.right.to.line"
        case .previousTab: return "arrow.left.to.line"
        }
    }

    /// Matches an ordered sequence of cardinal directions to a browser action.
    public static func match(strokes: [MouseGestureDirection]) -> MouseGestureAction? {
        switch strokes {
        case [.left]:
            return .back
        case [.right]:
            return .forward
        case [.down]:
            return .newTab
        case [.up]:
            return .scrollToTop
        case [.up, .down]:
            return .reload
        case [.down, .right]:
            return .closeTab
        case [.down, .left]:
            return .reopenClosedTab
        case [.up, .right]:
            return .nextTab
        case [.up, .left]:
            return .previousTab
        default:
            return nil
        }
    }
}

/// Utility for calculating stroke directions from 2D mouse deltas.
public enum MouseGestureRecognizer {
    /// Classifies an (x, y) vector in AppKit coordinate space (y up) into a cardinal direction.
    ///
    /// - Parameters:
    ///   - dx: Horizontal delta (positive is right).
    ///   - dy: Vertical delta (positive is up).
    ///   - minThreshold: Minimum displacement required to register a stroke.
    /// - Returns: Cardinal direction if threshold exceeded, nil otherwise.
    public static func direction(dx: CGFloat, dy: CGFloat, minThreshold: CGFloat = 20.0) -> MouseGestureDirection? {
        let distance = hypot(dx, dy)
        guard distance >= minThreshold else { return nil }

        if abs(dx) > abs(dy) {
            return dx > 0 ? .right : .left
        } else {
            return dy > 0 ? .up : .down
        }
    }

    /// Formats a list of directions into a readable string of arrows, e.g. "↓ →".
    public static func formatStrokes(_ strokes: [MouseGestureDirection]) -> String {
        strokes.map(\.symbol).joined(separator: " ")
    }
}
