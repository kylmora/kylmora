import AppKit
import QuartzCore

/// A surface springing into existence, and sliding back out of it.
///
/// The companion to `SpringPress`: that one is about a surface reacting to a
/// finger, this one is about a surface that was not there a moment ago. Both
/// drive the host's backing layer transform, so a toast that is springing in
/// and is clicked on the way squeezes from wherever the arrival has got to
/// rather than snapping to its resting size first.
///
/// Arrivals spring and departures do not, which is the asymmetry the durations
/// in `Style.Motion` already state: an overshoot is anticipation, and there is
/// nothing to anticipate about something leaving.
@MainActor
enum SpringPresence {

    private static let key = "kylmora.springPresence"

    /// Springs `view` into place: it starts small, low and transparent, and
    /// arrives at its own size having overshot it once.
    ///
    /// - Parameters:
    ///   - rising: how far below its resting position the view starts, in
    ///     points. The caller's own measure, because a toast rising off the
    ///     bottom edge and a card growing in the middle of a grid are not
    ///     travelling the same distance.
    ///   - completion: run when the spring has settled, for a caller that has
    ///     something to do afterwards.
    static func appear(_ view: NSView, rising: CGFloat, completion: (() -> Void)? = nil) {
        view.wantsLayer = true
        guard let layer = view.layer else {
            view.alphaValue = 1
            completion?()
            return
        }

        guard !Style.Motion.isReduced else {
            // Reduce Motion asks for no travel, not for no arrival: the view
            // still has to end up visible, so only the movement is dropped.
            layer.removeAnimation(forKey: key)
            layer.transform = CATransform3DIdentity
            view.alphaValue = 1
            completion?()
            return
        }

        let scale = Style.Motion.entryScale
        let start = centredScale(scale, in: layer, offsetBy: -rising)

        let spring = CASpringAnimation(
            perceptualDuration: Style.Motion.entrySettle,
            bounce: Style.Motion.entryBounce
        )
        spring.keyPath = "transform"
        spring.fromValue = NSValue(caTransform3D: start)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.duration = spring.settlingDuration

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
        layer.add(spring, forKey: key)

        // The fade is not part of the spring and must not be: an opacity that
        // overshoots would have to pass through more than fully opaque, which
        // is not a thing, and Core Animation clamps it into a visible hitch.
        view.alphaValue = 0
        // AppKit's completion handler is not typed as main-actor-isolated, so a
        // main-actor closure cannot be handed to it directly. It does in fact
        // run on the main queue, which is what the assertion below relies on;
        // the unsafe marking is what lets the closure make the crossing at all.
        nonisolated(unsafe) let finish = completion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Style.Motion.duration(Style.Motion.entrySettle) / 2
            context.timingFunction = Style.Motion.curve
            view.animator().alphaValue = 1
        } completionHandler: {
            MainActor.assumeIsolated { finish?() }
        }
    }

    /// Springs `view` into place from an offset, without touching its opacity.
    ///
    /// For a row a list is inserting. The list is already fading the row in as
    /// it opens a gap for it, so a second fade here would double up; all this
    /// contributes is the travel. It is a pure translation, which is what makes
    /// it safe to start on a cell the table has built but not yet laid out:
    /// there is no scale, so nothing depends on the layer's bounds or anchor
    /// point being settled yet.
    ///
    /// - Parameters:
    ///   - offset: where the view starts, relative to where it belongs, in the
    ///     view's own coordinates. Negative `dx` is to the left.
    ///   - fading: whether to fade the view in as well. `false` where something
    ///     else is already fading it -- a table opening a gap for a new row --
    ///     and `true` where nothing is, such as a pane replacing another.
    static func slideIn(_ view: NSView, from offset: CGVector, fading: Bool = false) {
        view.wantsLayer = true
        guard !Style.Motion.isReduced, let layer = view.layer else {
            view.alphaValue = 1
            return
        }

        if fading {
            view.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Style.Motion.duration(Style.Motion.entrySettle) / 2
                context.timingFunction = Style.Motion.curve
                view.animator().alphaValue = 1
            }
        }

        // Positive y is up in a layer, and a table's rows are laid out in a
        // flipped view, so the caller's `dy` is negated to keep "down" meaning
        // down at the call site.
        let start = CATransform3DMakeTranslation(offset.dx, -offset.dy, 0)

        let spring = CASpringAnimation(
            perceptualDuration: Style.Motion.entrySettle,
            bounce: Style.Motion.entryBounce
        )
        spring.keyPath = "transform"
        spring.fromValue = NSValue(caTransform3D: start)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.duration = spring.settlingDuration

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
        layer.add(spring, forKey: key)
    }

    /// Fades and settles `view` back out, then hands it to `completion` --
    /// which is where a caller removes it from its superview.
    static func disappear(_ view: NSView, falling: CGFloat, completion: @escaping () -> Void) {
        guard !Style.Motion.isReduced, let layer = view.layer else {
            view.alphaValue = 0
            completion()
            return
        }

        let target = centredScale(Style.Motion.entryScale, in: layer, offsetBy: -falling)
        let slide = CABasicAnimation(keyPath: "transform")
        slide.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? layer.transform)
        slide.toValue = NSValue(caTransform3D: target)
        slide.duration = Style.Motion.exit
        slide.timingFunction = Style.Motion.curve

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = target
        CATransaction.commit()
        layer.add(slide, forKey: key)

        nonisolated(unsafe) let finish = completion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Style.Motion.duration(Style.Motion.exit)
            context.timingFunction = Style.Motion.curve
            view.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { finish() }
        }
    }

    /// A scale about the layer's centre, with a vertical offset applied after
    /// it.
    ///
    /// Built around the centre explicitly rather than trusting the anchor
    /// point, for the same reason `SpringPress` does: a layer whose anchor has
    /// been moved would otherwise grow out of a corner. Positive `dy` is up,
    /// because this is layer geometry and not a flipped view's.
    private static func centredScale(
        _ scale: CGFloat, in layer: CALayer, offsetBy dy: CGFloat
    ) -> CATransform3D {
        let size = layer.bounds.size
        let offsetX = (0.5 - layer.anchorPoint.x) * size.width
        let offsetY = (0.5 - layer.anchorPoint.y) * size.height
        var transform = CATransform3DMakeTranslation(offsetX, offsetY + dy, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -offsetX, -offsetY, 0)
        return transform
    }
}
