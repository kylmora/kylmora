import AppKit
import QuartzCore

/// The squeeze a control gives under a click, and the spring that puts it back.
///
/// Every clickable surface in the chrome -- icon buttons, tab rows, pinned
/// tiles, command rows, folder headers, toasts, tab cards -- yields the same
/// way when it is pressed: it scales down while the mouse is held, then
/// overshoots its resting size once on the way back. That is the only feedback
/// in the app that is about the *input* rather than about a state change, which
/// is why it is a separate thing from `RowHighlight` and why it is allowed to
/// be the one animation with a visible bounce in it.
///
/// It drives the host view's own backing layer transform rather than a plate of
/// its own, so everything the view contains -- the highlight behind it, the
/// glyph, the title, the close button -- squeezes together as one object. A
/// transform is also the only way to do this without touching layout: Auto
/// Layout never sees it, so a pressed row cannot shove its neighbours around or
/// trigger a layout pass sixty times a second.
///
/// Reduce Motion is honoured by not squeezing at all rather than by squeezing
/// instantly. A press is not a state change that has to survive the animation
/// being skipped -- there is nothing to arrive at, the control ends where it
/// started -- so the honest answer to "do not animate" is to stay still.
@MainActor
final class SpringPress {

    /// The view whose layer is squeezed. Unowned because the view owns this,
    /// and an owner that has been deallocated cannot be pressed.
    private unowned let host: NSView

    /// Whether the squeeze is currently held down, so a second `down()` from a
    /// repeated event does not restart the animation from the pressed size, and
    /// an `up()` with nothing held does not spring a control that never moved.
    private var isDown = false

    /// The one animation key this uses, so a new press replaces the rebound
    /// from the previous one rather than fighting it.
    private static let key = "kylmora.springPress"

    init(view: NSView) {
        self.host = view
        view.wantsLayer = true
    }

    /// Squeeze, and hold it. For a control that tracks the mouse all the way
    /// to `mouseUp`.
    func down() {
        guard !isDown else { return }
        isDown = true
        animate(to: Style.Motion.pressScale(for: host.bounds.size), bouncing: false)
    }

    /// Let go, springing back past the resting size and settling on it.
    func up() {
        guard isDown else { return }
        isDown = false
        animate(to: 1, bouncing: true)
    }

    /// A whole press in one call: squeeze, then spring back on its own.
    ///
    /// Most of the chrome fires its action from `mouseDown` and never looks at
    /// `mouseUp` -- a tab selects the instant it is clicked, which is correct
    /// and worth keeping. Such a control has no event to release on, so the
    /// release is scheduled off the end of the squeeze instead. The result is
    /// the same shape of motion as a tracked press, just on a fixed clock.
    func flick() {
        down()
        guard !Style.Motion.isReduced else {
            isDown = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Style.Motion.pressDown) { [weak self] in
            self?.up()
        }
    }

    /// Put the control back without the bounce.
    ///
    /// For a press that stopped being a press: a drag that took the pointer off
    /// the row, a menu opening over it, a list reloading underneath it. None of
    /// those are a click completing, and springing on them would report a
    /// button as having been pressed when it was not.
    func cancel() {
        guard isDown else { return }
        isDown = false
        animate(to: 1, bouncing: false)
    }

    /// Whether anything is currently squeezed. Read by the tests, and by a
    /// control that has to know whether it still owes a release.
    var isPressed: Bool { isDown }

    /// Drop the squeeze on the spot, with no animation at all.
    ///
    /// For a recycled table cell. A row that is halfway through a rebound when
    /// the list hands it to a different tab would finish the previous
    /// occupant's bounce on the new one's behalf, and a row recycled while held
    /// down would arrive already squeezed and stay that way, because the
    /// `mouseUp` that would have released it belongs to a row that no longer
    /// exists. Called from `prepareForReuse`, unconditionally, because the
    /// point is to be certain rather than to be tidy.
    func reset() {
        isDown = false
        guard let layer = host.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.key)
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    /// Scales the host's layer about the centre of its bounds.
    ///
    /// The transform is built around the centre explicitly rather than relying
    /// on the layer's anchor point being the middle. It usually is, but a view
    /// that has had its anchor moved -- or a layer AppKit has laid out for a
    /// flipped parent -- would otherwise squeeze towards a corner, which reads
    /// as the control sliding rather than as it being pressed.
    private func animate(to scale: CGFloat, bouncing: Bool) {
        guard let layer = host.layer else { return }

        let size = layer.bounds.size
        let offsetX = (0.5 - layer.anchorPoint.x) * size.width
        let offsetY = (0.5 - layer.anchorPoint.y) * size.height
        var target = CATransform3DMakeTranslation(offsetX, offsetY, 0)
        target = CATransform3DScale(target, scale, scale, 1)
        target = CATransform3DTranslate(target, -offsetX, -offsetY, 0)

        guard !Style.Motion.isReduced else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAnimation(forKey: Self.key)
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
            return
        }

        // Where it is *now*, not where it was last told to be. A press that
        // interrupts a rebound has to start from the size on screen, or the
        // control jumps to its resting size before squeezing again.
        let from = layer.presentation()?.transform ?? layer.transform

        let animation: CABasicAnimation
        if bouncing {
            let spring = CASpringAnimation(
                perceptualDuration: Style.Motion.pressSettle,
                bounce: Style.Motion.pressBounce
            )
            // A spring's `duration` is not its perceptual duration: left at the
            // default quarter second the animation is cut off mid-wobble and
            // the layer snaps the rest of the way. `settlingDuration` is how
            // long the spring actually needs to be done moving.
            spring.duration = spring.settlingDuration
            animation = spring
        } else {
            let basic = CABasicAnimation()
            basic.duration = Style.Motion.pressDown
            basic.timingFunction = Style.Motion.curve
            animation = basic
        }
        animation.keyPath = "transform"
        animation.fromValue = NSValue(caTransform3D: from)
        animation.toValue = NSValue(caTransform3D: target)

        // The model value is set first and without an implicit animation, so
        // the layer is already where it belongs when the explicit animation is
        // removed on completion and nothing flickers at the hand-off.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = target
        CATransaction.commit()
        layer.add(animation, forKey: Self.key)
    }
}

extension NSView {
    /// Whether a press on this view should do anything, which is the same
    /// question every adopting control was already asking before it drew a
    /// hover: a control in a background window, or a disabled one, is not
    /// giving feedback about anything.
    var acceptsSpringPress: Bool {
        guard let window, window.isKeyWindow || window.isMainWindow else { return false }
        if let control = self as? NSControl, !control.isEnabled { return false }
        return true
    }
}
