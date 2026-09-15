import AppKit
import QuartzCore

/// A vertical stack whose rows can be dragged into a different order.
///
/// Arrows move a row one place at a time, which is fine for a nudge and
/// tedious for anything else: getting the last item to the top is nine clicks
/// and nine redraws, and at no point does the list show you where the item is
/// going to land. Dragging shows exactly that, the whole way.
///
/// The rows are not restructured while the drag is in flight. The one being
/// dragged is lifted -- raised above its neighbours and given a shadow, so it
/// reads as picked up rather than as a row that has come loose -- and moved by
/// a layer transform; the rows it passes slide one slot out of its way by the
/// same means. Nothing is committed until the mouse comes up, at which point
/// the owner is told the old and new positions and rebuilds the list. That
/// keeps the model the single source of the order: this view never edits it,
/// and a drag that is abandoned leaves nothing behind to undo.
///
/// A press that lands on a control inside a row never reaches here, because
/// the control handles it first. So a switch stays a switch and a button stays
/// a button; everything else in the row is a handle.
@MainActor
final class ReorderableStackView: NSStackView {
    /// A row was dragged from one position to another. The owner is expected
    /// to move the item in its model and rebuild the rows.
    var onReorder: ((_ from: Int, _ to: Int) -> Void)?

    /// How far the pointer must travel before this is a drag rather than a
    /// click. Below it, a press that wanders by a pixel still reaches whatever
    /// the row does on click.
    private static let threshold: CGFloat = 3

    /// One drag in flight, as pure geometry.
    ///
    /// Everything the drag decides lives here rather than inside the tracking
    /// loop, so all of it can be checked without a mouse, a window or an event
    /// queue: where the row lands, and how far each row it passes has to move
    /// to open a gap for it. The loop's only job is to read the pointer and
    /// apply what this says.
    struct Drag {
        /// Each row's centre before anything moved, in the stack's own
        /// coordinates.
        let centres: [CGFloat]
        /// Which row is being dragged.
        let index: Int
        /// Whether centres fall as the index rises, which is the case in an
        /// unflipped view where the first row is at the top. Read from the
        /// rows rather than assumed, so this works either way up.
        let descending: Bool

        init(centres: [CGFloat], index: Int) {
            self.centres = centres
            self.index = index
            self.descending = centres.count < 2 || centres[0] > centres[1]
        }

        /// The distance between two neighbouring rows' centres.
        var pitch: CGFloat { centres.count < 2 ? 0 : abs(centres[0] - centres[1]) }

        /// The slot the dragged row is over, having been moved this far.
        ///
        /// The dragged row's own centre is excluded from the comparison: it is
        /// the thing being placed, not an obstacle to place it against.
        func target(forOffset offset: CGFloat) -> Int {
            let centre = centres[index] + offset
            var slot = 0
            for (other, position) in centres.enumerated() where other != index {
                // Rows still sitting before the dragged one push it further
                // down the order; the ones after it do not.
                if descending ? (position > centre) : (position < centre) { slot += 1 }
            }
            return min(max(slot, 0), max(centres.count - 1, 0))
        }

        /// How far a row has to slide to open a gap at `target`, in the
        /// stack's own coordinates. Zero for the rows the drag does not pass,
        /// and for the dragged row itself, which the loop moves.
        func shift(forRow row: Int, target: Int) -> CGFloat {
            guard row != index else { return 0 }
            // One slot towards the top of the list: up the screen is a larger
            // y unless the view is flipped.
            let towardsTop = descending ? pitch : -pitch
            if target > index, row > index, row <= target { return towardsTop }
            if target < index, row >= target, row < index { return -towardsTop }
            return 0
        }
    }

    // MARK: - Dragging

    /// Routes a press to this view unless it landed on something that acts on
    /// clicks itself.
    ///
    /// Without this a row is not draggable by the part of it you would
    /// naturally grab. `NSTextField` is an `NSControl`, and a control consumes
    /// a press even when it is a label with nothing to do -- so pressing the
    /// name and dragging did nothing at all, while pressing the sliver of
    /// empty space between the name and the buttons worked. A control with an
    /// action keeps its own clicks; everything else in a row is a handle.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== self {
            if let control = current as? NSControl, control.action != nil, control.isEnabled {
                return hit
            }
            view = current.superview
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        let rows = arrangedSubviews
        guard rows.count > 1,
              let index = rows.firstIndex(where: { $0.frame.contains(start) })
        else { return super.mouseDown(with: event) }

        let drag = Drag(centres: rows.map(\.frame.midY), index: index)
        let row = rows[index]
        var target = index
        var isDragging = false

        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let point = convert(next.locationInWindow, from: nil)
            let offset = point.y - start.y
            if !isDragging {
                guard abs(offset) > Self.threshold else { continue }
                isDragging = true
                lift(row)
            }
            move(row, by: offset, animated: false)

            let slot = drag.target(forOffset: offset)
            guard slot != target else { continue }
            target = slot
            // The rows between where this one came from and where it is going
            // slide one slot towards the gap it left.
            for (position, other) in rows.enumerated() {
                move(other, by: drag.shift(forRow: position, target: target), animated: true)
            }
        }

        guard isDragging else { return }
        drop(row)
        for other in rows { move(other, by: 0, animated: true) }
        if target != index { onReorder?(index, target) }
    }

    private func move(_ view: NSView, by offset: CGFloat, animated: Bool) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let duration = animated ? Style.Motion.duration(Style.Motion.selection) : 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(Style.Motion.curve)
        CATransaction.setDisableActions(duration == 0)
        layer.setAffineTransform(CGAffineTransform(translationX: 0, y: offset))
        CATransaction.commit()
    }

    /// Picks a row up: above its neighbours, and casting the shadow of
    /// something held off the surface.
    private func lift(_ view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.zPosition = 1
        layer.shadowColor = Style.Colors.rowSelectedShadow.cgColor
        layer.shadowOpacity = 1
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: -2)
        layer.shadowPath = CGPath(
            roundedRect: view.bounds,
            cornerWidth: Style.Metrics.rowCornerRadius,
            cornerHeight: Style.Metrics.rowCornerRadius,
            transform: nil
        )
    }

    private func drop(_ view: NSView) {
        guard let layer = view.layer else { return }
        layer.zPosition = 0
        layer.shadowOpacity = 0
        layer.shadowColor = nil
    }
}
