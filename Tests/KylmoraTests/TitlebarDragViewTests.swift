import AppKit
import Testing
@testable import Kylmora

/// The window has no real titlebar, so the behaviours a titlebar would provide
/// are ours to implement — and therefore ours to test.
@Suite("Titlebar strip")
@MainActor
struct TitlebarDragViewTests {
    private func makeWindow() -> (NSWindow, TitlebarDragView) {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 700, height: 450),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let view = TitlebarDragView(frame: NSRect(x: 0, y: 0, width: 700, height: 34))
        window.contentView?.addSubview(view)
        return (window, view)
    }

    private func click(_ count: Int, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 120, y: 10),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: count,
            pressure: 1
        )!
    }

    @Test("A double-click on the strip zooms the window")
    func doubleClickZooms() {
        let (window, view) = makeWindow()
        let original = window.frame

        view.mouseDown(with: click(2, in: window))

        #expect(window.frame != original, "double-click should have zoomed the window")
    }

    @Test("A second double-click restores the previous size")
    func doubleClickTogglesBack() {
        let (window, view) = makeWindow()
        let original = window.frame

        view.mouseDown(with: click(2, in: window))
        view.mouseDown(with: click(2, in: window))

        #expect(window.frame == original, "zoom should toggle back to the original frame")
    }

    @Test("A single click does not resize the window")
    func singleClickDoesNothing() {
        let (window, view) = makeWindow()
        let original = window.frame

        view.mouseDown(with: click(1, in: window))

        #expect(window.frame == original)
    }

    @Test("The strip lets the window be dragged by it")
    func stripIsDraggable() {
        let (_, view) = makeWindow()
        #expect(view.mouseDownCanMoveWindow)
    }
}
