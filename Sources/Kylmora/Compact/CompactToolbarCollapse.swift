import AppKit

/// The toolbar half of compact mode: the bar above the page slides up under
/// the card's top edge, leaving the gutter behind it.
///
/// Kylmora's top bar has its own required height constraint and sits inside a
/// card that already masks its bounds, so the effect comes from moving the bar
/// rather than shrinking it: slide it up by its height minus the gutter, and
/// the card clips what leaves. The page follows on its own, because it is
/// pinned to the bar's bottom edge -- which is exactly the content slide a
/// negative margin would produce by hand.
///
/// The contents fade on their own timing. At 42 points the bar is only five
/// times the height of the gutter it collapses into, so controls that were
/// still visible at the end would be visibly squashed against the edge.
@MainActor
final class CompactToolbarCollapse {

    /// Distance the bar travels: everything above the gutter.
    static var travel: CGFloat {
        Style.Metrics.topBarHeight - Style.Metrics.elementSeparation
    }

    private let topConstraint: NSLayoutConstraint
    private let fadingView: NSView
    private var isRevealed = true

    /// - Parameters:
    ///   - topConstraint: pins the bar to the top of the page card. Its
    ///     constant is what moves.
    ///   - fadingView: the bar itself, whose alpha is animated.
    init(topConstraint: NSLayoutConstraint, fadingView: NSView) {
        self.topConstraint = topConstraint
        self.fadingView = fadingView
    }

    func apply(height: CGFloat, opacity: CGFloat, transition: CompactTransition) {
        let revealed = height >= Style.Metrics.topBarHeight
        let offset = revealed ? 0 : -Self.travel
        guard revealed != isRevealed || topConstraint.constant != offset else { return }
        isRevealed = revealed

        guard transition != .immediate else {
            topConstraint.constant = offset
            fadingView.alphaValue = opacity
            fadingView.superview?.layoutSubtreeIfNeeded()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = transition.duration
            context.timingFunction = transition.curve.mediaTimingFunction
                ?? CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            topConstraint.animator().constant = offset
            fadingView.animator().alphaValue = opacity
            fadingView.superview?.layoutSubtreeIfNeeded()
        }
    }
}

/// Moves the window's traffic lights between the two places they can live.
///
/// Kylmora's sidebar owns the titlebar strip, so a floating
/// sidebar takes the close button with it. Re-parenting the standard window
/// buttons is the only way to keep them: they are ordinary views that happen to
/// be owned by the titlebar container, and `NSWindow` keeps working them
/// wherever they are put.
///
/// Their original superview and frames are captured on the first move and
/// restored verbatim, so leaving compact mode puts the window back exactly as
/// the system had it rather than as we guessed it should be.
@MainActor
final class CompactTrafficLights {
    private struct Home {
        let superview: NSView
        let frames: [NSRect]
    }

    private let buttons: [NSButton]
    private var home: Home?
    private var current: CompactTrafficLightHost = .sidebar

    init?(window: NSWindow) {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        // A window without all three is not a window compact mode should be
        // rearranging: better to leave the lights alone than to move two of
        // them and strand the third.
        guard buttons.count == 3 else { return nil }
        self.buttons = buttons
    }

    /// Puts the lights on `host`. `toolbarView` is where they go when the
    /// sidebar is floating; passing nil leaves them where they are.
    func move(to host: CompactTrafficLightHost, toolbarView: NSView?) {
        guard host != current else { return }
        switch host {
        case .toolbar:
            guard let toolbarView else { return }
            captureHomeIfNeeded()
            current = .toolbar
            adopt(into: toolbarView)
        case .sidebar:
            guard let home else { return }
            for (index, button) in buttons.enumerated() {
                button.removeFromSuperview()
                home.superview.addSubview(button)
                button.frame = home.frames[index]
            }
        }
        current = host
    }

    /// Puts the lights back on the bar, on its centre line.
    ///
    /// Called by the bar itself every time it lays out, and it has to take them
    /// back rather than just move them: AppKit reclaims the standard window
    /// buttons into `NSTitlebarView` whenever it rebuilds the titlebar, and
    /// once they are back there nothing we own places them. They then sit
    /// where the titlebar puts them -- six points off its own bottom edge --
    /// while the bar they are supposed to be on starts eight points lower, so
    /// the three lights floated above the toolbar's buttons instead of lining
    /// up with them.
    func recentre(in toolbarView: NSView) {
        guard current == .toolbar else { return }
        adopt(into: toolbarView)
    }

    /// Takes the three buttons onto `toolbarView` -- if they are not already
    /// there -- and sits them on its centre line.
    private func adopt(into toolbarView: NSView) {
        for (index, button) in buttons.enumerated() {
            if button.superview !== toolbarView {
                button.removeFromSuperview()
                button.translatesAutoresizingMaskIntoConstraints = true
                toolbarView.addSubview(button)
                // Nothing flexible in y: with both vertical margins flexible
                // AppKit shares out every height change between them, and the
                // bar does change height on the way in.
                button.autoresizingMask = [.maxXMargin]
            }
            button.frame.origin = Self.origin(index: index, button: button, in: toolbarView)
        }
    }

    /// Where the light at `index` sits: along the bar's leading edge, on its
    /// centre line. Rounded, because half a point of offset on a fourteen-point
    /// circle is a visibly soft edge.
    private static func origin(index: Int, button: NSButton, in toolbarView: NSView) -> CGPoint {
        // The bar's constrained height, not its current bounds: `layout()`
        // runs before the constraint has settled, and a bar that is briefly
        // 68 points tall centres the lights 13 points too high -- which is
        // where they stayed, above the buttons they are meant to sit beside.
        let height = Style.Metrics.topBarHeight
        return CGPoint(
            x: Style.Metrics.elementSeparation + CGFloat(index) * buttonPitch,
            y: ((height - button.frame.height) / 2).rounded()
        )
    }

    /// Centre-to-centre spacing of the three lights, which macOS fixes at 20
    /// points and which cannot be read off the buttons: their frames are only
    /// correct once the titlebar has laid them out.
    private static let buttonPitch: CGFloat = 20

    private func captureHomeIfNeeded() {
        guard home == nil, let superview = buttons[0].superview else { return }
        home = Home(superview: superview, frames: buttons.map(\.frame))
    }
}
