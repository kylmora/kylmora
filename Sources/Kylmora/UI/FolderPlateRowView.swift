import AppKit

/// The row behind every sidebar cell, which draws the folder plates.
///
/// A folder's plate spans its header and its children, which are separate
/// rows, so each row paints its slice (`FolderPlatePlan`). The row view rather
/// than the cell, because a slice has to run edge to edge under the cell's
/// own pill and hover plate, and a cell is inset from the row on every side.
///
/// A group can colour its plate (`TabGroupAppearance`). A gradient has to run
/// unbroken down the whole card, so a themed slice is drawn by filling the
/// plate's full rounded outline -- which reaches above and below this one row
/// -- clipped to the band of it this row owns. The default plate keeps drawing
/// each slice on its own, unchanged.
@MainActor
final class FolderPlateRowView: NSTableRowView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("folderPlate")

    var slices: [FolderPlateSlice] = [] {
        didSet { if slices != oldValue { needsDisplay = true } }
    }

    /// The table draws its own selection and hover; every cell here does that
    /// itself, so the row draws nothing of the kind.
    override func drawSelection(in dirtyRect: NSRect) {}

    override func drawBackground(in dirtyRect: NSRect) {
        guard !slices.isEmpty else { return }
        let radius = Style.Metrics.folderPlateCornerRadius
        let gap = Style.Metrics.folderPlateGap

        for slice in slices {
            // The plate is inset by the same `sidebarInset` as the pinned tiles
            // above it, so their left edges line up; the header still sits inside
            // it with a margin because the header's own content inset is larger.
            let leading = Style.Metrics.sidebarInset + FolderTree.indent(forDepth: slice.depth)
            let width = bounds.width - leading

            // The fill: the flat default sliced per row, or the group's colour
            // over the whole card. The rim, if any, goes on top of either.
            if slice.appearance.fill == .standard {
                drawDefault(slice.segment, leading: leading, width: width, radius: radius, gap: gap)
            } else {
                drawGradient(slice, leading: leading, width: width, radius: radius, gap: gap)
            }
            if let rim = slice.appearance.elevation.rim {
                drawRim(slice, leading: leading, width: width, radius: radius, gap: gap, rim: rim)
            }
        }
    }

    /// The plate's whole rounded outline, reaching above and below this one row,
    /// and the strip of that outline this row is allowed to paint. Every slice
    /// works from the same outline, so a fill or a rim drawn through the band is
    /// one continuous shape across the rows the table draws separately.
    private func plateOutline(
        _ slice: FolderPlateSlice, leading: CGFloat, width: CGFloat, radius: CGFloat, gap: CGFloat
    ) -> (path: NSBezierPath, rect: NSRect, band: NSRect) {
        var plateRect = NSRect(x: leading, y: bounds.minY + slice.plateTop, width: width, height: slice.plateHeight)
        // `plateTop`/`plateHeight` are measured with +y downward, so a
        // non-flipped view flips them back onto its own axis.
        if !isFlipped {
            plateRect.origin.y = bounds.maxY - slice.plateTop - slice.plateHeight
        }
        let path = NSBezierPath(roundedRect: plateRect, xRadius: radius, yRadius: radius)

        // The band is the whole row, less the gap above a header's plate.
        let (topContinues, _) = continuation(of: slice.segment)
        var band = NSRect(x: leading, y: bounds.minY, width: width, height: bounds.height)
        if !topContinues {
            if isFlipped { band.origin.y += gap }
            band.size.height -= gap
        }
        return (path, plateRect, band)
    }

    /// The plate the sidebar has always drawn: one flat fill, sliced per row,
    /// each slice a rounded rect whose continuing side is pushed off-row so its
    /// arc is clipped away and it meets the next slice in a straight line.
    private func drawDefault(
        _ segment: FolderPlatePlan.Segment,
        leading: CGFloat, width: CGFloat, radius: CGFloat, gap: CGFloat
    ) {
        Style.Colors.folderPlateFill.setFill()
        var rect = bounds
        rect.origin.x = leading
        rect.size.width = width

        let (topContinues, bottomContinues) = continuation(of: segment)
        // In a flipped row view y grows downwards, so "top" is minY.
        let extendsAtMinY = isFlipped ? topContinues : bottomContinues
        let extendsAtMaxY = isFlipped ? bottomContinues : topContinues
        if extendsAtMinY {
            rect.origin.y -= radius
            rect.size.height += radius
        }
        if extendsAtMaxY {
            rect.size.height += radius
        }
        // The header's row is taller by the plate gap; the plate starts under
        // that gap rather than filling the row.
        if !topContinues {
            if isFlipped { rect.origin.y += gap }
            rect.size.height -= gap
        }

        NSGraphicsContext.saveGraphicsState()
        bounds.clip()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A coloured plate: the whole card's outline filled with the group's
    /// gradient, clipped to the band this row shows. Every slice fills the same
    /// outline, so the gradient is one unbroken run however many rows it spans.
    private func drawGradient(
        _ slice: FolderPlateSlice,
        leading: CGFloat, width: CGFloat, radius: CGFloat, gap: CGFloat
    ) {
        guard let gradient = slice.appearance.gradient(fallback: Style.Colors.folderPlateFill) else { return }
        let outline = plateOutline(slice, leading: leading, width: width, radius: radius, gap: gap)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: outline.band).addClip()
        gradient.draw(in: outline.path, angle: slice.appearance.direction.angle)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The raised rim: a light stroke just inside the plate's outline, drawn on
    /// top of whatever fill it has. Like the fill it strokes the whole outline
    /// clipped to this row's band, so the rim never shows a seam between slices.
    private func drawRim(
        _ slice: FolderPlateSlice,
        leading: CGFloat, width: CGFloat, radius: CGFloat, gap: CGFloat,
        rim: (alpha: CGFloat, width: CGFloat)
    ) {
        let outline = plateOutline(slice, leading: leading, width: width, radius: radius, gap: gap)
        // Inset by half the line so the stroke lands inside the fill rather than
        // straddling the edge into the neighbouring plate.
        let inset = outline.rect.insetBy(dx: rim.width / 2, dy: rim.width / 2)
        let rimPath = NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)
        rimPath.lineWidth = rim.width
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: outline.band).addClip()
        NSColor(white: 1, alpha: rim.alpha).setStroke()
        rimPath.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Which sides of a slice continue into the next: the sides whose corner is
    /// squared off rather than rounded.
    private func continuation(of segment: FolderPlatePlan.Segment) -> (top: Bool, bottom: Bool) {
        switch segment {
        case .single: return (false, false)
        case .top: return (false, true)
        case .middle: return (true, true)
        case .bottom: return (true, false)
        }
    }
}
