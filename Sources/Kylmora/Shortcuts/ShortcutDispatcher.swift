import AppKit

/// Fires the shortcuts menus cannot: chords, and keys bound to custom
/// commands.
///
/// A chord is a leader stroke (⌘K) followed, within a moment, by a plain
/// key (T). The leader is swallowed and remembered; the next stroke either
/// completes a chord or falls through. Pure enough to test: `decide` takes
/// a key and its modifiers and answers with what to do.
@MainActor
final class ShortcutDispatcher {
    static let shared = ShortcutDispatcher()

    enum Decision: Equatable {
        case pass
        case armed
        case perform(id: String)
    }

    /// How long a leader waits for its second stroke.
    static let chordWindow: TimeInterval = 1.5

    private var pendingLeader: (key: String, modifiers: NSEvent.ModifierFlags, at: Date)?
    private var monitor: Any?
    var bindings: () -> [ShortcutManager.Binding] = { ShortcutManager.shared.dispatcherBindings }
    var runCommand: (String) -> Bool = { id in
        MainActor.assumeIsolated { AutomationService.shared.runCommand(id: id, tab: nil) }
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self, let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return false }
                // Typing in a text field is typing, not a chord's second stroke.
                if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                   event.window?.firstResponder is NSTextView, self.pendingLeader == nil {
                    return false
                }
                return self.handle(key: chars.lowercased(), modifiers: event.modifierFlags)
            }
            return swallow ? nil : event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pendingLeader = nil
    }

    /// Acts on a stroke. Returns whether it was consumed.
    @discardableResult
    func handle(key: String, modifiers: NSEvent.ModifierFlags, now: Date = .now) -> Bool {
        switch decide(key: key, modifiers: modifiers, now: now) {
        case .pass:
            return false
        case .armed:
            return true
        case .perform(let id):
            perform(id)
            return true
        }
    }

    func decide(key: String, modifiers: NSEvent.ModifierFlags, now: Date = .now) -> Decision {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        let all = bindings()

        if let leader = pendingLeader {
            pendingLeader = nil
            if now.timeIntervalSince(leader.at) <= Self.chordWindow {
                let completed = all.first { binding in
                    binding.secondKey == key && binding.key == leader.key && binding.modifiers == leader.modifiers
                        && (flags.isEmpty || flags == leader.modifiers)
                }
                if let completed { return .perform(id: completed.id) }
            }
        }

        if all.contains(where: { $0.secondKey != nil && $0.key == key && $0.modifiers == flags }) {
            pendingLeader = (key, flags, now)
            return .armed
        }
        if let direct = all.first(where: { $0.secondKey == nil && $0.key == key && $0.modifiers == flags }) {
            return .perform(id: direct.id)
        }
        return .pass
    }

    private func perform(_ id: String) {
        if runCommand(id) { return }
        guard let selector = bindings().first(where: { $0.id == id })?.selector else { return }
        NSApplication.shared.sendAction(selector, to: nil, from: nil)
    }
}
