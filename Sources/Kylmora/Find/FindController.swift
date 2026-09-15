import AppKit
import Combine
import WebKit

/// Find-in-page, driven by WebKit search and enhanced with regex, match counting,
/// and scrollbar match highlights.
///
/// The controller owns the bar, the scrollbar marks ruler, the state and the one
/// web view the search applies to. It listens to `BrowserSession` rather than being
/// told about tab changes, so installing it costs the content pane three lines and
/// no ongoing bookkeeping.
@MainActor
final class FindController: FindBarViewDelegate {
    /// Long enough that holding a key down does not queue a search per
    /// keystroke, short enough to still read as find-as-you-type.
    private static let typingDelay = Duration.milliseconds(120)

    private let session: BrowserSession
    private let bar = FindBarView()
    private let scrollbarMarks = FindScrollbarMarksView()
    private var state = FindState()

    private weak var webView: WKWebView?
    private var sessionCancellable: AnyCancellable?
    private var navigationCancellable: AnyCancellable?
    private var searchTask: Task<Void, Never>?

    var isVisible: Bool { !bar.isHidden }

    /// Cmd-F is only meaningful when there is a page to search.
    var canFind: Bool { webView != nil }

    /// Cmd-G needs a term as well as a page, but not an open bar.
    var canRepeat: Bool { canFind && state.canRepeat }

    init(session: BrowserSession) {
        self.session = session
    }

    /// Adds the bar and the scrollbar marks ruler to the content container.
    func install(in host: NSView) {
        bar.delegate = self
        bar.isHidden = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(bar)

        scrollbarMarks.translatesAutoresizingMaskIntoConstraints = false
        scrollbarMarks.isHidden = true
        host.addSubview(scrollbarMarks)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: host.topAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 12),

            scrollbarMarks.topAnchor.constraint(equalTo: host.topAnchor),
            scrollbarMarks.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            scrollbarMarks.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scrollbarMarks.widthAnchor.constraint(equalToConstant: 12)
        ])

        scrollbarMarks.onSelectRatio = { [weak self] ratio in
            self?.jumpToMatchClosestTo(ratio: ratio)
        }

        sessionCancellable = session.changes
            .sink { [weak self] change in
                switch change {
                case .activeTab, .spaces, .tabs:
                    self?.syncWebView()
                case .tab(let tab):
                    guard let self, tab.id == self.session.activeTab?.id else { return }
                    self.syncWebView()
                case .structure, .bookmarks:
                    break
                }
            }
        syncWebView()
    }

    // MARK: - Commands

    /// Cmd-F. Reopening on the same page re-runs the term, which is what makes
    /// Cmd-F feel like "show me that again" rather than "start over".
    func show() {
        guard canFind else { return }
        bar.isHidden = false
        bar.update(with: state)
        bar.focus()
        if !state.query.isEmpty { search(.forward, fromCurrentMatch: true) }
    }

    func findNext() { repeatSearch(.forward) }
    func findPrevious() { repeatSearch(.backward) }

    /// Escape, the Done button, or leaving the page behind.
    func dismiss() {
        searchTask?.cancel()
        searchTask = nil
        guard !bar.isHidden else { return }
        bar.isHidden = true
        state.clearOutcome()
        bar.update(with: state)
        scrollbarMarks.clear()
        clearSelection()
        if let webView { webView.window?.makeFirstResponder(webView) }
    }

    private func repeatSearch(_ direction: FindDirection) {
        guard canRepeat else { return }
        search(direction, fromCurrentMatch: false)
    }

    // MARK: - Searching

    private func search(_ direction: FindDirection, fromCurrentMatch: Bool, afterTyping: Bool = false) {
        searchTask?.cancel()
        guard let webView, !state.query.isEmpty else { return }

        let query = state.query
        let isRegex = state.isRegex
        let matchesCase = state.matchesCase

        if isRegex {
            do {
                _ = try NSRegularExpression(pattern: query, options: matchesCase ? [] : [.caseInsensitive])
            } catch {
                state.recordInvalidRegex()
                bar.update(with: state)
                scrollbarMarks.clear()
                return
            }
        }

        searchTask = Task { [weak self] in
            if afterTyping {
                try? await Task.sleep(for: Self.typingDelay)
                guard !Task.isCancelled else { return }
            }

            guard let self, self.state.query == query else { return }

            if isRegex {
                let targetIndex: Int
                if fromCurrentMatch {
                    targetIndex = 0
                } else {
                    targetIndex = (self.state.stepMatch(direction: direction) ?? 1) - 1
                }

                let result = await Self.runScanScript(
                    query: query,
                    matchesCase: matchesCase,
                    isRegex: true,
                    targetIndex: targetIndex,
                    in: webView
                )

                guard !Task.isCancelled, self.state.query == query else { return }

                if result.count > 0 {
                    let activeIndex = targetIndex + 1
                    self.state.record(
                        matchFound: true,
                        current: activeIndex,
                        total: result.count,
                        positions: result.positions
                    )
                    self.bar.update(with: self.state)
                    self.scrollbarMarks.update(positions: result.positions, activeIndex: activeIndex)
                } else {
                    self.state.record(matchFound: false, current: 0, total: 0, positions: [])
                    self.bar.update(with: self.state)
                    self.scrollbarMarks.clear()
                }
            } else {
                if fromCurrentMatch {
                    await Self.runSelectionScript("window.getSelection().collapseToStart()", in: webView)
                    guard !Task.isCancelled else { return }
                }

                let configuration = self.state.configuration(for: direction)
                let findResult = try? await webView.find(query, configuration: configuration)
                guard !Task.isCancelled, self.state.query == query else { return }

                let matchFound = findResult?.matchFound ?? false

                let scan = await Self.runScanScript(
                    query: query,
                    matchesCase: matchesCase,
                    isRegex: false,
                    targetIndex: nil,
                    in: webView
                )

                guard !Task.isCancelled, self.state.query == query else { return }

                if matchFound && scan.count > 0 {
                    if fromCurrentMatch {
                        self.state.setCurrentMatchIndex(1)
                    } else {
                        self.state.stepMatch(direction: direction)
                    }
                    self.state.record(
                        matchFound: true,
                        current: self.state.currentMatchIndex,
                        total: scan.count,
                        positions: scan.positions
                    )
                    self.bar.update(with: self.state)
                    self.scrollbarMarks.update(positions: scan.positions, activeIndex: self.state.currentMatchIndex)
                } else if matchFound {
                    self.state.record(matchFound: true)
                    self.bar.update(with: self.state)
                    self.scrollbarMarks.clear()
                } else {
                    self.state.record(matchFound: false, current: 0, total: 0, positions: [])
                    self.bar.update(with: self.state)
                    self.scrollbarMarks.clear()
                }
            }
        }
    }

    private func jumpToMatchClosestTo(ratio: Double) {
        guard let webView, !state.matchPositions.isEmpty else { return }
        let positions = state.matchPositions
        var bestIdx = 0
        var bestDist = Double.greatestFiniteMagnitude
        for (idx, pos) in positions.enumerated() {
            let dist = abs(pos - ratio)
            if dist < bestDist {
                bestDist = dist
                bestIdx = idx
            }
        }

        let activeIndex = bestIdx + 1
        state.setCurrentMatchIndex(activeIndex)
        bar.update(with: state)
        scrollbarMarks.update(positions: positions, activeIndex: activeIndex)

        Task {
            _ = await Self.runScanScript(
                query: state.query,
                matchesCase: state.matchesCase,
                isRegex: state.isRegex,
                targetIndex: bestIdx,
                in: webView
            )
        }
    }

    private func clearSelection() {
        guard let webView else { return }
        Task { await Self.runSelectionScript("window.getSelection().removeAllRanges()", in: webView) }
    }

    private static func runSelectionScript(_ source: String, in webView: WKWebView) async {
        _ = try? await webView.callAsyncJavaScript(
            source,
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        )
    }

    // MARK: - Following the session

    private func syncWebView() {
        let tab = session.activeTab
        let next = tab?.isLoaded == true ? tab?.webView() : nil
        guard next !== webView else { return }

        dismiss()
        webView = next
        observeNavigation(next)
    }

    private func observeNavigation(_ webView: WKWebView?) {
        guard let webView else {
            navigationCancellable = nil
            return
        }
        navigationCancellable = webView.publisher(for: \.url, options: [.new])
            .sink { [weak self] _ in self?.pageDidNavigate() }
    }

    private func pageDidNavigate() {
        searchTask?.cancel()
        searchTask = nil
        state.clearOutcome()
        bar.update(with: state)
        scrollbarMarks.clear()
    }

    // MARK: - FindBarViewDelegate

    func findBar(_ bar: FindBarView, didChangeQuery query: String) {
        guard state.setQuery(query) else {
            if state.query.isEmpty {
                bar.update(with: state)
                scrollbarMarks.clear()
                clearSelection()
            }
            return
        }
        bar.update(with: state)
        search(.forward, fromCurrentMatch: true, afterTyping: true)
    }

    func findBarDidChangeOptions(_ bar: FindBarView) {
        state.matchesCase = bar.matchesCaseIsOn
        state.isRegex = bar.isRegexOn
        bar.update(with: state)
        search(.forward, fromCurrentMatch: true)
    }

    func findBarWantsNextMatch(_ bar: FindBarView) { findNext() }
    func findBarWantsPreviousMatch(_ bar: FindBarView) { findPrevious() }
    func findBarWantsDismissal(_ bar: FindBarView) { dismiss() }

    // MARK: - DOM Script Scanning

    private struct ScanResult {
        let count: Int
        let positions: [Double]
        let currentIndex: Int
        let isValid: Bool
    }

    private static let domScanScript = """
    (function() {
        const q = (typeof query !== 'undefined') ? query : (typeof arguments !== 'undefined' && arguments[0] ? arguments[0].query : "");
        const mc = (typeof matchesCase !== 'undefined') ? matchesCase : (typeof arguments !== 'undefined' && arguments[0] ? arguments[0].matchesCase : false);
        const re = (typeof isRegex !== 'undefined') ? isRegex : (typeof arguments !== 'undefined' && arguments[0] ? arguments[0].isRegex : false);
        const target = (typeof targetIndex !== 'undefined') ? targetIndex : (typeof arguments !== 'undefined' && arguments[0] ? arguments[0].targetIndex : null);

        if (!q || q.length === 0) {
            return { count: 0, positions: [], currentIndex: 0, valid: true };
        }

        let regex;
        if (re) {
            try {
                regex = new RegExp(q, mc ? 'g' : 'gi');
            } catch(e) {
                return { count: 0, positions: [], currentIndex: 0, valid: false };
            }
        }

        const docHeight = Math.max(
            document.documentElement.scrollHeight,
            document.body ? document.body.scrollHeight : 0,
            window.innerHeight,
            1
        );

        const matches = [];
        const maxMatches = 1000;

        const walker = document.createTreeWalker(
            document.body || document.documentElement,
            NodeFilter.SHOW_TEXT,
            {
                acceptNode: function(node) {
                    if (!node.nodeValue || !node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
                    const parent = node.parentElement;
                    if (!parent) return NodeFilter.FILTER_REJECT;
                    const tag = parent.tagName.toLowerCase();
                    if (tag === 'script' || tag === 'style' || tag === 'noscript' || tag === 'textarea' || tag === 'input') {
                        return NodeFilter.FILTER_REJECT;
                    }
                    const style = window.getComputedStyle(parent);
                    if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') {
                        return NodeFilter.FILTER_REJECT;
                    }
                    return NodeFilter.FILTER_ACCEPT;
                }
            }
        );

        let node;
        const needle = mc ? q : q.toLowerCase();

        while ((node = walker.nextNode()) && matches.length < maxMatches) {
            const text = node.nodeValue;
            if (re) {
                regex.lastIndex = 0;
                let m;
                while ((m = regex.exec(text)) !== null && matches.length < maxMatches) {
                    if (m[0].length === 0) {
                        regex.lastIndex++;
                        continue;
                    }
                    try {
                        const range = document.createRange();
                        range.setStart(node, m.index);
                        range.setEnd(node, m.index + m[0].length);
                        const rect = range.getBoundingClientRect();
                        const top = rect.top + window.scrollY;
                        matches.push({
                            range: range,
                            top: top,
                            ratio: Math.max(0, Math.min(top / docHeight, 1.0))
                        });
                    } catch(err) {}
                }
            } else {
                const haystack = mc ? text : text.toLowerCase();
                let pos = 0;
                while ((pos = haystack.indexOf(needle, pos)) !== -1 && matches.length < maxMatches) {
                    try {
                        const range = document.createRange();
                        range.setStart(node, pos);
                        range.setEnd(node, pos + needle.length);
                        const rect = range.getBoundingClientRect();
                        const top = rect.top + window.scrollY;
                        matches.push({
                            range: range,
                            top: top,
                            ratio: Math.max(0, Math.min(top / docHeight, 1.0))
                        });
                    } catch(err) {}
                    pos += needle.length;
                }
            }
        }

        const positions = matches.map(m => m.ratio);
        const count = matches.length;
        let current = 0;

        if (count > 0 && typeof target === 'number' && target >= 0 && target < count) {
            current = target + 1;
            const chosen = matches[target];
            const sel = window.getSelection();
            sel.removeAllRanges();
            sel.addRange(chosen.range);
            if (chosen.range.startContainer.parentElement) {
                chosen.range.startContainer.parentElement.scrollIntoView({
                    behavior: 'auto',
                    block: 'center',
                    inline: 'nearest'
                });
            }
        }

        return {
            count: count,
            positions: positions,
            currentIndex: current,
            valid: true
        };
    })()
    """

    private static func runScanScript(
        query: String,
        matchesCase: Bool,
        isRegex: Bool,
        targetIndex: Int?,
        in webView: WKWebView
    ) async -> ScanResult {
        var args: [String: Any] = [
            "query": query,
            "matchesCase": matchesCase,
            "isRegex": isRegex
        ]
        if let targetIndex {
            args["targetIndex"] = targetIndex
        }

        let raw = try? await webView.callAsyncJavaScript(
            domScanScript,
            arguments: args,
            in: nil,
            contentWorld: .defaultClient
        )

        guard let dict = raw as? [String: Any] else {
            return ScanResult(count: 0, positions: [], currentIndex: 0, isValid: true)
        }

        let count = dict["count"] as? Int ?? 0
        let positions = (dict["positions"] as? [NSNumber])?.map { $0.doubleValue } ?? []
        let currentIndex = dict["currentIndex"] as? Int ?? 0
        let valid = dict["valid"] as? Bool ?? true
        return ScanResult(count: count, positions: positions, currentIndex: currentIndex, isValid: valid)
    }
}
