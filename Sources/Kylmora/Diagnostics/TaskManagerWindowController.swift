import AppKit

/// Window controller hosting the Task Manager view.
@MainActor
final class TaskManagerWindowController: NSWindowController {
    static var current: TaskManagerWindowController?

    static func show(session: BrowserSession) {
        if let existing = current, let window = existing.window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            (existing.contentViewController as? TaskManagerViewController)?.refreshMetrics()
            return
        }

        let controller = TaskManagerWindowController(session: session)
        current = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init(session: BrowserSession) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Task Manager"
        window.minSize = NSSize(width: 560, height: 340)
        window.setFrameAutosaveName("KylmoraTaskManagerWindow")
        window.center()

        let viewController = TaskManagerViewController(session: session)
        window.contentViewController = viewController

        super.init(window: window)
    }

    public required init?(coder: NSCoder) {
        fatalError("TaskManagerWindowController is created in code only")
    }
}
