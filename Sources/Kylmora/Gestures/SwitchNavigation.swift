import Foundation

/// Index arithmetic for moving between spaces.
///
/// Small enough to inline at each call site and wrong often enough there that
/// it should not be. Every switch path -- the keyboard shortcut, the scroll
/// wheel, the swipe -- lands here, so "does it wrap" is answered once.
enum SwitchNavigation {

    /// The space `offset` steps from `index`, or nil when the move is not
    /// possible.
    ///
    /// - Parameter wraps: past the last space, start again at the first. On by
    ///   default because a repeated shortcut that silently stops at the end is
    ///   indistinguishable from one that has stopped working. Clamping is the
    ///   right answer for a drag, where the edge has to be felt.
    static func destination(
        from index: Int,
        offset: Int,
        count: Int,
        wraps: Bool = true
    ) -> Int? {
        guard count > 0, (0..<count).contains(index) else { return nil }
        guard offset != 0 else { return index }
        guard count > 1 else { return nil }

        let raw = index + offset
        if wraps {
            // `%` in Swift keeps the sign of the dividend, so a negative offset
            // needs the extra `+ count` before it means anything.
            return ((raw % count) + count) % count
        }
        let clamped = min(max(raw, 0), count - 1)
        return clamped == index ? nil : clamped
    }

    /// Signed distance from `index` to `target`, taking the shorter way round.
    ///
    /// This is what lays the strip out during a switch: with five spaces,
    /// moving from the first to the last is one step left, not four steps
    /// right, and animating it the long way is both slower and a lie about
    /// where the spaces are.
    static func shortestDistance(from index: Int, to target: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var difference = target - index
        let half = count / 2
        if difference > half {
            difference -= count
        } else if difference < -half {
            difference += count
        }
        return difference
    }
}
