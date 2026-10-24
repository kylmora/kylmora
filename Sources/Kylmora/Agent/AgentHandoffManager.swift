import AppKit
import Foundation

extension Notification.Name {
    static let agentHandoffStateDidChange = Notification.Name("com.kylmora.agent.handoffStateDidChange")
}

/// Who holds the page: the agent, the user, or nobody.
///
/// Modelled on ego lite's task spaces. Control is exclusive, never shared:
/// while the agent drives, the page is fenced off from the user's pointer, and
/// the moment the user takes over — by the "Take over" button, or because the
/// agent handed off for a captcha or a login — every agent call fails at once
/// with `AgentError.userInControl` instead of hanging. The agent gets the page
/// back only when the user gives it back, or when it explicitly resumes after
/// the user said they were done.
@MainActor
public final class AgentHandoffManager {
    public static let shared = AgentHandoffManager()

    public enum State: Equatable {
        case idle
        case agentDriving(task: String)
        /// `requestedByAgent` is true for a hand-off (captcha, 2FA) and false
        /// when the user grabbed the page themselves.
        case userInControl(reason: String, requestedByAgent: Bool)
    }

    public private(set) var currentState: State = .idle {
        didSet {
            guard currentState != oldValue else { return }
            NotificationCenter.default.post(name: .agentHandoffStateDidChange, object: nil)
        }
    }

    /// The last task the agent described, kept across a hand-off so the bar
    /// can say what will resume.
    public private(set) var activeTask: String = ""

    /// An agent that stops calling without finishing must not leave the page
    /// fenced off forever.
    var idleTimeout: TimeInterval = 90
    private var idleTimer: Timer?
    private var controlWaiters: [CheckedContinuation<Void, Never>] = []

    public var isUserControlling: Bool {
        if case .userInControl = currentState { return true }
        return false
    }

    public var isAgentDriving: Bool {
        if case .agentDriving = currentState { return true }
        return false
    }

    var handoffReason: String {
        if case .userInControl(let reason, _) = currentState { return reason }
        return ""
    }

    // MARK: - Agent side

    /// Called before every agent action. Fails fast while the user holds the page.
    func beginAction(_ task: String) throws {
        if case .userInControl(let reason, _) = currentState {
            throw AgentError.userInControl(reason)
        }
        activeTask = task
        currentState = .agentDriving(task: task)
        restartIdleTimer()
    }

    /// The agent gives the page to the user, e.g. for a captcha or a 2FA code.
    func handOff(reason: String, session: BrowserSession?) -> [String: Any] {
        currentState = .userInControl(reason: reason, requestedByAgent: true)
        idleTimer?.invalidate()
        NSApplication.shared.requestUserAttention(.informationalRequest)
        session?.showToast?(Toast(
            symbolName: "hand.raised.fill",
            message: "The agent needs you: \(reason)",
            duration: 8.0
        ))
        return [
            "status": "handed_off_to_user",
            "reason": reason,
            "message": "Control handed to the user. Stop and tell them what to do; call resume (or waitForControl) once they confirm."
        ]
    }

    /// The agent takes the page back after the user confirmed they were done.
    func resume(session: BrowserSession?) -> [String: Any] {
        currentState = .agentDriving(task: activeTask.isEmpty ? "Working" : activeTask)
        restartIdleTimer()
        wakeControlWaiters()
        return [
            "status": "agent_driving",
            "message": "The agent has control of the page again."
        ]
    }

    /// The task is done: drop the fence and the cursor.
    func finish() -> [String: Any] {
        idleTimer?.invalidate()
        activeTask = ""
        currentState = .idle
        wakeControlWaiters()
        return ["status": "idle", "message": "Task finished; the page is the user's again."]
    }

    /// Suspends until the user gives control back, or `timeout` passes.
    func waitForControl(timeout: TimeInterval) async throws {
        guard isUserControlling else { return }
        let expiry = Expiry()
        let timer = Task { @MainActor [weak self] in
            try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            expiry.passed = true
            self?.wakeControlWaiters()
        }
        defer { timer.cancel() }
        // Waiters are woken together, by any state change or by any waiter's
        // timeout, so each one checks its own reason before leaving.
        while isUserControlling {
            if expiry.passed { throw AgentError.controlWaitTimedOut(timeout) }
            await withCheckedContinuation { controlWaiters.append($0) }
        }
    }

    // MARK: - User side

    /// The user grabs the page from the "Take over" button.
    func takeOverByUser() {
        idleTimer?.invalidate()
        currentState = .userInControl(reason: "You took over the task", requestedByAgent: false)
    }

    /// The user hands the page back from the bar.
    func giveBackToAgent() {
        currentState = .agentDriving(task: activeTask.isEmpty ? "Waiting for the agent" : activeTask)
        restartIdleTimer()
        wakeControlWaiters()
    }

    /// Resets to idle; used by tests and on quit.
    public func reset() {
        idleTimer?.invalidate()
        activeTask = ""
        currentState = .idle
        wakeControlWaiters()
    }

    @MainActor private final class Expiry { var passed = false }

    private func wakeControlWaiters() {
        let waiters = controlWaiters
        controlWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func restartIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isAgentDriving else { return }
                _ = self.finish()
            }
        }
    }
}
