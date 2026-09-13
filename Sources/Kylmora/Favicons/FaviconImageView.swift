import AppKit
import WebKit

/// The 16-point icon slot at the head of a sidebar row.
///
/// It owns the whole asynchronous dance — placeholder, cache hit, fetch,
/// cell reuse — so that the tab row itself gains exactly one line and none of
/// the state. `NSTableView` recycles cells, so a fetch that finishes after the
/// row has been given to a different tab must be discarded, which is what the
/// token check does.
@MainActor
final class FaviconImageView: NSImageView {
    /// Matches the sidebar's 13-point label without crowding it.
    static let side: CGFloat = 16

    /// The globe is shown while an icon is loading and left in place when the
    /// site has none. It is deliberately a generic symbol and not a guess at
    /// the site's branding: an invented icon would be exactly the fake state
    /// this project forbids. There is no spinner, because the row already
    /// shows one for the page load and a second would be noise.
    private static let placeholder: NSImage? = {
        let image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }()

    private var token: String?
    private var load: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageScaling = .scaleProportionallyDown
        contentTintColor = .tertiaryLabelColor
        // The row's accessibility label already names the site; a second
        // element saying "globe" would only make VoiceOver slower.
        setAccessibilityElement(false)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("FaviconImageView is created in code only")
    }

    /// Shows the icon for a page, fetching it if necessary.
    ///
    /// `webView` is the tab's live web view when it has one, and is used only
    /// to read the page's declared icons. Pass `nil` for a tab that is not
    /// loaded; discovery falls back to the `/favicon.ico` convention.
    func show(for pageURL: URL, in webView: WKWebView?, isPrivate: Bool) {
        let host = FaviconSource.cacheKey(for: pageURL)
        guard let host else {
            reset(to: nil)
            return
        }

        // A cached icon is set without ever showing the placeholder, so a
        // scrolled or re-configured row does not flash.
        let service = FaviconService.shared
        let cached = service.cachedImage(for: pageURL)
        if token != host { reset(to: cached) } else if let cached { apply(cached) }
        token = host

        load = Task { [weak self] in
            let image = await service.image(for: pageURL, webView: webView, isPrivate: isPrivate)
            guard let self, self.token == host, let image else { return }
            self.apply(image)
        }
    }

    /// Back to the placeholder, for a page with no address to look one up for.
    func clear() { reset(to: nil) }

    private func reset(to image: NSImage?) {
        load?.cancel()
        load = nil
        token = nil
        if let image { apply(image) } else { showPlaceholder() }
    }

    /// Called whenever the icon changes, including when it arrives from the
    /// network after a placeholder was shown. The pinned tile uses it to draw a
    /// ring in the site's own colours.
    var onImageChanged: ((NSImage?) -> Void)?

    private func apply(_ image: NSImage) {
        self.image = image
        // A real favicon is drawn in its own colours; the placeholder is not.
        contentTintColor = nil
        onImageChanged?(image)
    }

    private func showPlaceholder() {
        image = Self.placeholder
        contentTintColor = .tertiaryLabelColor
        onImageChanged?(nil)
    }
}
