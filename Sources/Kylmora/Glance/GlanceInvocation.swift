import AppKit
import WebKit

/// The rules that decide whether a click, a menu item or a link becomes a
/// glance. Pure, because every one of them is a security decision and a
/// security decision that can only be exercised by clicking a live page is a
/// security decision nobody exercises.
enum GlanceInvocation {
    /// Option-click. Kylmora has no other use for Option-click on a link:
    /// WebKit's own Option-click gesture downloads the target, which
    /// `DownloadManager` already reaches through `<a download>` and
    /// `Content-Disposition` instead.
    static let modifier: NSEvent.ModifierFlags = .option

    /// The modifiers a click is judged on. Caps Lock, Function and the numeric
    /// keypad flag are not chords the user meant to type.
    private static let considered: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// Exactly one modifier is required so that Cmd-Option-click, which
    /// means something else everywhere, never lands here by accident.
    static func isGlanceChord(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection(considered) == modifier
    }

    /// Where a glance is allowed to point.
    ///
    /// A glance is a page the user has not committed to, shown over one they
    /// have, so the set of schemes it may carry is smaller than the set a tab
    /// may carry. `javascript:` is the one that matters -- glancing it would run
    /// script in whatever document the overlay happened to be pointed at -- but
    /// `data:` and `blob:` are excluded for the same reason: an opaque origin
    /// under a chrome-drawn address pill is a spoofing primitive, and nothing
    /// legitimate needs it here.
    static func isPermittedTarget(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https", "file": true
        default: false
        }
    }

    /// Path 1: modifier-click on a link, decided in the browser process from
    /// the navigation action alone.
    ///
    /// WebKit hands us `modifierFlags` and `navigationType` before the load
    /// starts, so unlike Gecko this needs no content-side JavaScript and no
    /// drag threshold: a drag that selects text never produces a
    /// `.linkActivated` navigation in the first place.
    @MainActor
    static func shouldGlance(_ action: WKNavigationAction) -> Bool {
        guard action.navigationType == .linkActivated,
              isGlanceChord(action.modifierFlags),
              let url = action.request.url else { return false }
        return isPermittedTarget(url)
    }

    /// Path 5: a link out of a tab that is sitting on a pinned site, pointing
    /// somewhere else entirely.
    ///
    /// This makes sense for app tabs -- a mail client, a chat client -- where
    /// an outbound link is nearly always something you want to read once and
    /// leave. Kylmora's pinned sites are shortcuts, not app tabs: opening one
    /// hands you an ordinary tab you can navigate anywhere, so "this tab is an
    /// app you live in" is not true of it and silently redirecting its links
    /// would be a surprise. The rule is implemented and the switch is off.
    static func shouldAutoGlance(
        linkURL: URL,
        ownerURL: URL,
        ownerIsPinnedSite: Bool,
        enabled: Bool
    ) -> Bool {
        guard enabled, ownerIsPinnedSite, isPermittedTarget(linkURL) else { return false }
        guard let target = linkURL.host()?.lowercased(), let owner = ownerURL.host()?.lowercased() else {
            return false
        }
        return !isSameSite(target, owner)
    }

    /// Host comparison that treats `www.example.com` and `example.com` as one
    /// site and anything else as different.
    ///
    /// Deliberately not a public-suffix match: Kylmora bundles no PSL and a
    /// hand-rolled "last two labels" rule would call `foo.co.uk` and
    /// `bar.co.uk` the same site. Being too strict here costs an extra glance;
    /// being too loose costs a missed one, and this heuristic only ever decides
    /// which of two harmless presentations a link gets.
    private static func isSameSite(_ lhs: String, _ rhs: String) -> Bool {
        strippingWWW(lhs) == strippingWWW(rhs)
    }

    private static func strippingWWW(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
