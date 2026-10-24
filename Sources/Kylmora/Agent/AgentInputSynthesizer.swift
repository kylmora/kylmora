import AppKit
import WebKit

/// Drives a web view with real input, at a person's pace.
///
/// ego lite sends input through the browser's own input pipeline (CDP
/// `Input.dispatchMouseEvent`), so pages see trusted events. The WebKit
/// equivalent is to hand synthesized `NSEvent`s straight to the `WKWebView`'s
/// responder methods: WebKit turns them into `isTrusted` pointer, mouse, key,
/// `beforeinput`/`input` and wheel events, with native default actions (focus,
/// text insertion, form submission on Return, link activation). This works in a
/// window that is not key, so the agent never has to steal focus.
///
/// Coordinates in this API are CSS pixels in the page's viewport, as snapshots
/// report them.
@MainActor
public final class AgentInputSynthesizer {
    public static let shared = AgentInputSynthesizer()

    /// The cursor's last position, in CSS pixels, per web view.
    private var cursor: [ObjectIdentifier: CGPoint] = [:]
    private var eventNumber = 0
    private var overlays: [ObjectIdentifier: AgentCursorOverlayView] = [:]

    private func random(in range: ClosedRange<Double>) -> Double { Double.random(in: range) }
    private func pause(_ range: ClosedRange<Double>) async throws {
        try await Task.sleep(nanoseconds: UInt64(random(in: range) * 1_000_000_000))
    }

    func overlay(for webView: WKWebView) -> AgentCursorOverlayView {
        let key = ObjectIdentifier(webView)
        if let existing = overlays[key] { return existing }
        let view = AgentCursorOverlayView()
        overlays[key] = view
        return view
    }

    func cursorPosition(in webView: WKWebView) -> CGPoint? { cursor[ObjectIdentifier(webView)] }

    /// Fades every agent cursor out, for the end of a task.
    func dismissCursors() {
        overlays.values.forEach { $0.dismiss() }
    }

    // MARK: - Paths

    /// Waypoints along a hand's arc between two points: a cubic Bézier bowed off
    /// the straight line, landing slightly off-centre.
    public func generateCurvedPath(from: CGPoint, to: CGPoint) -> [CGPoint] {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let dist = hypot(dx, dy)
        if dist < 10 { return [to] }

        let bow = min(dist * 0.18, 60.0)
        let arcOffset = (Bool.random() ? 1.0 : -1.0) * Double.random(in: 0.4...1.0) * bow
        let cp1 = CGPoint(x: from.x + dx * 0.35 - CGFloat(arcOffset * 0.8), y: from.y + dy * 0.35 + CGFloat(arcOffset * 0.5))
        let cp2 = CGPoint(x: from.x + dx * 0.72 + CGFloat(arcOffset * 0.5), y: from.y + dy * 0.72 - CGFloat(arcOffset * 0.8))

        let stepCount = max(6, min(24, Int(dist / 25.0)))
        var points: [CGPoint] = []
        points.reserveCapacity(stepCount)
        for i in 1...stepCount {
            let t = CGFloat(i) / CGFloat(stepCount)
            let u = 1 - t
            let x = u * u * u * from.x + 3 * u * u * t * cp1.x + 3 * u * t * t * cp2.x + t * t * t * to.x
            let y = u * u * u * from.y + 3 * u * u * t * cp1.y + 3 * u * t * t * cp2.y + t * t * t * to.y
            points.append(CGPoint(x: round(x), y: round(y)))
        }
        points[points.count - 1] = CGPoint(
            x: to.x + CGFloat(Double.random(in: -1.5...1.5)),
            y: to.y + CGFloat(Double.random(in: -1.5...1.5))
        )
        return points
    }

    // MARK: - Geometry

    /// CSS pixels to the web view's points: page zoom and magnification scale them.
    private func scale(of webView: WKWebView) async -> CGFloat {
        let viewport = try? await AgentSnapshotScript.call("return agent.viewport();", in: webView) as? [String: Any]
        guard let cssWidth = viewport?["width"] as? Double, cssWidth > 0 else { return 1 }
        return webView.bounds.width / CGFloat(cssWidth)
    }

    /// A CSS point in the web view's (flipped) coordinates.
    private func viewPoint(_ css: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: css.x * scale, y: css.y * scale)
    }

    private func windowPoint(_ view: CGPoint, in webView: WKWebView) -> NSPoint {
        let local = webView.isFlipped ? view : NSPoint(x: view.x, y: webView.bounds.height - view.y)
        return webView.convert(local, to: nil)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at css: CGPoint, scale: CGFloat, in webView: WKWebView, clickCount: Int = 0, modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        eventNumber += 1
        return NSEvent.mouseEvent(
            with: type,
            location: windowPoint(viewPoint(css, scale: scale), in: webView),
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: webView.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: eventNumber,
            clickCount: clickCount,
            pressure: type == .leftMouseDown ? 1 : 0
        )
    }

    /// Hover. WebKit drops plain `mouseMoved` events while its window is not
    /// key, but takes a button-less drag as a move: the page sees trusted
    /// `pointermove`/`mousemove` with `buttons == 0` and updates `:hover`.
    private func dispatchHover(at css: CGPoint, scale: CGFloat, in webView: WKWebView) {
        if webView.window?.isKeyWindow == true {
            if let event = mouseEvent(.mouseMoved, at: css, scale: scale, in: webView) { webView.mouseMoved(with: event) }
        } else if let event = mouseEvent(.leftMouseDragged, at: css, scale: scale, in: webView) {
            webView.mouseDragged(with: event)
        }
    }

    // MARK: - Pointer

    /// Travels to `target` along a curve, with the native cursor in step with the
    /// hover events the page receives, then dwells before whatever comes next.
    public func humanMove(to target: CGPoint, in webView: WKWebView, label: String? = nil) async throws {
        let key = ObjectIdentifier(webView)
        let scale = await scale(of: webView)
        let overlay = overlay(for: webView)
        overlay.attach(to: webView)

        let viewTarget = viewPoint(target, scale: scale)
        let viewStart = overlay.entryPoint(toward: viewTarget)
        let start = cursor[key] ?? CGPoint(x: viewStart.x / scale, y: viewStart.y / scale)
        let path = generateCurvedPath(from: start, to: target)
        let duration = AgentCursorOverlayView.travelDuration(from: viewStart, to: viewTarget)
        overlay.travel(along: path.map { viewPoint($0, scale: scale) }, duration: duration, label: label)

        let stepDelay = duration / Double(path.count)
        for point in path {
            dispatchHover(at: point, scale: scale, in: webView)
            try await Task.sleep(nanoseconds: UInt64(stepDelay * 1_000_000_000))
        }
        cursor[key] = path.last ?? target
        try await pause(0.12...0.35)
    }

    /// A click where a person would click: travel, dwell, press, hold, release.
    public func humanClick(at target: CGPoint, in webView: WKWebView, label: String? = nil, clickCount: Int = 1) async throws -> [String: Any] {
        try await humanMove(to: target, in: webView, label: label)
        let scale = await scale(of: webView)
        let point = cursor[ObjectIdentifier(webView)] ?? target
        overlay(for: webView).pulseClick()
        for count in 1...max(1, clickCount) {
            if let down = mouseEvent(.leftMouseDown, at: point, scale: scale, in: webView, clickCount: count) {
                webView.mouseDown(with: down)
            }
            try await pause(0.045...0.11)
            if let up = mouseEvent(.leftMouseUp, at: point, scale: scale, in: webView, clickCount: count) {
                webView.mouseUp(with: up)
            }
            if count < clickCount { try await pause(0.06...0.12) }
        }
        try await pause(0.25...0.7)
        return ["success": true, "x": point.x, "y": point.y]
    }

    // MARK: - Wheel

    /// Scrolls with wheel input at the cursor, in uneven notches with pauses, so
    /// the page scrolls the way it does under a hand and inner scrollers under
    /// the pointer get the wheel, not the document.
    public func humanScroll(deltaX: Double, deltaY: Double, in webView: WKWebView, at point: CGPoint? = nil) async throws -> [String: Any] {
        let scale = await scale(of: webView)
        let key = ObjectIdentifier(webView)
        let viewportCSS = CGSize(width: webView.bounds.width / scale, height: webView.bounds.height / scale)
        var anchor = point ?? cursor[key] ?? CGPoint(x: viewportCSS.width / 2, y: viewportCSS.height / 2)
        if !CGRect(origin: .zero, size: viewportCSS).insetBy(dx: 4, dy: 4).contains(anchor) {
            anchor = CGPoint(x: viewportCSS.width / 2, y: viewportCSS.height / 2)
        }
        if cursor[key] == nil || point != nil {
            try await humanMove(to: anchor, in: webView, label: "Scrolling")
            anchor = cursor[key] ?? anchor
        } else {
            overlay(for: webView).setLabel("Scrolling")
        }

        var remainingX = deltaX
        var remainingY = deltaY
        while abs(remainingX) >= 1 || abs(remainingY) >= 1 {
            let notch = random(in: 90...160)
            let stepY = abs(remainingY) <= notch ? remainingY : notch * (remainingY > 0 ? 1 : -1)
            let stepX = abs(remainingX) <= notch ? remainingX : notch * (remainingX > 0 ? 1 : -1)
            try await dispatchWheel(dx: stepX, dy: stepY, at: anchor, scale: scale, in: webView)
            remainingX -= stepX
            remainingY -= stepY
            try await pause(0.07...0.2)
        }
        try await pause(0.3...0.8)
        return ["success": true, "scrolledX": deltaX, "scrolledY": deltaY]
    }

    /// One notch, smoothed into a few events like a trackpad flick (ego lite
    /// eases its wheel motion with smoothstep the same way).
    private func dispatchWheel(dx: Double, dy: Double, at css: CGPoint, scale: CGFloat, in webView: WKWebView) async throws {
        let steps = max(1, min(6, Int(max(abs(dx), abs(dy)) / 30)))
        var emittedX = 0.0
        var emittedY = 0.0
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let eased = t * t * (3 - 2 * t)
            let x = (dx * eased).rounded() - emittedX
            let y = (dy * eased).rounded() - emittedY
            emittedX += x
            emittedY += y
            guard let event = wheelEvent(dx: x * scale, dy: y * scale, at: css, scale: scale, in: webView) else { continue }
            webView.scrollWheel(with: event)
            if step < steps { try await Task.sleep(nanoseconds: 12_000_000) }
        }
    }

    /// A pixel-precise wheel event aimed at a point in the web view.
    ///
    /// `NSEvent(cgEvent:)` leaves the event without a window, and then reports
    /// the screen location as `locationInWindow`; WebKit converts that from
    /// window coordinates. So the location is set to the window point itself.
    private func wheelEvent(dx: Double, dy: Double, at css: CGPoint, scale: CGFloat, in webView: WKWebView) -> NSEvent? {
        guard let cg = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
            wheel1: Int32(-dy.rounded()), wheel2: Int32(-dx.rounded()), wheel3: 0
        ) else { return nil }
        let target = windowPoint(viewPoint(css, scale: scale), in: webView)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: target.x, y: primaryHeight - target.y)
        return NSEvent(cgEvent: cg)
    }

    // MARK: - Keyboard

    /// Types `text` one key at a time, unevenly, pausing at some word breaks the
    /// way a person thinks between words.
    public func humanType(text: String, in webView: WKWebView) async throws -> [String: Any] {
        webView.window?.makeFirstResponder(webView)
        overlay(for: webView).setLabel("Typing")
        for character in text {
            if character == "\n" {
                sendKey(AgentKey.named["Enter"]!, modifiers: [], in: webView)
            } else {
                let key = AgentKey.forCharacter(character)
                sendKey(key, modifiers: key.needsShift ? [.shift] : [], in: webView)
            }
            try await pause(0.07...0.19)
            if character == " ", random(in: 0...1) < 0.22 { try await pause(0.25...0.8) }
            if random(in: 0...1) < 0.05 { try await pause(0.4...1.2) }
        }
        return ["success": true, "charactersTyped": text.count]
    }

    /// Presses a key or chord, Playwright-style: "Enter", "Tab", "Shift+Tab",
    /// "Meta+a", "ControlOrMeta+Enter", "ArrowDown".
    public func humanPress(key chord: String, in webView: WKWebView) async throws -> [String: Any] {
        webView.window?.makeFirstResponder(webView)
        overlay(for: webView).setLabel("Pressing \(chord)")
        let parts = chord.split(separator: "+").map(String.init)
        guard let keyName = parts.last, !keyName.isEmpty else {
            throw AgentError.invalidTarget("Empty key")
        }
        var modifiers: NSEvent.ModifierFlags = []
        for modifier in parts.dropLast() {
            switch modifier.lowercased() {
            case "shift": modifiers.insert(.shift)
            case "control", "ctrl": modifiers.insert(.control)
            case "alt", "option": modifiers.insert(.option)
            case "meta", "command", "cmd", "controlormeta": modifiers.insert(.command)
            default: throw AgentError.invalidTarget("Unknown modifier '\(modifier)'")
            }
        }
        let key: AgentKey
        if let named = AgentKey.named[keyName] ?? AgentKey.named[keyName.capitalized] {
            key = named
        } else if keyName.count == 1, let character = keyName.first {
            key = AgentKey.forCharacter(character)
            if key.needsShift { modifiers.insert(.shift) }
        } else {
            throw AgentError.invalidTarget("Unknown key '\(keyName)'")
        }
        sendKey(key, modifiers: modifiers, in: webView)
        try await pause(0.15...0.35)
        return ["success": true, "key": chord]
    }

    /// Empties the focused field the way a person does: select all, delete.
    func clearFocusedField(in webView: WKWebView) async throws {
        webView.window?.makeFirstResponder(webView)
        webView.selectAll(nil)
        try await pause(0.08...0.18)
        sendKey(AgentKey.named["Backspace"]!, modifiers: [], in: webView)
        try await pause(0.1...0.25)
    }

    private func sendKey(_ key: AgentKey, modifiers: NSEvent.ModifierFlags, in webView: WKWebView) {
        let characters = modifiers.contains(.shift) ? key.shifted : key.characters
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: webView.window?.windowNumber ?? 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: key.characters,
                isARepeat: false,
                keyCode: key.code
            )
        }
        guard let down = event(.keyDown), let up = event(.keyUp) else { return }
        // Command chords are key equivalents in AppKit; WebKit handles the
        // editing ones (copy, paste, select all) there.
        if modifiers.contains(.command), webView.performKeyEquivalent(with: down) {
            return
        }
        webView.keyDown(with: down)
        webView.keyUp(with: up)
    }
}

/// A key on a US keyboard: its virtual key code and what it types.
struct AgentKey {
    let code: UInt16
    let characters: String
    let shifted: String
    var needsShift = false

    static let named: [String: AgentKey] = {
        func function(_ code: UInt16, _ scalar: Int) -> AgentKey {
            let string = String(UnicodeScalar(UInt32(scalar)).map(Character.init) ?? " ")
            return AgentKey(code: code, characters: string, shifted: string)
        }
        return [
            "Enter": AgentKey(code: 36, characters: "\r", shifted: "\r"),
            "Return": AgentKey(code: 36, characters: "\r", shifted: "\r"),
            "Tab": AgentKey(code: 48, characters: "\t", shifted: "\u{19}"),
            "Escape": AgentKey(code: 53, characters: "\u{1b}", shifted: "\u{1b}"),
            "Backspace": AgentKey(code: 51, characters: "\u{7f}", shifted: "\u{7f}"),
            "Space": AgentKey(code: 49, characters: " ", shifted: " "),
            "Delete": function(117, NSDeleteFunctionKey),
            "ArrowUp": function(126, NSUpArrowFunctionKey),
            "ArrowDown": function(125, NSDownArrowFunctionKey),
            "ArrowLeft": function(123, NSLeftArrowFunctionKey),
            "ArrowRight": function(124, NSRightArrowFunctionKey),
            "Home": function(115, NSHomeFunctionKey),
            "End": function(119, NSEndFunctionKey),
            "PageUp": function(116, NSPageUpFunctionKey),
            "PageDown": function(121, NSPageDownFunctionKey),
        ]
    }()

    /// US-layout key codes; anything else is sent with code 0 and its text,
    /// which WebKit inserts as typed.
    private static let codes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "`": 50, " ": 49,
    ]
    private static let shiftedPairs: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
        "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";",
        "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    static func forCharacter(_ character: Character) -> AgentKey {
        let text = String(character)
        if character.isUppercase, let base = character.lowercased().first, let code = codes[base] {
            return AgentKey(code: code, characters: String(base), shifted: text, needsShift: true)
        }
        if let base = shiftedPairs[character], let code = codes[base] {
            return AgentKey(code: code, characters: String(base), shifted: text, needsShift: true)
        }
        return AgentKey(code: codes[character] ?? 0, characters: text, shifted: text)
    }
}
