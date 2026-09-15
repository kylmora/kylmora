import AppKit
import Combine
import WebKit

/// The view controller hosting the docked web panel (pinned side web app) in the browser window.
@MainActor
public final class WebPanelViewController: NSViewController, WKNavigationDelegate {
    public var onOpenInTab: ((URL) -> Void)?
    public var onPopOut: ((WKWebView, WebPanel) -> Void)?
    public var onClose: (() -> Void)?

    private let store: WebPanelStore
    private let headerView = WebPanelHeaderView()
    private let webContainer = NSView()
    private let leadingBorder = NSBox()

    private var webViewCache: [UUID: WKWebView] = [:]
    private var activeWebView: WKWebView?
    private var cancellables: Set<AnyCancellable> = []
    private var webViewObservations: Set<AnyCancellable> = []

    public init(store: WebPanelStore = .shared) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("WebPanelViewController is created in code only")
    }

    public override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.translatesAutoresizingMaskIntoConstraints = false

        leadingBorder.translatesAutoresizingMaskIntoConstraints = false
        leadingBorder.boxType = .custom
        leadingBorder.borderColor = NSColor.separatorColor.withAlphaComponent(0.35)
        leadingBorder.borderWidth = 1
        leadingBorder.fillColor = .clear

        webContainer.translatesAutoresizingMaskIntoConstraints = false
        webContainer.wantsLayer = true

        root.addSubview(headerView)
        root.addSubview(webContainer)
        root.addSubview(leadingBorder)

        NSLayoutConstraint.activate([
            leadingBorder.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            leadingBorder.topAnchor.constraint(equalTo: root.topAnchor),
            leadingBorder.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            leadingBorder.widthAnchor.constraint(equalToConstant: 1),

            headerView.topAnchor.constraint(equalTo: root.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 1),
            headerView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            webContainer.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            webContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 1),
            webContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        self.view = root
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        wireHeader()
        observeStore()
        reloadActivePanel()
    }

    private func wireHeader() {
        headerView.onSelectPanel = { [weak self] id in
            self?.store.select(id: id)
        }

        headerView.onAddPanel = { [weak self] in
            self?.showAddPanelPrompt()
        }

        headerView.onBack = { [weak self] in
            self?.activeWebView?.goBack()
        }

        headerView.onForward = { [weak self] in
            self?.activeWebView?.goForward()
        }

        headerView.onReloadOrStop = { [weak self] in
            guard let self, let wv = self.activeWebView else { return }
            if wv.isLoading {
                wv.stopLoading()
            } else {
                wv.reload()
            }
        }

        headerView.onOpenInTab = { [weak self] in
            guard let self, let currentURL = self.activeWebView?.url ?? self.store.activePanel?.url else { return }
            self.onOpenInTab?(currentURL)
        }

        headerView.onPopOut = { [weak self] in
            guard let self, let panel = self.store.activePanel, let webView = self.activeWebView else { return }
            // Remove webview from container before handing off to floating window
            webView.removeFromSuperview()
            self.webViewCache.removeValue(forKey: panel.id)
            self.activeWebView = nil
            self.onPopOut?(webView, panel)
        }

        headerView.onClose = { [weak self] in
            self?.store.isOpen = false
            self?.onClose?()
        }
    }

    private func observeStore() {
        NotificationCenter.default.publisher(for: .webPanelSelectionDidChange)
            .sink { [weak self] _ in
                self?.reloadActivePanel()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .webPanelsDidChange)
            .sink { [weak self] _ in
                self?.reloadActivePanel()
            }
            .store(in: &cancellables)
    }

    public func reloadActivePanel() {
        guard let panel = store.activePanel else {
            activeWebView?.removeFromSuperview()
            activeWebView = nil
            return
        }

        let webView = webView(for: panel)

        if activeWebView !== webView {
            activeWebView?.removeFromSuperview()
            activeWebView = webView

            webView.translatesAutoresizingMaskIntoConstraints = false
            webContainer.addSubview(webView)

            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
                webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor)
            ])
        }

        observeActiveWebView(webView, for: panel)
        updateHeader(for: panel, in: webView)
    }

    private func webView(for panel: WebPanel) -> WKWebView {
        if let cached = webViewCache[panel.id] {
            return cached
        }

        let wv = WebEnvironment.shared.makeWebView(identity: .standard)
        wv.navigationDelegate = self
        if let customUA = panel.customUserAgent {
            wv.customUserAgent = customUA
        }

        if panel.isScratchpad {
            wv.loadHTMLString(ScratchpadContent.html, baseURL: nil)
        } else {
            wv.load(URLRequest(url: panel.url))
        }

        webViewCache[panel.id] = wv
        return wv
    }

    private func observeActiveWebView(_ webView: WKWebView, for panel: WebPanel) {
        webViewObservations.removeAll()

        webView.publisher(for: \.isLoading, options: [.initial, .new])
            .sink { [weak self, weak webView] isLoading in
                guard let self, let webView else { return }
                self.updateHeader(for: panel, in: webView)
            }
            .store(in: &webViewObservations)

        webView.publisher(for: \.estimatedProgress, options: [.initial, .new])
            .sink { [weak self] progress in
                self?.headerView.setProgress(progress)
            }
            .store(in: &webViewObservations)

        webView.publisher(for: \.canGoBack, options: [.initial, .new])
            .sink { [weak self, weak webView] _ in
                guard let self, let webView else { return }
                self.updateHeader(for: panel, in: webView)
            }
            .store(in: &webViewObservations)

        webView.publisher(for: \.canGoForward, options: [.initial, .new])
            .sink { [weak self, weak webView] _ in
                guard let self, let webView else { return }
                self.updateHeader(for: panel, in: webView)
            }
            .store(in: &webViewObservations)
    }

    private func updateHeader(for panel: WebPanel, in webView: WKWebView) {
        headerView.update(
            panel: panel,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            isLoading: webView.isLoading
        )
    }

    /// Adopts a web view back from a floating window.
    public func adoptWebView(_ webView: WKWebView, for panel: WebPanel?) {
        guard let panel = panel ?? store.activePanel else { return }
        webViewCache[panel.id] = webView
        store.select(id: panel.id)
        reloadActivePanel()
    }

    // MARK: - Add Panel Prompt

    public func showAddPanelPrompt() {
        let alert = NSAlert()
        alert.messageText = "Add Web Panel"
        alert.informativeText = "Enter a title and web address for the side panel:"
        alert.alertStyle = .informational

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 72))

        let titleField = NSTextField(frame: NSRect(x: 0, y: 40, width: 300, height: 24))
        titleField.placeholderString = "Title (e.g. Notion, Discord, Linear)"

        let urlField = NSTextField(frame: NSRect(x: 0, y: 8, width: 300, height: 24))
        urlField.placeholderString = "URL (e.g. https://notion.so)"

        container.addSubview(titleField)
        container.addSubview(urlField)
        alert.accessoryView = container

        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        if let window = view.window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                var urlString = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !urlString.isEmpty else { return }

                if !urlString.contains("://") {
                    urlString = "https://" + urlString
                }

                guard let url = URL(string: urlString) else { return }
                let finalTitle = title.isEmpty ? (url.host ?? "Web Panel") : title
                self?.store.add(title: finalTitle, url: url, symbolName: "sidebar.right")
            }
        }
    }
}
