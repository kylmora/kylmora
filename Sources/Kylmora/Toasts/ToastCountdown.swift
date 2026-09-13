import Foundation

/// The auto-dismiss clock, as arithmetic rather than as a timer.
///
/// Pausing on hover is the reason this is not simply a `Task.sleep`: the
/// remaining time has to survive being stopped and started, and "how much is
/// left" is exactly the kind of off-by-one that a test should catch rather
/// than a user noticing a toast that never goes away.
struct ToastCountdown: Equatable {
    private let duration: TimeInterval
    /// When the current run began, or nil while paused.
    private var startedAt: Date?
    /// Time already spent on screen before the current run.
    private var elapsed: TimeInterval

    var isRunning: Bool { startedAt != nil }

    init(duration: TimeInterval, startedAt: Date) {
        self.duration = max(duration, 0)
        self.startedAt = startedAt
        self.elapsed = 0
    }

    /// Time left before the toast should come down. Zero means now.
    func remaining(at now: Date) -> TimeInterval {
        let spent = elapsed + (startedAt.map { max(now.timeIntervalSince($0), 0) } ?? 0)
        return max(duration - spent, 0)
    }

    func hasExpired(at now: Date) -> Bool { remaining(at: now) == 0 }

    /// Stops the clock, banking what has been spent so far.
    mutating func pause(at now: Date) {
        guard let startedAt else { return }
        elapsed += max(now.timeIntervalSince(startedAt), 0)
        self.startedAt = nil
    }

    mutating func resume(at now: Date) {
        guard startedAt == nil else { return }
        startedAt = now
    }
}
