import Foundation

/// One remote thing a live folder shows as a tab.
struct LiveFolderItem: Sendable, Equatable, Codable {
    /// Stable for the lifetime of the remote object: a pull request number, a
    /// feed entry's `guid`. Everything downstream keys on it, so a provider
    /// that invents a new id per fetch would churn the folder on every poll.
    let id: String
    let title: String
    let url: URL
    /// The second line in the folder popup: an author login, a feed name.
    let subtitle: String?
    /// When the remote object was published or last touched, when the source
    /// says. Used for ordering and for the time range filter.
    let date: Date?
}

/// Why a live folder has nothing to show, as a value rather than an exception.
///
/// This is the single most important type in the subsystem. A fetch that fails
/// must be *distinguishable* from a fetch that succeeded and found nothing,
/// because the first must never remove a tab and the second must. Conflating
/// them -- a 500 on every parallel query falling through as an empty array and
/// silently closing every tab in the folder -- is exactly the bug this type
/// exists to make impossible.
enum LiveFolderIssue: Codable, Sendable, Equatable {
    /// The provider has not been given what it needs (no feed URL, no account).
    case notConfigured
    /// Every filter is switched off, so there is no question to ask. Detected
    /// before any request is made.
    case noFilterSelected
    /// The source says there is no such account or feed.
    case unknownAccount(String)
    /// `retryAfter` is the server's own number when it sent one.
    case rateLimited(retryAfter: TimeInterval?)
    case network(String)
    /// The bytes arrived but were not the document they claimed to be.
    case malformedResponse
    case sourceUnavailable(status: Int)

    /// Shown on the folder's header while the issue stands. Deliberately plain:
    /// an error the user cannot act on should at least be one they can read.
    var message: String {
        switch self {
        case .notConfigured: return "Not set up yet"
        case .noFilterSelected: return "No filters selected"
        case .unknownAccount(let name): return "Can't find \(name)"
        case .rateLimited: return "Rate limited — will retry"
        case .network: return "Couldn't reach the source"
        case .malformedResponse: return "The source sent something unreadable"
        case .sourceUnavailable(let status): return "The source returned \(status)"
        }
    }

    /// What the header's action button does about it. `nil` means the button
    /// only offers a retry.
    var recoveryURL: URL? {
        if case .unknownAccount(let name) = self {
            return URL(string: "https://github.com/\(name)")
        }
        return nil
    }

    /// Whether retrying immediately could plausibly help. A rate limit says no,
    /// and honouring that is the difference between backing off and hammering.
    var allowsImmediateRetry: Bool {
        switch self {
        case .rateLimited: return false
        case .notConfigured, .noFilterSelected, .unknownAccount,
             .network, .malformedResponse, .sourceUnavailable: return true
        }
    }
}

/// The result of one poll.
enum LiveFolderFetch: Sendable, Equatable {
    /// Authoritative contents. An empty array here genuinely means "there are
    /// none", and the folder is emptied accordingly.
    case items([LiveFolderItem])
    /// Nothing is known this time round. Never prunes anything.
    case blocked(LiveFolderIssue)
}

/// Which provider a live folder uses. A closed set, because each case is a
/// hand-written parser for one service's shape.
enum LiveFolderKind: String, Codable, Sendable, CaseIterable {
    case rss
    case github
}

/// Name and icon a new live folder is created with, so the user does not have
/// to name something they have not seen yet.
struct LiveFolderMetadata: Sendable, Equatable {
    var name: String
    var symbolName: String
}

/// A source of tabs that is not the user.
///
/// Providers are immutable values. Everything that changes -- when it was last
/// fetched, what it last returned, which items the user dismissed -- lives in
/// `LiveFolderState` beside them, which is what makes a provider trivially
/// `Sendable` and what keeps "the configuration" and "the accumulated history"
/// from being edited by the same code path.
protocol LiveFolderProvider: Sendable {
    static var kind: LiveFolderKind { get }

    /// The configuration in the form that is written to disk.
    var source: LiveFolderSource { get }

    var metadata: LiveFolderMetadata { get }

    /// The provider-specific half of the folder's options menu. The interval
    /// and refresh items are added by the manager, so no provider has to
    /// remember them.
    var options: [LiveFolderOption] { get }

    /// One poll. Never throws: every failure a provider can have is a state the
    /// folder must display, and an error that unwinds past the caller is a
    /// state that got lost on the way.
    func fetchItems(using fetcher: LiveFolderFetcher) async -> LiveFolderFetch

    /// A new provider with one option changed. Returning a value rather than
    /// mutating keeps the "configuration is immutable" rule from having an
    /// exception the menu code can reach through.
    func applying(_ change: LiveFolderOptionChange) -> any LiveFolderProvider

    /// A chance to fold what a fetch revealed back into the configuration --
    /// the repositories GitHub actually returned, the title a feed calls
    /// itself. Optional: most providers learn nothing.
    func learning(from items: [LiveFolderItem]) -> any LiveFolderProvider
}

extension LiveFolderProvider {
    func learning(from items: [LiveFolderItem]) -> any LiveFolderProvider { self }
}

/// The persisted configuration of a live folder, and the only thing that knows
/// how to turn itself back into a provider.
enum LiveFolderSource: Codable, Sendable, Equatable {
    case rss(RSSLiveFolderProvider.Configuration)
    case github(GitHubLiveFolderProvider.Configuration)

    var kind: LiveFolderKind {
        switch self {
        case .rss: return .rss
        case .github: return .github
        }
    }

    func makeProvider() -> any LiveFolderProvider {
        switch self {
        case .rss(let configuration): return RSSLiveFolderProvider(configuration: configuration)
        case .github(let configuration): return GitHubLiveFolderProvider(configuration: configuration)
        }
    }
}

// MARK: - Options

/// A declarative description of a provider's menu.
///
/// Declarative rather than each provider building an `NSMenu`: a provider is
/// a networking and parsing object, and giving it a second job of assembling
/// AppKit objects is how two providers end up with menus that behave
/// differently. One renderer, one set of behaviours.
enum LiveFolderOption: Sendable, Equatable {
    case action(key: String, title: String)
    case toggle(key: String, title: String, isOn: Bool)
    case choice(key: String, title: String, values: [Value], selected: String)
    case submenu(title: String, items: [LiveFolderOption])
    case separator

    struct Value: Sendable, Equatable {
        let value: String
        let title: String
    }
}

/// What the user did to an option.
struct LiveFolderOptionChange: Sendable, Equatable {
    let key: String
    let value: Value

    enum Value: Sendable, Equatable {
        case triggered
        case bool(Bool)
        case string(String)
    }

    /// Refresh now. Handled by the manager for every provider.
    static let refreshKey = "refresh"
    /// Poll interval, in seconds, as a string. Handled by the manager.
    static let intervalKey = "interval"
}
