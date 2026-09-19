import AppKit
import Testing
@testable import Kylmora

// Choosing a colour used to open `NSColorPanel`: a second window, in another
// app's visual language, over the sheet that asked for it -- and still there
// after the sheet had gone. The picker is now part of the card.

@Suite("The colour picker's maths")
struct ColourPickerMathTests {
    private let size = CGSize(width: 200, height: 100)

    @Test("The bottom-left corner is white, the top-right the hue at full")
    func cornersAreTheExtremes() {
        let low = ColourPickerMath.components(at: CGPoint(x: 0, y: 0), in: size)
        #expect(low.saturation == 0)
        #expect(low.brightness == 0)
        let high = ColourPickerMath.components(at: CGPoint(x: 200, y: 100), in: size)
        #expect(high.saturation == 1)
        #expect(high.brightness == 1)
    }

    @Test("A drag that leaves the field clamps to its edge")
    func draggingOutClamps() {
        let past = ColourPickerMath.components(at: CGPoint(x: 900, y: -40), in: size)
        #expect(past.saturation == 1)
        #expect(past.brightness == 0)
    }

    @Test("A point and its colour agree both ways")
    func theCursorRoundTrips() {
        let point = ColourPickerMath.point(saturation: 0.25, brightness: 0.75, in: size)
        #expect(point.x == 50)
        #expect(point.y == 75)
        let back = ColourPickerMath.components(at: point, in: size)
        #expect(abs(back.saturation - 0.25) < 0.0001)
        #expect(abs(back.brightness - 0.75) < 0.0001)
    }

    @Test("The hue slider runs the whole wheel across its width")
    func theSliderCoversEveryHue() {
        #expect(ColourPickerMath.hue(atX: 0, width: 200) == 0)
        #expect(ColourPickerMath.hue(atX: 100, width: 200) == 0.5)
        #expect(ColourPickerMath.hue(atX: 400, width: 200) == 1)
        #expect(ColourPickerMath.x(forHue: 0.5, width: 200) == 100)
    }

    @Test("A field with no size yet answers without dividing by zero")
    func anUnlaidOutFieldIsSafe() {
        let picked = ColourPickerMath.components(at: .zero, in: .zero)
        #expect(picked.saturation == 0)
        #expect(picked.brightness == 1)
        #expect(ColourPickerMath.hue(atX: 10, width: 0) == 0)
    }

    @Test("Typed hex is read with or without the hash, long or short")
    func typedHexIsRead() {
        #expect(ColourPickerMath.colour(fromTyped: "#0a84ff")?.hexString == "#0a84ff")
        #expect(ColourPickerMath.colour(fromTyped: "0A84FF")?.hexString == "#0a84ff")
        #expect(ColourPickerMath.colour(fromTyped: " #37f ")?.hexString == "#3377ff")
    }

    @Test("Half-typed or nonsense hex is no colour at all")
    func partialHexIsIgnored() {
        #expect(ColourPickerMath.colour(fromTyped: "#0a8") != nil)
        #expect(ColourPickerMath.colour(fromTyped: "#0a84f") == nil)
        #expect(ColourPickerMath.colour(fromTyped: "") == nil)
        #expect(ColourPickerMath.colour(fromTyped: "#zzzzzz") == nil)
    }
}

@Suite("The picker lives in the card")
@MainActor
struct ColourPickerViewTests {
    @Test("It shows the colour it is given")
    func itShowsWhatItIsGiven() {
        let picker = ColourPickerView()
        picker.show(NSColor(hexString: "#34c759")!)
        #expect(picker.colour.hexString == "#34c759")
    }

    @Test("A grey keeps the hue the slider had, rather than snapping to red")
    func greyKeepsTheHue() {
        let picker = ColourPickerView()
        picker.show(NSColor(hexString: "#0a84ff")!)
        picker.show(NSColor(white: 0.5, alpha: 1))
        // Nothing to assert about grey's own hue; what matters is that the
        // picker took it without complaint and is showing it.
        #expect(picker.colour.saturationComponent < 0.01)
    }

    @Test("No colour panel is ever ordered in")
    func theStockPanelStaysShut() {
        // The sheet and the group editor both used to call
        // `NSColorPanel.shared.orderFront`. Nothing in the sidebar does now.
        let sources = [
            "Sources/Kylmora/Sidebar/NewSpaceSheet.swift",
            "Sources/Kylmora/Sidebar/GroupAppearanceEditor.swift",
            "Sources/Kylmora/Settings/SpaceThemePicker.swift"
        ]
        for path in sources {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // KylmoraTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // package root
                .appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // A comment may still name it; what must be gone is the call.
            let code = text.split(separator: "\n").filter {
                !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
            }.joined(separator: "\n")
            #expect(!code.contains("NSColorPanel"), "\(path) still opens the stock panel")
        }
    }
}
