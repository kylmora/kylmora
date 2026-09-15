import Foundation

/// Which rows sit inside which folder's plate, and which slice of the plate
/// each row draws.
///
/// A folder and its children are drawn on one rounded plate. In an
/// `NSTableView` the header and the children are separate rows, so the plate
/// is drawn in slices: the header takes the top corners, the last child the
/// bottom ones, and the rows between draw straight sides. With the table's
/// row spacing at zero the slices abut and read as one shape. A row inside a
/// nested folder draws a slice of every plate that encloses it, outermost
/// first, each at its own folder's indent.
@MainActor
enum FolderPlatePlan {
    enum Segment: Equatable {
        case top, middle, bottom
        /// A plate one row tall: a collapsed folder, or an empty open one.
        case single
    }

    struct Piece: Equatable {
        /// The folder's depth, which sets how far in the plate starts.
        let depth: Int
        let segment: Segment
        /// The folder this slice belongs to, so the row can look up how the
        /// folder wants its plate painted. Nil is accepted for the structural
        /// tests, which do not care whose plate a slice is.
        let groupID: TabGroup.ID?

        init(depth: Int, segment: Segment, groupID: TabGroup.ID? = nil) {
            self.depth = depth
            self.segment = segment
            self.groupID = groupID
        }
    }

    /// One entry per row: the plate slices it draws, outermost folder first.
    static func pieces(for rows: [TabDropPlan.Row]) -> [[Piece]] {
        var result = Array(repeating: [Piece](), count: rows.count)
        // Open folders, outermost first: the row its header is on, its depth,
        // and which folder it is.
        var open: [(headerRow: Int, depth: Int, groupID: TabGroup.ID)] = []

        func close(_ folder: (headerRow: Int, depth: Int, groupID: TabGroup.ID), lastRow: Int) {
            let id = folder.groupID
            if lastRow == folder.headerRow {
                result[folder.headerRow].append(Piece(depth: folder.depth, segment: .single, groupID: id))
                return
            }
            result[folder.headerRow].append(Piece(depth: folder.depth, segment: .top, groupID: id))
            for row in (folder.headerRow + 1)..<lastRow {
                result[row].append(Piece(depth: folder.depth, segment: .middle, groupID: id))
            }
            result[lastRow].append(Piece(depth: folder.depth, segment: .bottom, groupID: id))
        }

        for (index, row) in rows.enumerated() {
            // Anything no deeper than an open folder's header ends that folder.
            while let last = open.last, row.depth <= last.depth {
                close(last, lastRow: index - 1)
                open.removeLast()
            }
            if case .folder(let group, _) = row {
                open.append((headerRow: index, depth: row.depth, groupID: group.id))
            }
        }
        while let last = open.popLast() {
            close(last, lastRow: rows.count - 1)
        }

        // Slices were appended as folders closed, innermost first; the view
        // wants to paint the outermost plate first so inner ones sit on it.
        return result.map { $0.sorted { $0.depth < $1.depth } }
    }
}

/// A plate slice resolved for drawing: the structural piece plus how its
/// folder wants it painted and where the slice sits in the whole plate.
///
/// A themed group's plate spans rows the table draws one at a time, so a
/// gradient has to be computed over the whole plate and each row shown only
/// its band of it. `plateTop` and `plateHeight` carry that band's placement so
/// the fill runs unbroken from the header to the last child.
struct FolderPlateSlice: Equatable {
    let segment: FolderPlatePlan.Segment
    /// The folder's depth, which sets how far in the plate starts.
    let depth: Int
    let appearance: TabGroupAppearance
    /// The y of the plate's top edge relative to this row's top edge, in the
    /// flipped row view where positive points down. Ignored for the default
    /// plate, which draws each slice on its own.
    let plateTop: CGFloat
    let plateHeight: CGFloat
    /// Clear space this row carries *below* the plate, when the plate ends
    /// here and something that is not another card follows it. Zero anywhere
    /// else. See `FolderPlateGeometry`.
    var gapBelow: CGFloat = 0
}

/// The vertical placement each row's slice needs so one plate's fill runs
/// unbroken across the rows the table draws separately.
///
/// Pure arithmetic over the plate's row heights, kept apart from the view so
/// the sums can be checked without a table. The header row is taller than its
/// content by `gap`, an empty strip above the plate; the last row may be
/// taller by `gapBelow`, an empty strip under it; every other row is all
/// plate.
enum FolderPlateGeometry {
    /// - Parameter rowHeights: the plate's rows, header first.
    /// - Returns: for each row, the plate top's offset from that row's top
    ///   (flipped, positive down) and the plate's full height.
    /// - Parameter gapBelow: empty space under the plate, carried by its last
    ///   row. A card is fenced off above by `gap`; without the same below it,
    ///   a card followed by a loose row crowds that row harder than two plain
    ///   rows crowd each other.
    static func slices(
        rowHeights: [CGFloat], gap: CGFloat, gapBelow: CGFloat = 0
    ) -> [(plateTop: CGFloat, plateHeight: CGFloat)] {
        guard !rowHeights.isEmpty else { return [] }
        // The header row's own plate starts below the gap and the last row's
        // ends above its own; every other row is plate top to bottom.
        var content = rowHeights
        content[0] -= gap
        content[content.count - 1] -= gapBelow
        let total = content.reduce(0, +)

        var result: [(plateTop: CGFloat, plateHeight: CGFloat)] = []
        var above: CGFloat = 0
        for index in rowHeights.indices {
            // The header's plate sits `gap` below the row's top; a child row's
            // top is `above` points past the plate's top, so the plate top is
            // that far above it.
            let plateTop = index == 0 ? gap : -above
            result.append((plateTop: plateTop, plateHeight: total))
            above += content[index]
        }
        return result
    }
}
