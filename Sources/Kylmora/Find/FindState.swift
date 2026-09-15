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
    enum Outcome: Equatable {
        /// No search has completed for the current query yet.
        case pending
        case found
        case notFound
        case invalidRegex(message: String)
    }

    private(set) var query = ""
    private(set) var outcome: Outcome = .pending

    /// Off by default, matching every other browser's find bar and WebKit's own
    /// `WKFindConfiguration` default.
    var matchesCase = false {
        didSet { if matchesCase != oldValue { outcome = .pending } }
    }

    /// Regular expression mode toggle (`.*`). Off by default.
    var isRegex = false {
        didSet { if isRegex != oldValue { outcome = .pending } }
    }

    /// Current active match index (1-based, e.g. 3 of 12). 0 when unpositioned.
    private(set) var currentMatchIndex: Int = 0

    /// Total number of matches discovered in the document.
    private(set) var totalMatches: Int? = nil

    /// Normalized vertical offsets (0.0 to 1.0) of matches along the document height.
    private(set) var matchPositions: [Double] = []

    /// Cmd-G with the bar closed repeats the last term, so a repeat only needs
    /// a term — not a visible bar and not a previous match.
    var canRepeat: Bool { !query.isEmpty }

    /// What the bar shows beside the field, or `nil` for nothing.
    var statusMessage: String? {
        switch outcome {
        case .pending:
            return nil
        case .found:
            if let total = totalMatches {
                if total == 0 {
                    return "Not found"
                } else if currentMatchIndex > 0 {
                    return "\(currentMatchIndex) of \(total)"
                } else {
                    return "\(total) \(total == 1 ? "match" : "matches")"
                }
            }
            return nil
        case .notFound:
            return "Not found"
        case .invalidRegex:
            return "Invalid regex"
        }
    }

    /// True while the field should read as a failed search.
    var isFailing: Bool {
        switch outcome {
        case .notFound, .invalidRegex:
            return true
        case .pending, .found:
            return false
        }
    }

    /// - Returns: whether the new text warrants a fresh search.
    @discardableResult
    mutating func setQuery(_ newValue: String) -> Bool {
        guard newValue != query else { return false }
        query = newValue
        outcome = .pending
        currentMatchIndex = 0
        totalMatches = nil
        matchPositions = []
        return !newValue.isEmpty
    }

    mutating func record(
        matchFound: Bool,
        current: Int? = nil,
        total: Int? = nil,
        positions: [Double]? = nil
    ) {
        outcome = matchFound ? .found : .notFound
        if let current { currentMatchIndex = current }
        if let total { totalMatches = total }
        if let positions { matchPositions = positions }
    }

    mutating func recordInvalidRegex(_ message: String = "Invalid regex") {
        outcome = .invalidRegex(message: message)
        currentMatchIndex = 0
        totalMatches = 0
        matchPositions = []
    }

    @discardableResult
    mutating func stepMatch(direction: FindDirection) -> Int? {
        guard let total = totalMatches, total > 0 else { return nil }
        switch direction {
        case .forward:
            currentMatchIndex = (currentMatchIndex % total) + 1
        case .backward:
            currentMatchIndex = currentMatchIndex <= 1 ? total : currentMatchIndex - 1
        }
        return currentMatchIndex
    }

    mutating func setCurrentMatchIndex(_ index: Int) {
        guard let total = totalMatches, total > 0 else { return }
        currentMatchIndex = max(1, min(total, index))
    }

    /// Forgets the answer but keeps the term, so closing the bar and pressing
    /// Cmd-G still searches for what was last typed.
    mutating func clearOutcome() {
        outcome = .pending
        currentMatchIndex = 0
        totalMatches = nil
        matchPositions = []
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
