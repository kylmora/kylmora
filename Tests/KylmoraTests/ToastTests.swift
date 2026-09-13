import Foundation
import Testing
@testable import Kylmora

@Suite("Toast queueing and timing")
@MainActor
struct ToastTests {
    private func toast(_ message: String, identity: String? = nil, duration: TimeInterval = 2) -> Toast {
        Toast(symbolName: "info.circle", message: message, duration: duration, identity: identity)
    }

    @Test("The first toast shows immediately")
    func firstToastShows() {
        var queue = ToastQueue()
        let first = toast("Saved")
        #expect(queue.enqueue(first) == .show(first.id))
        #expect(queue.current?.id == first.id)
        #expect(queue.pending.isEmpty)
    }

    @Test("A second toast waits rather than replacing the one on screen")
    func secondToastWaits() {
        var queue = ToastQueue()
        let first = toast("Saved")
        let second = toast("Copied")
        queue.enqueue(first)

        #expect(queue.enqueue(second) == .none)
        #expect(queue.current?.id == first.id)
        #expect(queue.pending.count == 1)

        #expect(queue.dismissCurrent() == .show(second.id))
        #expect(queue.current?.id == second.id)
        #expect(queue.pending.isEmpty)
    }

    @Test("Dismissing the last toast leaves nothing on screen")
    func dismissingLastToastHides() {
        var queue = ToastQueue()
        queue.enqueue(toast("Saved"))
        #expect(queue.dismissCurrent() == .hide)
        #expect(queue.isEmpty)
        // Dismissing an empty queue is a no-op, not a second hide.
        #expect(queue.dismissCurrent() == .none)
    }

    @Test("A repeat of the showing toast replaces it in place and restarts it")
    func repeatReplacesCurrent() {
        var queue = ToastQueue()
        queue.enqueue(toast("Opened in Work", identity: "space-routing"))
        let repeated = toast("Opened in Personal", identity: "space-routing")

        #expect(queue.enqueue(repeated) == .show(repeated.id))
        #expect(queue.current?.message == "Opened in Personal")
        #expect(queue.pending.isEmpty)
    }

    @Test("A repeat of a waiting toast replaces it without disturbing the screen")
    func repeatReplacesPending() {
        var queue = ToastQueue()
        queue.enqueue(toast("Saved"))
        queue.enqueue(toast("Opened in Work", identity: "space-routing"))

        #expect(queue.enqueue(toast("Opened in Personal", identity: "space-routing")) == .none)
        #expect(queue.pending.count == 1)
        #expect(queue.pending.first?.message == "Opened in Personal")
    }

    @Test("Toasts with no identity never collapse into each other")
    func distinctToastsQueue() {
        var queue = ToastQueue()
        queue.enqueue(toast("One"))
        queue.enqueue(toast("Two"))
        queue.enqueue(toast("Three"))
        #expect(queue.pending.count == 2)
    }

    @Test("The backlog is capped, dropping the oldest waiting toast")
    func backlogIsCapped() {
        var queue = ToastQueue()
        queue.enqueue(toast("Showing"))
        for index in 0..<(ToastQueue.maxPending + 2) {
            queue.enqueue(toast("Waiting \(index)"))
        }
        #expect(queue.pending.count == ToastQueue.maxPending)
        #expect(queue.pending.first?.message == "Waiting 2")
    }

    @Test("A toast can be withdrawn from anywhere in the queue")
    func removingAToast() {
        var queue = ToastQueue()
        let showing = toast("Showing")
        let waiting = toast("Waiting")
        queue.enqueue(showing)
        queue.enqueue(waiting)

        #expect(queue.remove(waiting.id) == .none)
        #expect(queue.pending.isEmpty)
        #expect(queue.remove(showing.id) == .hide)
        #expect(queue.isEmpty)
    }

    @Test("Clearing everything takes the current toast down once")
    func removeAll() {
        var queue = ToastQueue()
        queue.enqueue(toast("One"))
        queue.enqueue(toast("Two"))
        #expect(queue.removeAll() == .hide)
        #expect(queue.isEmpty)
        #expect(queue.removeAll() == .none)
    }

    @Test("A countdown expires exactly at its duration")
    func countdownExpires() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let countdown = ToastCountdown(duration: 2, startedAt: start)

        #expect(countdown.remaining(at: start) == 2)
        #expect(countdown.remaining(at: start.addingTimeInterval(1.5)) == 0.5)
        #expect(!countdown.hasExpired(at: start.addingTimeInterval(1.9)))
        #expect(countdown.hasExpired(at: start.addingTimeInterval(2)))
    }

    @Test("Hovering banks the time already spent and stops the clock")
    func countdownPauses() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var countdown = ToastCountdown(duration: 2, startedAt: start)

        countdown.pause(at: start.addingTimeInterval(0.5))
        #expect(!countdown.isRunning)
        // An hour under the pointer does not consume any of the two seconds.
        #expect(countdown.remaining(at: start.addingTimeInterval(3600)) == 1.5)

        countdown.resume(at: start.addingTimeInterval(3600))
        #expect(countdown.isRunning)
        #expect(countdown.remaining(at: start.addingTimeInterval(3601)) == 0.5)
        #expect(countdown.hasExpired(at: start.addingTimeInterval(3601.5)))
    }

    @Test("A preference below a readable minimum is clamped rather than obeyed")
    func dismissIntervalIsClamped() {
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
        let preferences = ToastPreferences(defaults: defaults)
        #expect(preferences.dismissInterval == Toast.defaultDuration)

        preferences.dismissInterval = 0
        #expect(preferences.dismissInterval == 1)
        preferences.dismissInterval = 600
        #expect(preferences.dismissInterval == 30)
    }
}
