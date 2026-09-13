import AppKit
import Dispatch

/// Drives `TabSuspension`: a periodic idle check and the system's own
/// memory-pressure signal.
///
/// `DispatchSource.makeMemoryPressureSource` is the same kernel signal macOS
/// uses to manage memory itself, so the browser reacts to real pressure rather
/// than to a threshold we invented.
@MainActor
final class TabSuspender {
    /// How often idle tabs are checked. Well below the shortest idle threshold
    /// the user can choose, and cheap: it walks a list and compares dates.
    private static let checkInterval: TimeInterval = 30

    private let session: BrowserSession
    private let settings: Settings
    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var activationObservers: [NSObjectProtocol] = []

    init(session: BrowserSession, settings: Settings = .shared) {
        self.session = session
        self.settings = settings
    }

    func start() {
        guard timer == nil else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate(.idle) }
        }
        // Measured: App Nap defers a tolerant timer in a background app almost
        // indefinitely, so a sweep can be an hour late. A small tolerance keeps
        // the timer useful while the app is in front; the notifications below
        // cover the case where it was not.
        timer.tolerance = 5
        self.timer = timer

        // Sweeping when the app is activated catches up on everything App Nap
        // deferred, which is exactly when reclaimed memory matters to the user.
        // Sweeping on deactivation releases background tabs on the way out.
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate(.idle) }
            }
            activationObservers.append(observer)
        }

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, let event = self.pressureSource?.data else { return }
            MainActor.assumeIsolated {
                self.evaluate(event.contains(.critical) ? .memoryCritical : .memoryWarning)
            }
        }
        source.resume()
        pressureSource = source
    }

    /// Callers own the lifetime: `AppDelegate` starts this at launch and the
    /// app process ends with it. A `deinit` cannot touch the timer, which is
    /// not `Sendable`.
    func stop() {
        timer?.invalidate()
        timer = nil
        pressureSource?.cancel()
        pressureSource = nil
        activationObservers.forEach(NotificationCenter.default.removeObserver)
        activationObservers.removeAll()
    }

    private func evaluate(_ trigger: TabSuspension.Trigger) {
        let tabs = session.allTabs
        let candidates = TabSuspension.candidates(
            among: tabs,
            protecting: session.visibleTabIDs,
            idleThreshold: settings.tabSuspensionDelay,
            trigger: trigger,
            cohorts: session.splitCohorts
        )

        if Metrics.isLoggingEnabled {
            let loaded = tabs.filter(\.isLoaded)
            let idles = loaded.map { Int(Date.now.timeIntervalSince($0.lastActiveAt)) }
            Metrics.log("""
                sweep trigger=\(trigger) tabs=\(tabs.count) loaded=\(loaded.count) \
                candidates=\(candidates.count) idleSeconds=\(idles.sorted(by: >))
                """)
        }

        guard !candidates.isEmpty else { return }
        session.suspend(candidates)
    }
}
