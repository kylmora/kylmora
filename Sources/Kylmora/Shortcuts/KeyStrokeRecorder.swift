import AppKit

/// Waits for one key stroke, for recording a shortcut. Escape cancels. A
/// stroke needs a modifier unless the key is a function or arrow key,
/// which arrive with none; anything else is swallowed and ignored.
@MainActor
final class KeyStrokeRecorder {
    struct Stroke: Equatable {
        let key: String
        let modifiers: NSEvent.ModifierFlags
        let keyCode: UInt16
    }

    private var monitor: Any?

    var isRecording: Bool { monitor != nil }

    /// Starts listening. `onStroke` gets each acceptable stroke and returns
    /// whether recording should stop; `onCancel` runs for Escape.
    func start(onStroke: @escaping (Stroke) -> Bool, onCancel: @escaping () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let chars = event.charactersIgnoringModifiers ?? ""
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if keyCode == 53 {
                    self.stop()
                    onCancel()
                    return true
                }
                guard !chars.isEmpty else { return true }
                let stroke = Stroke(key: chars.lowercased(), modifiers: flags, keyCode: keyCode)
                if onStroke(stroke) { self.stop() }
                return true
            }
            return swallow ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Whether a stroke can be a shortcut on its own: it has a modifier, or
    /// it is a function or arrow key.
    static func isBindable(_ stroke: Stroke) -> Bool {
        !stroke.modifiers.isEmpty || stroke.key.unicodeScalars.contains { (0xF700...0xF8FF).contains($0.value) }
    }
}
