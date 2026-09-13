import Foundation
import WebKit

/// Where a navigation started from an essential's tab should end up.
enum EssentialsNavigationDestination: Sendable, Equatable {
    /// Let the tab navigate.
    case sameTab
    /// Open it elsewhere and leave the tile where it was.
    case newTab(URL)
}

/// The rule that keeps a pinned tab on its own site.
///
/// Following an off-site link from a pinned tab is how a pinned mail tab turns
/// into whatever article someone sent you, and the tile then shows the wrong
/// favicon until you notice and navigate back. The fix is simple: a link
/// click that leaves the pinned host opens a new tab instead.
///
/// Deliberately narrow:
///
/// - Only link activations. A redirect, a form post, a `history.pushState` or
///   anything the page does to itself stays in the tab; a rule that fired on
///   every navigation would break every sign-in flow that bounces through an
///   identity provider.
/// - Only a different **host**. A different path on the same site is the tab
///   doing its job.
enum EssentialsNavigationPolicy {

    /// - Parameters:
    ///   - pinned: the address the tile is pinned to, which is what "this tab's
    ///     site" means -- not the tab's current address, which may itself have
    ///     drifted.
    ///   - target: where the navigation wants to go.
    ///   - isLinkActivation: `navigationType == .linkActivated`.
    static func destination(
        pinned: URL,
        target: URL,
        isLinkActivation: Bool
    ) -> EssentialsNavigationDestination {
        guard isLinkActivation else { return .sameTab }
        guard let pinnedHost = pinned.host?.lowercased(),
              let targetHost = target.host?.lowercased() else { return .sameTab }
        return pinnedHost == targetHost ? .sameTab : .newTab(target)
    }

    /// The same rule, answered for a WebKit navigation action.
    ///
    /// Kept beside the pure form rather than folded into it so the policy can
    /// be tested without a `WKNavigationAction`, which cannot be constructed.
    /// Main-actor isolated because `WKNavigationAction`'s properties are, which
    /// is also where `decidePolicyFor` runs.
    @MainActor
    static func destination(
        pinned: URL,
        action: WKNavigationAction
    ) -> EssentialsNavigationDestination {
        guard let target = action.request.url else { return .sameTab }
        return destination(
            pinned: pinned,
            target: target,
            isLinkActivation: action.navigationType == .linkActivated
        )
    }
}
