import Foundation

/// What the page tells us about the link under the pointer.
///
/// Coordinates are CSS pixels with a top-left origin, alongside the viewport
/// they were measured in, so the browser side can map them onto the web view
/// without knowing the page's zoom.
struct GlanceLinkRecord: Equatable, Sendable {
    let url: URL
    /// Top-left origin, CSS pixels, relative to the viewport.
    let rect: CGRect
    let viewport: CGSize
    let recordedAt: Date

    /// A rectangle recorded on a mousedown three scrolls ago is not where the
    /// user is looking. Long enough to cover a context menu opening, short
    /// enough that a stale record is never used.
    static let freshness: TimeInterval = 5

    func isFresh(at now: Date = .now) -> Bool {
        now.timeIntervalSince(recordedAt) < Self.freshness
    }
}

/// The two scripts glance injects, and the parsing of what they post back.
///
/// Both are handled in `WKContentWorld.defaultClient`, so the page cannot see
/// the message handler, cannot call it, and cannot redefine the functions the
/// script uses. Everything that arrives is still treated as hostile: the URL is
/// re-parsed and re-checked against `GlanceInvocation.isPermittedTarget`, and
/// the geometry only ever decides where an animation starts.
enum GlanceScripts {
    static let linkHandlerName = "kylmoraGlanceLink"
    static let focusHandlerName = "kylmoraGlanceFocus"

    /// Records the link under the pointer on *mousedown*, before anyone knows
    /// whether a glance or a context menu will follow.
    ///
    /// This is deliberate, for the same reason: by the time the click or the
    /// menu arrives the layout may have moved, and by the time the menu's
    /// action runs the element may be gone entirely. The listener is passive
    /// and on the capture phase so a page that stops propagation cannot hide
    /// its links from it, and it never calls `preventDefault`, so it cannot
    /// change what the page does.
    static let linkSource = """
    (function () {
      const post = window.webkit?.messageHandlers?.\(linkHandlerName);
      if (!post) { return; }
      document.addEventListener('mousedown', function (event) {
        const anchor = event.target?.closest?.('a[href]');
        if (!anchor) { return; }
        const box = anchor.getBoundingClientRect();
        post.postMessage({
          href: anchor.href,
          x: box.left,
          y: box.top,
          width: box.width,
          height: box.height,
          viewportWidth: window.innerWidth,
          viewportHeight: window.innerHeight
        });
      }, { capture: true, passive: true });
    })();
    """

    /// Reports whether anything inside the glance holds focus.
    ///
    /// This is the input to the Escape confirmation guard, and it has to be
    /// known *synchronously* when Escape is pressed -- an `evaluateJavaScript`
    /// round trip would arrive after the decision was needed. So focus is
    /// tracked as it changes and cached on the browser side.
    ///
    /// `document.body` is excluded because it is what has focus when nothing
    /// does; a click on a paragraph is not a half-typed form.
    static let focusSource = """
    (function () {
      const post = window.webkit?.messageHandlers?.\(focusHandlerName);
      if (!post) { return; }
      const report = function () {
        const active = document.activeElement;
        // The handler is removed when the glance is promoted to a tab, and a
        // document that outlives it must not start throwing on every click.
        try {
          post.postMessage(!!active && active !== document.body && active !== document.documentElement);
        } catch (ignored) {}
      };
      document.addEventListener('focusin', report, { capture: true, passive: true });
      document.addEventListener('focusout', function () { setTimeout(report, 0); },
                                { capture: true, passive: true });
      report();
    })();
    """

    /// Turns a message body into a record, or into nothing.
    ///
    /// Separated from the handler so the hostile cases -- a missing field, a
    /// `javascript:` href, a negative size -- are unit tests rather than a page
    /// somebody has to build.
    static func parseLink(_ body: Any, at now: Date = .now) -> GlanceLinkRecord? {
        guard let payload = body as? [String: Any],
              let href = payload["href"] as? String,
              let url = URL(string: href),
              GlanceInvocation.isPermittedTarget(url) else { return nil }

        let numbers = ["x", "y", "width", "height", "viewportWidth", "viewportHeight"]
            .map { payload[$0] as? Double }
        guard let values = numbers.allSatisfy({ $0 != nil }) ? numbers.map({ $0! }) : nil,
              values.allSatisfy({ $0.isFinite }),
              values[2] >= 0, values[3] >= 0,
              values[4] > 0, values[5] > 0 else { return nil }

        return GlanceLinkRecord(
            url: url,
            rect: CGRect(x: values[0], y: values[1], width: values[2], height: values[3]),
            viewport: CGSize(width: values[4], height: values[5]),
            recordedAt: now
        )
    }
}
