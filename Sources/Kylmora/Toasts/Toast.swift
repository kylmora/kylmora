import Foundation

/// A transient message shown over the page.
///
/// A value type with a closure in it, so the thing that raises a toast decides
/// what its button does without the toast layer knowing anything about tabs,
/// spaces or the session. It is deliberately not `Equatable`: two toasts are
/// the same toast only when they say so, through `identity`.
@MainActor
struct Toast: Identifiable {
    /// The button on the right of a toast. One at most: a notification that
    /// offers a choice is a dialog, and a dialog is not transient.
    struct Action {
        var title: String
        var handler: () -> Void

        init(title: String, handler: @escaping () -> Void) {
            self.title = title
            self.handler = handler
        }
    }

    let id = UUID()

    /// SF Symbol shown at the leading edge.
    var symbolName: String
    var message: String
    var action: Action?

    /// How long the toast stays on screen once it is showing. It dismisses
    /// after two seconds and pauses while the pointer is over the toast; the
    /// pause is what makes two seconds enough for a message with a button.
    var duration: TimeInterval

    /// Collapses repeats. A second toast with the same identity replaces the
    /// first rather than queueing behind it, so holding down "open in
    /// background" leaves one message rather than a backlog of twelve.
    var identity: String?

    static let defaultDuration: TimeInterval = 2

    init(
        symbolName: String,
        message: String,
        action: Action? = nil,
        duration: TimeInterval = Toast.defaultDuration,
        identity: String? = nil
    ) {
        self.symbolName = symbolName
        self.message = message
        self.action = action
        self.duration = duration
        self.identity = identity
    }
}
