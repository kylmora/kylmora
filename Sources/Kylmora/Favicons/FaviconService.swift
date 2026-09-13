import AppKit
import WebKit

/// The sidebar's entry point to favicons: bounded memory cache, discovery, and
/// the one place an `NSImage` is made.
///
/// Discovery is *both* mechanisms, in the order that costs least. If the tab
/// has a live web view, its already-loaded DOM is asked for its `<link
/// rel="icon">` tags — that is the icon the site actually chose, and it costs
/// no extra page fetch because the page is already here. If there is no web
/// view (a restored or suspended tab), the `/favicon.ico` convention is used.
/// Kylmora never downloads a page's HTML itself just to read its head.
@MainActor
final class FaviconService {
    static let shared = FaviconService()

    /// One decoded 32-pixel icon is about 4 KB of backing store, so this caps
    /// decoded icons at roughly 2 MB.
    private static let memoryCostLimit = 2 * 1024 * 1024
    private static let memoryCountLimit = 512

    /// How long a host that produced no icon is left alone. Long enough that
    /// scrolling the sidebar does not re-request it, short enough that a site
    /// which has just added a favicon is picked up in the same sitting.
    private static let negativeCacheLifetime: TimeInterval = 60 * 60
    private static let negativeCacheLimit = 256

    /// Held by `NSCache` rather than a dictionary: it is already thread-safe,
    /// already evicts by cost, and — the part that matters here — it responds
    /// to system memory pressure by discarding entries on its own. A
    /// hand-rolled LRU would be more code and would still have to be told when
    /// memory is short, which is exactly the machinery D24 already treats as a
    /// first-class signal.
    private let memory = NSCache<NSString, Entry>()

    /// Hosts whose DOM has already been asked this session. Without it, every
    /// sidebar refresh — and titles change on almost every navigation — would
    /// run JavaScript in every visible tab.
    private var domQueried: Set<String> = []

    private var negative: [String: Date] = [:]

    private let store: FaviconStore

    final class Entry {
        let image: NSImage
        let source: FaviconSourceKind
        let cost: Int

        init(image: NSImage, source: FaviconSourceKind, cost: Int) {
            self.image = image
            self.source = source
            self.cost = cost
        }
    }

    init(store: FaviconStore = .shared) {
        self.store = store
        memory.countLimit = Self.memoryCountLimit
        memory.totalCostLimit = Self.memoryCostLimit
    }

    /// The icon if it is already decoded in memory. Synchronous on purpose: a
    /// table cell being reused must be able to draw the right icon in the same
    /// pass, or the list flickers as it scrolls.
    func cachedImage(for pageURL: URL) -> NSImage? {
        guard let host = FaviconSource.cacheKey(for: pageURL) else { return nil }
        return memory.object(forKey: host as NSString)?.image
    }

    /// The icon for a page, fetching it if it is not already known.
    ///
    /// Returns `nil` when the site has no usable icon, which the caller shows
    /// as the generic placeholder rather than inventing something.
    func image(for pageURL: URL, webView: WKWebView?, isPrivate: Bool) async -> NSImage? {
        guard let host = FaviconSource.cacheKey(for: pageURL) else { return nil }

        let cached = memory.object(forKey: host as NSString)
        // A page-declared icon is as good as it gets; nothing would improve it.
        if let cached, cached.source == .dom { return cached.image }

        // Only a live web view can improve on a guess, and only once per host.
        // It has to be showing *this* host's finished document: a tab's URL
        // moves to the next page the moment a navigation starts, and asking
        // then returns the previous site's icons, which would be cached under
        // the new host as its best answer and never corrected.
        let liveDocument = webView.map { view in
            !view.isLoading && view.url.flatMap(FaviconSource.cacheKey) == host
        } ?? false
        let canAskDOM = liveDocument && !domQueried.contains(host)
        if !canAskDOM {
            if let cached { return cached.image }
            if isNegative(host) { return nil }
        }

        var links: [FaviconLink] = []
        if let webView, canAskDOM {
            links = await declaredLinks(in: webView)
            rememberDOMQuery(for: host)
        }

        let source: FaviconSourceKind = links.isEmpty ? .convention : .dom
        // The DOM had nothing new to say and the guess is already cached.
        if let cached, cached.source >= source { return cached.image }

        let candidates = FaviconSource.candidates(pageURL: pageURL, links: links)
        guard !candidates.isEmpty else { return cached?.image }

        guard let record = await store.icon(
            host: host, candidates: candidates, source: source, persist: !isPrivate
        ) else {
            noteNegative(host)
            return cached?.image
        }

        guard let image = Self.makeImage(from: record.data) else { return cached?.image }
        negative[host] = nil
        memory.setObject(
            Entry(image: image, source: record.source, cost: record.data.count),
            forKey: host as NSString,
            cost: max(record.data.count, 1)
        )
        return image
    }

    // MARK: - Discovery

    /// Runs in `WKContentWorld.defaultClient`, not the page's own world. In the
    /// page world the site could replace `querySelectorAll` and see, or lie
    /// about, the browser asking. An isolated world shares the DOM but not the
    /// script environment, so the page cannot observe the question at all.
    private func declaredLinks(in webView: WKWebView) async -> [FaviconLink] {
        guard webView.url != nil else { return [] }
        guard let result = try? await webView.evaluateJavaScript(
            Self.discoveryScript, in: nil, contentWorld: .defaultClient
        ), let rows = result as? [[String: Any]] else {
            return []
        }
        return rows.compactMap { row in
            guard let href = row["href"] as? String, !href.isEmpty else { return nil }
            return FaviconLink(
                href: href,
                rel: row["rel"] as? String ?? "",
                sizes: row["sizes"] as? String ?? "",
                type: row["type"] as? String ?? ""
            )
        }
    }

    /// `link.href` is read rather than the attribute, so WebKit has already
    /// resolved it against the document's base URL. The count is capped because
    /// a page can declare as many icons as it likes.
    private static let discoveryScript = """
    (function () {
        var out = [];
        var links = document.querySelectorAll("link[rel]");
        for (var i = 0; i < links.length && out.length < 12; i++) {
            var rel = (links[i].getAttribute("rel") || "").toLowerCase();
            if (rel.indexOf("icon") === -1) { continue; }
            out.push({
                href: links[i].href || "",
                rel: rel,
                sizes: links[i].getAttribute("sizes") || "",
                type: links[i].getAttribute("type") || ""
            });
        }
        return out;
    })();
    """

    // MARK: - Bookkeeping

    private func rememberDOMQuery(for host: String) {
        if domQueried.count >= Self.memoryCountLimit { domQueried.removeAll(keepingCapacity: true) }
        domQueried.insert(host)
    }

    private func isNegative(_ host: String) -> Bool {
        guard let recorded = negative[host] else { return false }
        guard Date.now.timeIntervalSince(recorded) < Self.negativeCacheLifetime else {
            negative[host] = nil
            return false
        }
        return true
    }

    /// Failures are remembered in memory only. Writing "this host has no icon"
    /// to disk would leave a record of somewhere the user went in exchange for
    /// saving one small request per hour.
    private func noteNegative(_ host: String) {
        if negative.count >= Self.negativeCacheLimit { negative.removeAll(keepingCapacity: true) }
        negative[host] = .now
    }

    /// The bytes are a PNG of at most 32 pixels; giving the `NSImage` a 16-point
    /// size makes AppKit treat that as the 2x representation, so the icon is
    /// crisp on a Retina display and correctly sized on one that is not.
    private static func makeImage(from data: Data) -> NSImage? {
        guard let image = NSImage(data: data), image.size.width > 0 else { return nil }
        let side = CGFloat(FaviconDecoder.outputPixelSize) / 2
        image.size = NSSize(width: side, height: side)
        return image
    }
}
