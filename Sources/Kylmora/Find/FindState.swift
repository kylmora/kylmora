import WebKit

/// Which way through the document the next search runs.
enum FindDirection {
    case forward
    case backward
}

/// Everything find-in-page knows, with nothing that draws or searches.
///
/// Keeping the state a value type means the rules — what a repeat needs, what
/// the bar is allowed to claim, how the user's choices become a
/// `WKFindConfiguration` — are unit tests rather than something to click at.
struct FindState: Equatable {
    /// What the last completed search said.
    ///
    /// There is no `.found(index:of:)` case because WebKit will not tell us
    /// one: `WKFindResult` carries a single `matchFound` flag and nothing else.
    enum Outcome: Equatable {
        /// No search has completed for the current query yet.
        case pending
        case found
        case notFound
    }

    private(set) var query = ""
    private(set) var outcome: Outcome = .pending

    /// Off by default, matching every other browser's find bar and WebKit's own
    /// `WKFindConfiguration` default.
    var matchesCase = false {
        didSet { if matchesCase != oldValue { outcome = .pending } }
    }

    /// Cmd-G with the bar closed repeats the last term, so a repeat only needs
    /// a term — not a visible bar and not a previous match.
    var canRepeat: Bool { !query.isEmpty }

    /// What the bar shows beside the field, or `nil` for nothing.
    ///
    /// `nil` on success is deliberate. Every other browser puts "3 of 17" here;
    /// we cannot, so the space stays empty rather than being filled with
    /// something invented.
    var statusMessage: String? {
        switch outcome {
        case .pending, .found: return nil
        case .notFound: return "Not found"
        }
    }

    /// True while the field should read as a failed search.
    var isFailing: Bool { outcome == .notFound }

    /// - Returns: whether the new text warrants a fresh search.
    @discardableResult
    mutating func setQuery(_ newValue: String) -> Bool {
        guard newValue != query else { return false }
        query = newValue
        outcome = .pending
        return !newValue.isEmpty
    }

    mutating func record(matchFound: Bool) {
        outcome = matchFound ? .found : .notFound
    }

    /// Forgets the answer but keeps the term, so closing the bar and pressing
    /// Cmd-G still searches for what was last typed.
    mutating func clearOutcome() {
        outcome = .pending
    }

    /// WebKit's own search options, built from the user's choices.
    ///
    /// `wraps` stays at WebKit's default of `true`: a find bar that stopped at
    /// the bottom of the document would need to say so, and the result gives us
    /// no way to know whether a wrap happened.
    @MainActor
    func configuration(for direction: FindDirection) -> WKFindConfiguration {
        let configuration = WKFindConfiguration()
        configuration.backwards = direction == .backward
        configuration.caseSensitive = matchesCase
        configuration.wraps = true
        return configuration
    }
}
