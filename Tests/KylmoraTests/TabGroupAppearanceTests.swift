import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("Tab group appearance")
struct TabGroupAppearanceTests {
    @Test("The default is standard, and only a fill or an edge makes it custom")
    func standard() {
        #expect(TabGroupAppearance.standard.isStandard)
        #expect(TabGroupAppearance().isStandard)
        #expect(!TabGroupAppearance(fill: .solid).isStandard)
        #expect(!TabGroupAppearance(elevation: .soft).isStandard)
        // A direction alone is not custom: it only matters once there is a
        // gradient to point.
        #expect(TabGroupAppearance(direction: .upRight).isStandard)
    }

    @Test("A standard fill has no gradient; a coloured one does")
    func gradientPresence() {
        let fallback = NSColor.gray
        #expect(TabGroupAppearance.standard.gradient(fallback: fallback) == nil)
        #expect(TabGroupAppearance(fill: .solid, startColorHex: "#ff0000").gradient(fallback: fallback) != nil)
        #expect(TabGroupAppearance(fill: .gradient, startColorHex: "#ff0000", endColorHex: "#00ff00")
            .gradient(fallback: fallback) != nil)
    }

    @Test("Colours resolve from hex, and fall back when unset")
    func colourResolution() {
        let fallback = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        let solid = TabGroupAppearance(fill: .solid, startColorHex: "#ff0000")
        #expect(solid.startColor(fallback: fallback).hexString == "#ff0000")
        // A solid fill's second stop is its own colour, so both stops are set.
        #expect(solid.endColor(fallback: fallback).hexString == "#ff0000")

        // A half-set gradient leans on the fallback for the missing stop.
        let half = TabGroupAppearance(fill: .gradient, startColorHex: nil, endColorHex: "#00ff00")
        #expect(half.startColor(fallback: fallback).hexString == fallback.hexString)
        #expect(half.endColor(fallback: fallback).hexString == "#00ff00")
    }

    @Test("Every direction has a distinct angle, top-to-bottom at 90 in the flipped view")
    func directionAngles() {
        #expect(TabGroupAppearance.Direction.down.angle == 90)
        #expect(TabGroupAppearance.Direction.up.angle == 270)
        #expect(TabGroupAppearance.Direction.right.angle == 0)
        #expect(TabGroupAppearance.Direction.left.angle == 180)
        let angles = TabGroupAppearance.Direction.allCases.map(\.angle)
        #expect(Set(angles).count == angles.count)
    }

    @Test("Elevation rims grow with the level, and flat has none")
    func elevationRims() throws {
        #expect(TabGroupAppearance.Elevation.none.rim == nil)
        let soft = try #require(TabGroupAppearance.Elevation.soft.rim)
        let bold = try #require(TabGroupAppearance.Elevation.bold.rim)
        #expect(bold.alpha > soft.alpha)
        #expect(bold.width >= soft.width)
    }

    @Test("Encoding is tolerant: unknown values and missing keys fall back")
    func tolerantDecoding() throws {
        // A full appearance round-trips byte for byte.
        let full = TabGroupAppearance(fill: .gradient, startColorHex: "#112233",
                                      endColorHex: "#445566", direction: .downRight, elevation: .bold)
        let data = try JSONEncoder().encode(full)
        #expect(try JSONDecoder().decode(TabGroupAppearance.self, from: data) == full)

        // A junk fill and direction land on the defaults rather than throwing.
        let junk = Data(#"{"fill":"spooky","direction":"sideways","elevation":"soft"}"#.utf8)
        let decoded = try JSONDecoder().decode(TabGroupAppearance.self, from: junk)
        #expect(decoded.fill == .standard)
        #expect(decoded.direction == .down)
        #expect(decoded.elevation == .soft)

        // An empty object is the standard appearance.
        #expect(try JSONDecoder().decode(TabGroupAppearance.self, from: Data("{}".utf8)).isStandard)
    }
}

@Suite("Folder plate geometry")
struct FolderPlateGeometryTests {
    @Test("One plate's rows share a height and stack their offsets from the top")
    func stackedOffsets() {
        // A header (38 = 32 header + 6 gap) and two 32-point child rows.
        let placed = FolderPlateGeometry.slices(rowHeights: [38, 32, 32], gap: 6)
        #expect(placed.count == 3)
        // The plate is header content (32) plus the two children: 96 tall.
        #expect(placed.allSatisfy { $0.plateHeight == 96 })
        // The header's plate starts a gap below its own top.
        #expect(placed[0].plateTop == 6)
        // The first child sits one header-content down from the plate top.
        #expect(placed[1].plateTop == -32)
        // The second another child-height further.
        #expect(placed[2].plateTop == -64)
    }

    @Test("A one-row plate is its header's content tall, anchored at the gap")
    func singleRow() {
        let placed = FolderPlateGeometry.slices(rowHeights: [38], gap: 6)
        #expect(placed.count == 1)
        #expect(placed.first?.plateTop == 6)
        #expect(placed.first?.plateHeight == 32)
    }

    @Test("No rows means no slices")
    func empty() {
        #expect(FolderPlateGeometry.slices(rowHeights: [], gap: 6).isEmpty)
    }
}
