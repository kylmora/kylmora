import Foundation

/// Method used to authenticate and unlock Kylmora.
public enum BrowserLockMethod: String, CaseIterable, Sendable {
    case touchIDOrPasscode = "touchIDOrPasscode"
    case masterPassword = "masterPassword"

    public var title: String {
        switch self {
        case .touchIDOrPasscode:
            return "Touch ID or System Password"
        case .masterPassword:
            return "Master Password"
        }
    }
}

/// Inactivity timeout before automatically locking the browser.
public enum BrowserLockIdleTimeout: Int, CaseIterable, Sendable {
    case never = 0
    case minutes5 = 300
    case minutes15 = 900
    case minutes30 = 1800
    case hour1 = 3600

    public var title: String {
        switch self {
        case .never: return "Never"
        case .minutes5: return "After 5 minutes"
        case .minutes15: return "After 15 minutes"
        case .minutes30: return "After 30 minutes"
        case .hour1: return "After 1 hour"
        }
    }
}
