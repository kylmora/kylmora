import Testing
import AppKit
@testable import Kylmora

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@Suite("Mouse Gestures and Rocker Navigation (F-19)")
@MainActor
struct MouseGestureTests {

    @Test("Cardinal direction calculation correctly classifies 2D deltas")
    func testDirectionRecognition() {
        // Horizontal
        #expect(MouseGestureRecognizer.direction(dx: -30, dy: 5, minThreshold: 20) == .left)
        #expect(MouseGestureRecognizer.direction(dx: 30, dy: -5, minThreshold: 20) == .right)

        // Vertical (AppKit y goes up)
        #expect(MouseGestureRecognizer.direction(dx: 2, dy: 35, minThreshold: 20) == .up)
        #expect(MouseGestureRecognizer.direction(dx: -2, dy: -35, minThreshold: 20) == .down)

        // Sub-threshold movements return nil
        #expect(MouseGestureRecognizer.direction(dx: 5, dy: 5, minThreshold: 20) == nil)
        #expect(MouseGestureRecognizer.direction(dx: 0, dy: 0, minThreshold: 20) == nil)
    }

    @Test("Stroke pattern matching resolves all standard mouse gesture actions")
    func testStrokeMatching() {
        #expect(MouseGestureAction.match(strokes: [.left]) == .back)
        #expect(MouseGestureAction.match(strokes: [.right]) == .forward)
        #expect(MouseGestureAction.match(strokes: [.down]) == .newTab)
        #expect(MouseGestureAction.match(strokes: [.up]) == .scrollToTop)
        #expect(MouseGestureAction.match(strokes: [.up, .down]) == .reload)
        #expect(MouseGestureAction.match(strokes: [.down, .right]) == .closeTab)
        #expect(MouseGestureAction.match(strokes: [.down, .left]) == .reopenClosedTab)
        #expect(MouseGestureAction.match(strokes: [.up, .right]) == .nextTab)
        #expect(MouseGestureAction.match(strokes: [.up, .left]) == .previousTab)

        // Unrecognized combination
        #expect(MouseGestureAction.match(strokes: [.left, .up, .left]) == nil)
    }

    @Test("Mouse gesture settings flags toggle and post notifications")
    func testSettings() {
        let initial = Settings.shared.mouseGesturesEnabled
        defer { Settings.shared.mouseGesturesEnabled = initial }

        let fired = Box(false)
        let token = NotificationCenter.default.addObserver(
            forName: .mouseGesturesSettingDidChange,
            object: nil,
            queue: .main
        ) { _ in
            fired.value = true
        }
        defer { NotificationCenter.default.removeObserver(token) }

        Settings.shared.mouseGesturesEnabled = !initial
        #expect(Settings.shared.mouseGesturesEnabled == !initial)
        #expect(fired.value)

        // Rocker & trail settings
        let rockerInit = Settings.shared.rockerGesturesEnabled
        defer { Settings.shared.rockerGesturesEnabled = rockerInit }
        Settings.shared.rockerGesturesEnabled = !rockerInit
        #expect(Settings.shared.rockerGesturesEnabled == !rockerInit)

        let trailInit = Settings.shared.gestureTrailsEnabled
        defer { Settings.shared.gestureTrailsEnabled = trailInit }
        Settings.shared.gestureTrailsEnabled = !trailInit
        #expect(Settings.shared.gestureTrailsEnabled == !trailInit)
    }

    @Test("GestureTrailView accumulates points and updates HUD content")
    func testGestureTrailView() {
        let trail = GestureTrailView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        #expect(trail.points.isEmpty)

        trail.addPoint(NSPoint(x: 10, y: 10))
        trail.addPoint(NSPoint(x: 50, y: 10))
        #expect(trail.points.count == 2)

        trail.actionTitle = "Back"
        trail.actionSymbol = "arrow.left"
        trail.strokesText = "←"
        #expect(trail.actionTitle == "Back")

        trail.reset()
        #expect(trail.points.isEmpty)
        #expect(trail.actionTitle == nil)
    }

    @Test("Rocker Left gesture triggers history Back action")
    func testRockerLeft() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        window.contentView = contentView

        let controller = MouseGestureController(window: window)
        defer { controller.teardown() }

        let triggeredAction = Box<MouseGestureAction?>(nil)
        controller.onAction = { action in
            triggeredAction.value = action
        }

        // 1. Right mouse down
        let rightDown = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 100, y: 100),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )!
        _ = controller.handleEvent(rightDown)

        // 2. Left mouse down while right is held -> Rocker Left
        let leftDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 100, y: 100),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1.0
        )!
        let result = controller.handleEvent(leftDown)

        #expect(result == nil) // Swallowed
        #expect(triggeredAction.value == .back)
    }

    @Test("Rocker Right gesture triggers history Forward action")
    func testRockerRight() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let controller = MouseGestureController(window: window)
        defer { controller.teardown() }

        let triggeredAction = Box<MouseGestureAction?>(nil)
        controller.onAction = { action in
            triggeredAction.value = action
        }

        // 1. Left mouse down
        let leftDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 100, y: 100),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )!
        _ = controller.handleEvent(leftDown)

        // 2. Right mouse down while left is held -> Rocker Right
        let rightDown = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 100, y: 100),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1.0
        )!
        let result = controller.handleEvent(rightDown)

        #expect(result == nil) // Swallowed
        #expect(triggeredAction.value == .forward)
    }

    @Test("Hold-right-and-swipe left executes Back gesture")
    func testHoldRightAndSwipeLeft() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let controller = MouseGestureController(window: window)
        defer { controller.teardown() }

        let triggeredAction = Box<MouseGestureAction?>(nil)
        controller.onAction = { action in
            triggeredAction.value = action
        }

        // 1. Right mouse down at (200, 200)
        let rightDown = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 200, y: 200),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )!
        _ = controller.handleEvent(rightDown)

        // 2. Drag left to (120, 200) -> dx = -80, stroke recognized: .left
        let drag = NSEvent.mouseEvent(
            with: .rightMouseDragged,
            location: NSPoint(x: 120, y: 200),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1.0
        )!
        _ = controller.handleEvent(drag)
        #expect(controller.recognizedStrokes == [.left])

        // 3. Right mouse up -> finishes gesture
        let rightUp = NSEvent.mouseEvent(
            with: .rightMouseUp,
            location: NSPoint(x: 120, y: 200),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 3,
            clickCount: 1,
            pressure: 0.0
        )!
        let result = controller.handleEvent(rightUp)

        #expect(result == nil) // Swallowed, suppresses context menu
        #expect(triggeredAction.value == .back)
    }

    @Test("CommandCatalog contains toggle-mouse-gestures")
    func testCommandCatalog() {
        let ids = CommandCatalog.all.map(\.id)
        #expect(ids.contains("toggle-mouse-gestures"))
    }
}
