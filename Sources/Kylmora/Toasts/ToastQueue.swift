import Foundation

/// Decides which toast is on screen and which are waiting.
///
/// Kept free of views and timers for the same reason `TabSuspension` is: the
/// rules that decide what the user sees are worth a unit test, and a rule that
/// only exists inside an animation callback is not testable at all.
@MainActor
struct ToastQueue {
    /// What the caller has to do to the screen after a mutation. The queue
    /// never talks to a view, so every change comes back as one of these.
    enum Effect: Equatable {
        /// Nothing on screen changed.
        case none
        /// Put this toast up. Replaces whatever was showing.
        case show(Toast.ID)
        /// Take the current toast down; nothing follows it.
        case hide
    }

    /// The backlog is capped because a queue longer than this is no longer
    /// telling the user anything: by the time the tenth message appears the
    /// event that caused it is long gone. New arrivals push the oldest waiting
    /// toast out rather than delaying the queue further.
    static let maxPending = 3

    private(set) var current: Toast?
    private(set) var pending: [Toast] = []

    var isEmpty: Bool { current == nil && pending.isEmpty }

    /// Adds a toast, showing it immediately when the spot is free.
    ///
    /// A toast whose `identity` matches one already here replaces it in place,
    /// which is what stops a repeated action stacking up copies of the same
    /// message. Replacing the *showing* toast deliberately restarts it: the
    /// second event is newer, and its countdown should reflect that.
    @discardableResult
    mutating func enqueue(_ toast: Toast) -> Effect {
        if let identity = toast.identity {
            if current?.identity == identity {
                current = toast
                return .show(toast.id)
            }
            if let index = pending.firstIndex(where: { $0.identity == identity }) {
                pending[index] = toast
                return .none
            }
        }

        guard current != nil else {
            current = toast
            return .show(toast.id)
        }

        pending.append(toast)
        if pending.count > Self.maxPending { pending.removeFirst() }
        return .none
    }

    /// Takes the current toast down and promotes the next one.
    @discardableResult
    mutating func dismissCurrent() -> Effect {
        guard current != nil else { return .none }
        guard !pending.isEmpty else {
            current = nil
            return .hide
        }
        let next = pending.removeFirst()
        current = next
        return .show(next.id)
    }

    /// Removes a specific toast wherever it is. Used when the thing a toast
    /// refers to disappears -- a routed tab closed before the toast expired --
    /// so the button can never act on something that is gone.
    @discardableResult
    mutating func remove(_ id: Toast.ID) -> Effect {
        if current?.id == id { return dismissCurrent() }
        pending.removeAll { $0.id == id }
        return .none
    }

    /// Clears everything at once, for a window closing or a space switch.
    @discardableResult
    mutating func removeAll() -> Effect {
        pending.removeAll()
        guard current != nil else { return .none }
        current = nil
        return .hide
    }
}
