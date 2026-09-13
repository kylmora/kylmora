import Foundation

/// The line a gradient runs along, shared by a tab group's plate and a space's
/// wash. Six, not a free angle: a fixed set is a row of buttons the user can
/// pick from at a glance, and the diagonals and axes are the ones anyone
/// reaches for.
enum GradientDirection: String, Codable, CaseIterable, Sendable {
    case down, up, right, left, downRight, upRight

    var title: String {
        switch self {
        case .down: return "Top to bottom"
        case .up: return "Bottom to top"
        case .right: return "Left to right"
        case .left: return "Right to left"
        case .downRight: return "Diagonal down"
        case .upRight: return "Diagonal up"
        }
    }

    /// The arrow shown on the direction button.
    var symbolName: String {
        switch self {
        case .down: return "arrow.down"
        case .up: return "arrow.up"
        case .right: return "arrow.right"
        case .left: return "arrow.left"
        case .downRight: return "arrow.down.right"
        case .upRight: return "arrow.up.right"
        }
    }

    /// Degrees for `NSGradient.draw(in:angle:)`. A plate is drawn in a flipped
    /// view, where +y points down, so 90° runs the gradient from top to bottom
    /// and the diagonals fall out from there.
    var angle: CGFloat {
        switch self {
        case .right: return 0
        case .left: return 180
        case .down: return 90
        case .up: return 270
        case .downRight: return 45
        case .upRight: return 315
        }
    }

    /// The gradient's ends in a `CAGradientLayer`'s unit coordinates, where
    /// (0,0) is bottom-left and (1,1) is top-left's diagonal opposite -- the
    /// top of the layer is y = 1. The first colour sits at `start`.
    var layerPoints: (start: CGPoint, end: CGPoint) {
        switch self {
        case .down: return (CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0))
        case .up: return (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1))
        case .right: return (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5))
        case .left: return (CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5))
        case .downRight: return (CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0))
        case .upRight: return (CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1))
        }
    }
}
