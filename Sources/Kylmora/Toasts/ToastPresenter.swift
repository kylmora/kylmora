import AppKit

/// Shows toasts over a host view, one at a time.
///
/// The whole API is `show`, `dismiss` and `dismissAll`: anything that wants to
/// tell the user something builds a `Toast` and hands it over, and never learns
/// whether it went up immediately or waited behind another. Ordering,
/// timing and the view all live behind that.
@MainActor
final class ToastPresenter {
    private weak var hostView: NSView?
    private let preferences: ToastPreferences

    private var queue = ToastQueue()
    private var countdown: ToastCountdown?
    private var expiry: Task<Void, Never>?

    private var toastView: ToastView?
    private var bottomConstraint: NSLayoutConstraint?

    /// The distance the toast travels as it appears. Small enough to read as
    /// the toast arriving rather than as a panel sliding, which is the
    /// difference between a notification and a sheet.
    private static let entryOffset: CGFloat = 12
    /// A toast never spans a wide window: a line of text 500 points long is
    /// read as a banner, and the eye has to travel to find the button.
    private static let maxWidth: CGFloat = 460

    init(hostView: NSView, preferences: ToastPreferences = .shared) {
        self.hostView = hostView
        self.preferences = preferences
    }

    /// Shows a toast, or queues it behind the one already up.
    ///
    /// A toast with no explicit duration takes the user's preference, so the
    /// caller states what it wants to say and not how long the user needs to
    /// read it.
    func show(_ toast: Toast) {
        var toast = toast
        if toast.duration == Toast.defaultDuration {
            toast.duration = preferences.dismissInterval
        }
        apply(queue.enqueue(toast))
    }

    /// Takes the current toast down early, promoting whatever was waiting.
    func dismiss() {
        apply(queue.dismissCurrent())
    }

    /// Drops a specific toast wherever it is, for when the thing it refers to
    /// has gone away.
    func dismiss(_ id: Toast.ID) {
        apply(queue.remove(id))
    }

    func dismissAll() {
        apply(queue.removeAll())
    }

    // MARK: - Queue effects

    private func apply(_ effect: ToastQueue.Effect) {
        switch effect {
        case .none:
            break
        case .show:
            guard let toast = queue.current else { return }
            present(toast)
        case .hide:
            tearDown()
        }
    }

    private func present(_ toast: Toast) {
        guard let hostView else { return }

        toastView?.removeFromSuperview()

        let view = ToastView(
            toast: toast,
            onAction: { [weak self] in
                toast.action?.handler()
                self?.dismiss()
            },
            onDismiss: { [weak self] in self?.dismiss() },
            onHoverChange: { [weak self] isHovered in self?.setPaused(isHovered) }
        )
        hostView.addSubview(view)

        let bottom = view.bottomAnchor.constraint(
            equalTo: hostView.bottomAnchor,
            constant: -ToastMetrics.edgeOffset + Self.entryOffset
        )
        let width = view.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth)
        // The toast must not push past the window when the message is long,
        // and must not be wider than the page it is drawn over.
        let fit = view.trailingAnchor.constraint(
            lessThanOrEqualTo: hostView.trailingAnchor,
            constant: -ToastMetrics.edgeOffset
        )
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: hostView.leadingAnchor, constant: ToastMetrics.edgeOffset),
            fit,
            width,
            bottom
        ])

        toastView = view
        bottomConstraint = bottom

        // Laid out at its resting position first, and then sprung *to* it
        // from below. The constraint no longer animates: a constraint cannot
        // overshoot, and an entry animation split between Auto Layout and a
        // spring would have the toast's frame and its transform disagreeing
        // about where it is for the whole of the bounce.
        bottom.constant = -ToastMetrics.edgeOffset
        hostView.layoutSubtreeIfNeeded()
        SpringPresence.appear(view, rising: Self.entryOffset)

        startCountdown(for: toast)
    }

    private func tearDown() {
        expiry?.cancel()
        expiry = nil
        countdown = nil

        guard let view = toastView else { return }
        toastView = nil
        // It leaves the way it came, back down and slightly smaller, and only
        // then leaves the view tree. No spring on the way out: see
        // `SpringPresence`.
        SpringPresence.disappear(view, falling: Self.entryOffset) {
            view.removeFromSuperview()
        }
        bottomConstraint = nil
    }

    // MARK: - Timing

    private func startCountdown(for toast: Toast) {
        countdown = ToastCountdown(duration: toast.duration, startedAt: .now)
        scheduleExpiry()
    }

    /// Hovering holds the toast open. Without this, a toast with a button is a
    /// target that moves away while the user is reaching for it.
    private func setPaused(_ isPaused: Bool) {
        guard var countdown else { return }
        if isPaused {
            countdown.pause(at: .now)
            self.countdown = countdown
            expiry?.cancel()
            expiry = nil
        } else {
            countdown.resume(at: .now)
            self.countdown = countdown
            scheduleExpiry()
        }
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        guard let countdown else { return }
        let remaining = countdown.remaining(at: .now)
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self?.expire()
        }
    }

    /// A wake-up is not proof the time is up: the pointer may have paused the
    /// clock after this task was scheduled.
    private func expire() {
        guard let countdown, countdown.hasExpired(at: .now) else { return }
        dismiss()
    }
}
