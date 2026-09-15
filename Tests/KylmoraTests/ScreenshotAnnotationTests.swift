import AppKit
import Foundation
import Testing
@testable import Kylmora

private final class MenuStub: NSObject, NSMenuDelegate {}

@Suite("Screenshot annotation")
@MainActor
struct ScreenshotAnnotationTests {
    private func solid(_ color: NSColor, size: NSSize = NSSize(width: 200, height: 120)) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    private func rgb(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat) {
        let c = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.extendedSRGB) ?? color
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }

    /// Rendering goes through a wide-gamut backing store, so a mark's pixels
    /// are near its colour rather than equal to it. Near enough means the
    /// expected colour is the closest of the palette plus white.
    private func isClose(_ color: NSColor?, to other: NSColor) -> Bool {
        guard let color else { return false }
        let a = rgb(color)
        func distance(_ c: NSColor) -> CGFloat {
            let b = rgb(c)
            return (a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1) + (a.2 - b.2) * (a.2 - b.2)
        }
        let palette = AnnotationColor.allCases.map(\.nsColor) + [NSColor.white]
        let nearest = palette.min { distance($0) < distance($1) }!
        return distance(nearest) == distance(other)
    }

    @Test("Marks are drawn where they were placed, and nothing else changes")
    func rendering() {
        var shot = AnnotatedScreenshot(image: solid(.white))
        shot.annotations = [
            .rectangle(CGRect(x: 20, y: 20, width: 60, height: 40), color: .red, width: 4),
            .highlight(CGRect(x: 120, y: 20, width: 40, height: 40), color: .yellow),
            .arrow(from: CGPoint(x: 20, y: 100), to: CGPoint(x: 90, y: 100), color: .blue, width: 4),
            .text("Hi", at: CGPoint(x: 130, y: 80), color: .black, size: 20)
        ]
        let out = shot.render()
        #expect(out.size == NSSize(width: 200, height: 120))
        #expect(isClose(AnnotatedScreenshot.pixel(of: out, at: CGPoint(x: 20, y: 40)), to: AnnotationColor.red.nsColor), "the box's left edge is red")
        #expect(isClose(AnnotatedScreenshot.pixel(of: out, at: CGPoint(x: 50, y: 40)), to: .white), "inside the box is untouched")
        let highlighted = AnnotatedScreenshot.pixel(of: out, at: CGPoint(x: 140, y: 40)).map(rgb)
        #expect((highlighted?.2 ?? 1) < 0.9, "a highlight tints without hiding")
        #expect(isClose(AnnotatedScreenshot.pixel(of: out, at: CGPoint(x: 55, y: 100)), to: AnnotationColor.blue.nsColor), "the arrow's shaft is blue")
        #expect(isClose(AnnotatedScreenshot.pixel(of: out, at: CGPoint(x: 190, y: 5)), to: .white), "a corner far from every mark stays white")
    }

    @Test("A blur destroys the detail underneath it")
    func blur() {
        // A sharp edge between black and white; after pixelation the edge is a smear.
        let size = NSSize(width: 120, height: 120)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        NSColor.black.setFill(); NSRect(x: 0, y: 0, width: 60, height: 120).fill()
        image.unlockFocus()
        var shot = AnnotatedScreenshot(image: image)
        shot.annotations = [.blur(CGRect(x: 40, y: 40, width: 40, height: 40))]
        let out = shot.render()
        let inside = AnnotatedScreenshot.pixel(of: out, at: CGPoint(x: 59, y: 60)).map(rgb)
        #expect((inside?.0 ?? 0) > 0.1 && (inside?.0 ?? 1) < 0.9, "the edge inside the blur is grey now")
        #expect(isClose(AnnotatedScreenshot.pixel(of: out, at: CGPoint(x: 59, y: 10)), to: .black), "outside the blur the edge is still sharp")
    }

    @Test("A crop keeps only the chosen part, at its size")
    func crop() {
        var shot = AnnotatedScreenshot(image: solid(.white))
        shot.annotations = [.rectangle(CGRect(x: 10, y: 10, width: 50, height: 50), color: .green, width: 6)]
        shot.crop = CGRect(x: 10, y: 10, width: 80, height: 60)
        let out = shot.render()
        #expect(out.size == NSSize(width: 80, height: 60))
        #expect(isClose(AnnotatedScreenshot.pixel(of: out, at: CGPoint(x: 1, y: 30)), to: AnnotationColor.green.nsColor), "the box edge moved with the crop")
        shot.crop = CGRect(x: -500, y: -500, width: 10, height: 10)
        #expect(shot.render().size == NSSize(width: 200, height: 120), "a crop outside the picture is ignored")
    }

    @Test("The canvas adds, undoes and bakes a crop")
    func canvas() {
        let canvas = AnnotationCanvas(shot: AnnotatedScreenshot(image: solid(.white)))
        canvas.add(.rectangle(CGRect(x: 0, y: 0, width: 10, height: 10), color: .red, width: 2))
        canvas.add(.blur(CGRect(x: 0, y: 0, width: 10, height: 10)))
        #expect(canvas.shot.annotations.count == 2)
        canvas.undo()
        #expect(canvas.shot.annotations.count == 1)
        canvas.undo()
        #expect(canvas.shot.annotations.isEmpty)
        canvas.undo()
        #expect(canvas.shot.annotations.isEmpty, "nothing left to undo is fine")

        let editor = ScreenshotEditorWindowController(image: solid(.white), tabTitle: "T", pageURL: nil)
        #expect(editor.window?.title == "Annotate Screenshot")
        #expect(editor.shot.size == NSSize(width: 200, height: 120))
    }

    @Test("The editor is reachable from the menu, the palette and the shortcut list")
    func wiring() {
        let stub = MenuStub()
        let menu = MainMenu.build(bookmarks: stub, history: stub, tabs: stub, pinnedSites: stub, spaces: stub)
        let file = menu.items.first { $0.title == "File" }?.submenu
        let capture = file?.items.first { $0.title == "Capture Screenshot" }?.submenu
        let annotate = capture?.items.first { $0.title == "Capture and Annotate Visible Area\u{2026}" }
        #expect(annotate?.keyEquivalent == "3")
        #expect(annotate?.keyEquivalentModifierMask == [.command, .option, .control])
        #expect(capture?.items.contains { $0.title == "Capture and Annotate Full Page\u{2026}" } == true)
        for id in ["annotate-visible-area", "annotate-full-page"] {
            #expect(CommandCatalog.all.contains { $0.id == id })
            let definition = ShortcutManager.shared.definition(for: id)
            #expect(definition != nil)
            if let definition { #expect(BrowserWindowController.instancesRespond(to: definition.selector)) }
        }
    }
}
