import AppKit
import Testing
@testable import Kylmora

// The card at the top of the New Space sheet. It used to be the tab group
// editor's preview, which draws a fill and nothing else: choosing Light, Dark
// or Website changed the whole window and not one pixel of the card, and the
// transparency slider moved nothing at all.

@Suite("The New Space preview shows what will be made")
@MainActor
struct SpacePreviewTests {
    private func rendered(_ look: SpacePreviewLook) -> NSBitmapImageRep? {
        let view = SpacePreviewView()
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 92)
        view.look = look
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The colour in the middle of the card, where nothing but the material and
    /// the wash are drawn.
    private func middle(of look: SpacePreviewLook) -> NSColor? {
        guard let rep = rendered(look) else { return nil }
        return rep.colorAt(x: rep.pixelsWide - 20, y: rep.pixelsHigh / 2)?
            .usingColorSpace(.sRGB)
    }

    private func brightness(_ colour: NSColor?) -> CGFloat {
        guard let colour else { return -1 }
        return 0.299 * colour.redComponent + 0.587 * colour.greenComponent
            + 0.114 * colour.blueComponent
    }

    @Test("Light and Dark draw a light and a dark window")
    func presetsChangeTheMaterial() {
        let light = brightness(middle(of: SpacePreviewLook(appearance: .light, wash: nil)))
        let dark = brightness(middle(of: SpacePreviewLook(appearance: .dark, wash: nil)))
        #expect(light > 0.7, "a light window is light")
        #expect(dark < 0.3, "and a dark one is dark")
    }

    @Test("A colour of its own tints the card")
    func customisedIsTinted() {
        let plain = middle(of: SpacePreviewLook(appearance: .light, wash: nil))
        let tinted = middle(of: SpacePreviewLook(
            appearance: .light, wash: .solid(.systemRed), washOpacity: 1
        ))
        #expect(plain != nil && tinted != nil)
        // Measured as how far the colour leans red, not as how much red it
        // holds: the material is already near-white, so a red veil over it
        // takes green and blue away rather than adding red.
        func lean(_ colour: NSColor?) -> CGFloat {
            guard let colour else { return 0 }
            return colour.redComponent - colour.blueComponent
        }
        #expect(lean(tinted) > lean(plain) + 0.02, "the red wash should reach the card")
    }

    @Test("Transparency fades the colour away")
    func transparencyThins() {
        // The slider moved nothing at all before: the card drew the fill at
        // full strength whatever it said.
        let full = middle(of: SpacePreviewLook(
            appearance: .light, wash: .solid(.systemRed), washOpacity: 1
        ))
        let faint = middle(of: SpacePreviewLook(
            appearance: .light, wash: .solid(.systemRed), washOpacity: 0.2
        ))
        #expect(brightness(faint) > brightness(full), "less wash leaves more material")
    }

    @Test("A preset carries no colour, whatever the fill says")
    func presetsAreNotTinted() {
        // The sheet passes no wash at all for Automatic, Light, Dark and
        // Website; this is what makes Light look like a plain light window
        // rather than a tinted one.
        let light = middle(of: SpacePreviewLook(appearance: .light, wash: nil))
        let lightAgain = middle(of: SpacePreviewLook(appearance: .light, wash: nil, washOpacity: 0.3))
        #expect(brightness(light) == brightness(lightAgain))
    }

    @Test("A gradient draws as a gradient, not as one flat colour")
    func gradientHasTwoEnds() {
        let look = SpacePreviewLook(
            appearance: .light,
            wash: .gradient(SpaceGradient(startHex: "#ff0000", endHex: "#0000ff", direction: .down))
        )
        guard let rep = rendered(look) else {
            Issue.record("the card should draw")
            return
        }
        let top = rep.colorAt(x: rep.pixelsWide / 2, y: 12)?.usingColorSpace(.sRGB)
        let bottom = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh - 12)?.usingColorSpace(.sRGB)
        #expect((top?.redComponent ?? 0) != (bottom?.redComponent ?? 0), "the ends differ")
    }

    @Test("Website says it takes the page's colour rather than inventing one")
    func websiteSaysSo() {
        // There is no page yet, so guessing a colour would be a picture of a
        // decision nobody made.
        let plain = brightness(middle(of: SpacePreviewLook(appearance: .system, wash: nil)))
        let website = brightness(middle(of: SpacePreviewLook(
            appearance: .system, wash: nil, followsPageColour: true
        )))
        #expect(plain == website, "no colour is invented for it")
    }
}
