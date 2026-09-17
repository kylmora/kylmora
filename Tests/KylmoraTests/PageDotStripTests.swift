import AppKit
import Testing
@testable import Kylmora

// The row of space dots at the foot of the sidebar. With a dozen spaces it was
// wider than the gap between the two buttons and drew straight through the
// Archive button; the last dot sat on top of it.

@Suite("The space dots")
@MainActor
struct PageDotStripTests {
    private let pitch = Style.Metrics.pageDotSpacing

    @Test("A row that fits is left exactly as it was")
    func fittingRowIsUntouched() {
        let layout = PageDotStrip.layout(count: 5, selected: 0, availableWidth: 400)
        #expect(layout.offset == 0)
        #expect(!layout.cutAtStart)
        #expect(!layout.cutAtEnd)
        for index in 0..<5 {
            #expect(PageDotStrip.alpha(ofDotAt: index, in: layout, availableWidth: 400) == 1)
        }
    }

    @Test("Too many dots slide rather than overflow")
    func tooManyDotsSlide() {
        let width: CGFloat = 100
        let layout = PageDotStrip.layout(count: 20, selected: 19, availableWidth: width)
        #expect(layout.fullWidth > width)
        #expect(layout.offset > 0)
        // The last dot is what you are on, so it has to be on screen.
        let last = PageDotStrip.centre(of: 19) - layout.offset
        #expect(last <= width)
        #expect(last >= 0)
    }

    @Test("The space you are in is never the one that got cut off")
    func selectedStaysVisible() {
        let width: CGFloat = 90
        for selected in 0..<24 {
            let layout = PageDotStrip.layout(count: 24, selected: selected, availableWidth: width)
            let x = PageDotStrip.centre(of: selected) - layout.offset
            #expect(x >= 0 && x <= width, "dot \(selected) sits at \(x) in \(width)")
            #expect(
                PageDotStrip.alpha(ofDotAt: selected, in: layout, availableWidth: width) > 0.4,
                "the dot you are on must not be faded away"
            )
        }
    }

    @Test("Only a cut edge fades")
    func endsThatAreRealEndsStaySolid() {
        // Fading an edge where the dots genuinely stop would be a lie about how
        // many spaces there are.
        let width: CGFloat = 100
        let atStart = PageDotStrip.layout(count: 20, selected: 0, availableWidth: width)
        #expect(!atStart.cutAtStart, "nothing is hidden before the first dot")
        #expect(atStart.cutAtEnd)
        #expect(PageDotStrip.alpha(ofDotAt: 0, in: atStart, availableWidth: width) == 1)

        let atEnd = PageDotStrip.layout(count: 20, selected: 19, availableWidth: width)
        #expect(atEnd.cutAtStart)
        #expect(!atEnd.cutAtEnd)
        #expect(PageDotStrip.alpha(ofDotAt: 19, in: atEnd, availableWidth: width) == 1)
    }

    @Test("A dot goes out gradually, not all at once")
    func fadeIsARamp() {
        let width: CGFloat = 100
        let layout = PageDotStrip.layout(count: 20, selected: 10, availableWidth: width)
        #expect(layout.cutAtStart && layout.cutAtEnd)
        // Walking in from the leading edge, each dot is at least as solid as
        // the one before it, and the first visible ones are part-way.
        let alphas = (0..<20).map {
            PageDotStrip.alpha(ofDotAt: $0, in: layout, availableWidth: width)
        }.filter { $0 > 0 }
        #expect(alphas.first! < 1, "the dot at a cut edge is part-way out")
        #expect(alphas.contains { $0 == 1 }, "the middle of the row is solid")
    }

    @Test("A click lands on the dot under the pointer, not where it used to be")
    func clicksFollowTheSlide() {
        let width: CGFloat = 100
        let layout = PageDotStrip.layout(count: 20, selected: 19, availableWidth: width)
        #expect(layout.offset > 0)
        let x = PageDotStrip.centre(of: 19) - layout.offset
        #expect(PageDotStrip.index(at: x, count: 20, in: layout) == 19)
        // And without the slide it would have been a much earlier dot.
        let naive = Int((x / pitch).rounded(.down))
        #expect(naive != 19)
    }

    @Test("One space needs no indicator")
    func oneSpaceIsNoRow() {
        #expect(PageDotStrip.fullWidth(count: 1) == 0)
        #expect(PageDotStrip.index(at: 4, count: 1, in: PageDotStrip.layout(
            count: 1, selected: 0, availableWidth: 100
        )) == nil)
    }

    @Test("Drawn, the edge dots really are fainter than the middle ones")
    func theViewActuallyFades() {
        // The arithmetic above is only worth having if it reaches the screen.
        // Rendered offscreen and the pixels read back.
        let view = PageDotsView()
        view.frame = NSRect(x: 0, y: 0, width: 100, height: Style.Metrics.iconButtonSide)
        view.show(count: 20, selected: 10)
        view.layoutSubtreeIfNeeded()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Issue.record("the view should be able to draw itself offscreen")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)

        let layout = PageDotStrip.layout(count: 20, selected: 10, availableWidth: 100)
        // `colorAt` counts pixels, not points, and the rep is Retina-sized.
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        /// How much ink landed on a dot, as coverage from 0 to 1.
        func ink(at index: Int) -> CGFloat {
            let x = Int(((PageDotStrip.centre(of: index) - layout.offset) * scale).rounded())
            let y = rep.pixelsHigh / 2
            guard let pixel = rep.colorAt(x: x, y: y) else { return 0 }
            // Whatever the appearance, a dot differs from the empty background
            // by its alpha: the view draws nothing else.
            return pixel.alphaComponent
        }

        let middle = ink(at: 10)
        #expect(middle > 0.3, "the middle of the row is drawn")
        let atEdge = ink(at: 0)
        #expect(atEdge < middle, "a dot at a cut edge is fainter than one in the middle")
    }
}
