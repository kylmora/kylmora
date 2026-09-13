import AppKit
import Combine
import WebKit

/// Find-in-page, driven by WebKit's own search.
///
/// The controller owns the bar, the state and the one web view the search
/// applies to. It listens to `BrowserSession` rather than being told about tab
/// changes, so installing it costs the content pane three lines and no ongoing
/// bookkeeping.
@MainActor
final class FindController: FindBarViewDelegate {
    /// Long enough that holding a key down does not queue a search per
    /// keystroke, short enough to still read as find-as-you-type.
    private static let typingDelay = Duration.milliseconds(120)

    private let session: BrowserSession
    private let bar = FindBarView()
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

    /// Adds the bar to the content pane. Called once, after the pane's view
    /// exists; the bar stays hidden until Cmd-F.
    func install(in host: NSView) {
        bar.delegate = self
        bar.isHidden = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(bar)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: host.topAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 12)
        ])

        sessionCancellable = session.changes
            .sink { [weak self] change in
                switch change {
                case .activeTab, .spaces, .tabs:
                    self?.syncWebView()
                case .tab(let tab):
                    // A tab builds its web view the first time it is shown, and
                    // that is a `.tab` event, not an `.activeTab` one. Watching
                    // for it means the bar picks up the page whichever order
                    // the content pane and this controller were wired in.
                    guard let self, tab.id == self.session.activeTab?.id else { return }
                    self.syncWebView()
                case .structure:
                    // Filing a tab into a group does not change which page is
                    // showing, so the find bar keeps its target.
                    break
                case .bookmarks:
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
        clearSelection()
        // Hand the keyboard back to the page rather than to whatever AppKit
        // would pick after the field disappears.
        if let webView { webView.window?.makeFirstResponder(webView) }
    }

    private func repeatSearch(_ direction: FindDirection) {
        guard canRepeat else { return }
        // Cmd-G with the bar closed searches without opening it, matching
        // Safari. The bar is a way to type a term, not a precondition.
        search(direction, fromCurrentMatch: false)
    }

    // MARK: - Searching

    /// - Parameter fromCurrentMatch: collapse the page selection first, so the
    ///   search resumes at the current match instead of stepping past it. This
    ///   is what makes find-as-you-type stay on one match as the term grows.
    private func search(_ direction: FindDirection, fromCurrentMatch: Bool, afterTyping: Bool = false) {
        searchTask?.cancel()
        guard let webView, !state.query.isEmpty else { return }

        let query = state.query
        let configuration = state.configuration(for: direction)
        searchTask = Task { [weak self] in
            if afterTyping {
                try? await Task.sleep(for: Self.typingDelay)
                guard !Task.isCancelled else { return }
            }
            if fromCurrentMatch {
                await Self.runSelectionScript("window.getSelection().collapseToStart()", in: webView)
                guard !Task.isCancelled else { return }
            }
            // Throws only when the web view has been suspended out from under
            // us, which means there is no page left to report an answer about.
            guard let result = try? await webView.find(query, configuration: configuration) else { return }
            guard !Task.isCancelled, let self, self.state.query == query else { return }
            self.state.record(matchFound: result.matchFound)
            self.bar.update(with: self.state)
        }
    }

    /// Drops the page selection, which is the whole of what a completed find
    /// leaves behind: the public `findString` API asks WebKit for no overlay
    /// and no highlight, only a selection scrolled into view.
    private func clearSelection() {
        guard let webView else { return }
        Task { await Self.runSelectionScript("window.getSelection().removeAllRanges()", in: webView) }
    }

    /// Runs in `WKContentWorld.defaultClient`, an isolated world that shares the
    /// document but not the page's JavaScript globals, so a page cannot see or
    /// shadow this and its own CSP does not apply. Errors are ignored on
    /// purpose: a PDF or an `about:` document has no selection to clear, and
    /// that is not a failure worth reporting.
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
        // Asking an unloaded tab for its web view would build one, which is
        // exactly what lazy tabs exist to avoid.
        let next = tab?.isLoaded == true ? tab?.webView() : nil
        guard next !== webView else { return }

        // The bar belongs to the page it was opened on: a match highlighted in
        // one tab means nothing in another.
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

    /// A new document has no selection and no matches, so the last answer is
    /// stale. The term stays in the field — the user asked for it — but nothing
    /// is searched until they ask again, because a page that scrolled itself on
    /// load would be a surprise.
    private func pageDidNavigate() {
        searchTask?.cancel()
        searchTask = nil
        state.clearOutcome()
        bar.update(with: state)
    }

    // MARK: - FindBarViewDelegate

    func findBar(_ bar: FindBarView, didChangeQuery query: String) {
        guard state.setQuery(query) else {
            if state.query.isEmpty {
                bar.update(with: state)
                clearSelection()
            }
            return
        }
        bar.update(with: state)
        search(.forward, fromCurrentMatch: true, afterTyping: true)
    }

    func findBarDidChangeOptions(_ bar: FindBarView) {
        state.matchesCase = bar.matchesCaseIsOn
        bar.update(with: state)
        search(.forward, fromCurrentMatch: true)
    }

    func findBarWantsNextMatch(_ bar: FindBarView) { findNext() }
    func findBarWantsPreviousMatch(_ bar: FindBarView) { findPrevious() }
    func findBarWantsDismissal(_ bar: FindBarView) { dismiss() }
}
