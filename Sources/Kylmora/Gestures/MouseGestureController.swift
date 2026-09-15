import AppKit
import WebKit

/// Manages mouse gestures (Hold-Right-Click-and-Swipe) and Rocker gestures (Left/Right chord clicks)
/// on web page content views.
@MainActor
final class MouseGestureController {
    weak var windowController: BrowserWindowController?
    weak var window: NSWindow?

    /// Optional action override closure for testing or delegation.
    var onAction: ((MouseGestureAction) -> Void)?

    /// Distance in points pointer must travel before a right-drag is treated as a gesture.
    var deadzoneThreshold: CGFloat = 12.0

    /// Minimum stroke distance in points required to recognize a cardinal stroke direction.
    var strokeThreshold: CGFloat = 22.0

    private var eventMonitor: Any?
    private var isLeftMouseDown: Bool = false
    private var pendingRightDownEvent: NSEvent?
    private var isGestureActive: Bool = false
    private var rockerTriggered: Bool = false
    private var isRedispatching: Bool = false

    private var startPoint: NSPoint = .zero
    private var lastStrokePoint: NSPoint = .zero
    private(set) var recognizedStrokes: [MouseGestureDirection] = []
    private var trailView: GestureTrailView?

    init(windowController: BrowserWindowController) {
        self.windowController = windowController
        self.window = windowController.window
        setupMonitor()
    }

    init(window: NSWindow) {
        self.window = window
        setupMonitor()
    }

    func teardown() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        cancelGesture()
    }

    private func setupMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseDragged, .rightMouseUp, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleEvent(event)
        }
    }

    /// Primary event handler. Returns `nil` to swallow an event or `event` to pass it through.
    func handleEvent(_ event: NSEvent) -> NSEvent? {
        guard Settings.shared.mouseGesturesEnabled else { return event }
        guard let win = self.window, (event.window == nil || event.window === win) else { return event }
        if isRedispatching { return event }

        // Cancel on Escape key
        if event.type == .keyDown {
            if event.keyCode == 53 && (isGestureActive || pendingRightDownEvent != nil) {
                cancelGesture()
                return nil
            }
            return event
        }

        // If no gesture in progress, only intercept if pointer is inside a content web view
        if !isGestureActive && pendingRightDownEvent == nil && !isLeftMouseDown {
            guard isInsideWebArea(event) else { return event }
        }

        switch event.type {
        case .leftMouseDown:
            isLeftMouseDown = true
            if Settings.shared.rockerGesturesEnabled && pendingRightDownEvent != nil {
                // Rocker Left: Right held down, Left clicked -> History Back
                pendingRightDownEvent = nil
                rockerTriggered = true
                cancelGesture()
                triggerAction(.back)
                return nil
            }
            return event

        case .leftMouseUp:
            isLeftMouseDown = false
            if rockerTriggered {
                rockerTriggered = false
                return nil
            }
            return event

        case .rightMouseDown:
            if Settings.shared.rockerGesturesEnabled && isLeftMouseDown {
                // Rocker Right: Left held down, Right clicked -> History Forward
                rockerTriggered = true
                cancelGesture()
                triggerAction(.forward)
                return nil
            }

            guard isInsideWebArea(event) else { return event }

            pendingRightDownEvent = event
            startPoint = event.locationInWindow
            lastStrokePoint = event.locationInWindow
            recognizedStrokes.removeAll()
            isGestureActive = false
            return nil

        case .rightMouseDragged:
            guard pendingRightDownEvent != nil else { return event }
            let currentPoint = event.locationInWindow
            let dist = hypot(currentPoint.x - startPoint.x, currentPoint.y - startPoint.y)

            if !isGestureActive {
                if dist >= deadzoneThreshold {
                    isGestureActive = true
                    if Settings.shared.gestureTrailsEnabled {
                        showTrailView()
                        trailView?.addPoint(startPoint)
                    }
                }
            }

            if isGestureActive {
                if Settings.shared.gestureTrailsEnabled {
                    trailView?.addPoint(currentPoint)
                }

                let dx = currentPoint.x - lastStrokePoint.x
                let dy = currentPoint.y - lastStrokePoint.y
                if let dir = MouseGestureRecognizer.direction(dx: dx, dy: dy, minThreshold: strokeThreshold) {
                    if recognizedStrokes.last != dir {
                        recognizedStrokes.append(dir)
                        lastStrokePoint = currentPoint

                        let action = MouseGestureAction.match(strokes: recognizedStrokes)
                        trailView?.actionTitle = action?.title
                        trailView?.actionSymbol = action?.symbolName
                        trailView?.strokesText = MouseGestureRecognizer.formatStrokes(recognizedStrokes)
                    }
                }
                return nil
            }
            return nil

        case .rightMouseUp:
            if rockerTriggered {
                rockerTriggered = false
                pendingRightDownEvent = nil
                return nil
            }

            if isGestureActive {
                let strokes = recognizedStrokes
                let matched = MouseGestureAction.match(strokes: strokes)
                if let action = matched {
                    triggerAction(action)
                }

                trailView?.fadeOut(duration: 0.2)
                trailView = nil
                isGestureActive = false
                pendingRightDownEvent = nil
                recognizedStrokes.removeAll()
                return nil
            }

            // Normal right click: user released without dragging
            if let savedDown = pendingRightDownEvent {
                pendingRightDownEvent = nil
                isRedispatching = true
                window?.sendEvent(savedDown)
                window?.sendEvent(event)
                isRedispatching = false
                return nil
            }

            return event

        default:
            return event
        }
    }

    /// Checks if the event's location is within a `WKWebView` hierarchy.
    func isInsideWebArea(_ event: NSEvent) -> Bool {
        if onAction != nil { return true }
        guard let win = self.window, let contentView = win.contentView else { return false }
        if contentView.subviews.isEmpty { return true }
        let point = event.locationInWindow
        guard let hit = contentView.hitTest(point) else { return false }

        var current: NSView? = hit
        while let v = current {
            if v is WKWebView { return true }
            current = v.superview
        }
        return false
    }

    private func showTrailView() {
        guard let contentView = window?.contentView else { return }
        let trail = GestureTrailView(frame: contentView.bounds)
        contentView.addSubview(trail)
        self.trailView = trail
    }

    func cancelGesture() {
        trailView?.removeFromSuperview()
        trailView = nil
        isGestureActive = false
        pendingRightDownEvent = nil
        recognizedStrokes.removeAll()
    }

    private func triggerAction(_ action: MouseGestureAction) {
        if let onAction {
            onAction(action)
            return
        }

        guard let wc = windowController else { return }
        switch action {
        case .back:
            wc.goBack(nil)
        case .forward:
            wc.goForward(nil)
        case .newTab:
            _ = wc.session.newTab()
        case .closeTab:
            wc.closeTab(nil)
        case .reload:
            wc.reloadPage(nil)
        case .reopenClosedTab:
            _ = wc.session.reopenClosedTab()
        case .scrollToTop:
            wc.session.activeTab?.currentWebView?.evaluateJavaScript(
                "window.scrollTo({ top: 0, behavior: 'smooth' });", completionHandler: { _, _ in }
            )
        case .nextTab:
            wc.selectNextTab(nil)
        case .previousTab:
            wc.selectPreviousTab(nil)
        }
    }
}
