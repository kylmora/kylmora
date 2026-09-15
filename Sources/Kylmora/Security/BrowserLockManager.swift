import AppKit
import LocalAuthentication

/// Coordinates browser locking, authentication (Touch ID / system password or master password),
/// idle timeout detection, and lock overlay presentation.
@MainActor
public final class BrowserLockManager: NSObject {
    public static let shared = BrowserLockManager()

    public private(set) var isLocked: Bool = false
    public var lastActivityDate: Date = Date()

    private var idleTimer: Timer?
    private var localEventMonitor: Any?
    private var overlays: [NSWindow: LockOverlayView] = [:]
    private let settings = Settings.shared

    public override init() {
        super.init()
    }

    /// Initializes activity tracking, sleep hooks, and launch lock.
    public func start() {
        setupEventMonitors()
        setupSleepObservers()
        startIdleTimer()

        if settings.browserLockEnabled && settings.browserLockOnLaunch {
            // Lock immediately on launch
            lock(animated: false)
        }
    }

    /// Manually or automatically locks the browser.
    public func lock(animated: Bool = true) {
        guard !isLocked else { return }
        isLocked = true

        NotificationCenter.default.post(name: .browserLockStateDidChange, object: self)

        for window in NSApp.windows where shouldWindowBeLocked(window) {
            presentOverlay(on: window, animated: animated)
        }

        if settings.browserLockMethod == .touchIDOrPasscode {
            Task {
                await authenticateWithBiometrics()
            }
        }
    }

    /// Unlocks the browser and removes all lock overlays.
    public func unlock(animated: Bool = true) {
        guard isLocked else { return }
        isLocked = false
        lastActivityDate = Date()

        for (window, overlay) in overlays {
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    overlay.animator().alphaValue = 0
                } completionHandler: {
                    MainActor.assumeIsolated {
                        overlay.removeFromSuperview()
                    }
                }
            } else {
                overlay.removeFromSuperview()
            }
        }
        overlays.removeAll()

        NotificationCenter.default.post(name: .browserLockStateDidChange, object: self)
    }

    /// Presents a lock overlay on a given window if the browser is currently locked.
    public func attachOverlayIfNeeded(to window: NSWindow) {
        guard isLocked, shouldWindowBeLocked(window), overlays[window] == nil else { return }
        presentOverlay(on: window, animated: false)
    }

    private func presentOverlay(on window: NSWindow, animated: Bool) {
        guard let contentView = window.contentView else { return }
        if let existing = overlays[window] {
            existing.removeFromSuperview()
        }

        let overlay = LockOverlayView()
        overlay.applyMethod(settings.browserLockMethod)

        overlay.onBiometricUnlockRequested = { [weak self] in
            Task { @MainActor in
                await self?.authenticateWithBiometrics()
            }
        }

        overlay.onPasswordUnlockRequested = { [weak self] password in
            guard let self else { return false }
            return self.verifyAndUnlock(with: password)
        }

        contentView.addSubview(overlay, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        overlays[window] = overlay

        if animated {
            overlay.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                overlay.animator().alphaValue = 1
            } completionHandler: {
                MainActor.assumeIsolated {
                    overlay.focusInput()
                }
            }
        } else {
            overlay.alphaValue = 1
            overlay.focusInput()
        }
    }

    /// Evaluates Touch ID or local machine password via LocalAuthentication.
    @discardableResult
    public func authenticateWithBiometrics() async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "Enter Password"
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // If biometrics/passcode are not supported or available, unlock if no master password
            if !MasterPasswordStore.hasMasterPassword() {
                unlock()
                return true
            }
            return false
        }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Kylmora") { success, _ in
                Task { @MainActor in
                    if success {
                        self.unlock()
                    }
                    continuation.resume(returning: success)
                }
            }
        }
    }

    /// Verifies the entered candidate master password.
    public func verifyAndUnlock(with password: String) -> Bool {
        if MasterPasswordStore.verifyMasterPassword(password) {
            unlock()
            return true
        }
        return false
    }

    private func shouldWindowBeLocked(_ window: NSWindow) -> Bool {
        // Exclude system panels, menus, and hidden windows
        guard window.isVisible, !(window is NSPanel) else { return false }
        // Lock BrowserWindow and other document windows
        return true
    }

    // MARK: - Activity & Idle Monitoring

    private func setupEventMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .mouseMoved, .scrollWheel]
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.recordActivity()
            return event
        }
    }

    private func recordActivity() {
        lastActivityDate = Date()
    }

    private func setupSleepObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(workspaceWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(workspaceWillSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
    }

    @objc private func workspaceWillSleep() {
        guard settings.browserLockEnabled else { return }
        lock(animated: false)
    }

    private func startIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkIdleTimeout()
            }
        }
    }

    private func checkIdleTimeout() {
        guard settings.browserLockEnabled, !isLocked else { return }
        let timeout = settings.browserLockIdleTimeout.rawValue
        guard timeout > 0 else { return }

        let elapsed = Date().timeIntervalSince(lastActivityDate)
        if elapsed >= Double(timeout) {
            lock(animated: true)
        }
    }

    public func stop() {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        idleTimer?.invalidate()
        idleTimer = nil
    }
}
