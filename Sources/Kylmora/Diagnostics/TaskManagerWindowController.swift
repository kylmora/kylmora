import AppKit

/// The window the Task Manager lives in.
///
/// No titlebar of its own, and no toolbar: the window is a canvas washed in the
/// colour of the space you are looking at, and a title bar drawn across the top
/// of it would put a grey system band over the one thing that makes the window
/// Kylmora's. The name of what you are looking at is on the page, where the
/// Settings window puts it too, and the traffic lights float over the rail.
@MainActor
final class TaskManagerWindowController: NSWindowController {
    static var current: TaskManagerWindowController?

    /// Big enough for three cards across the top with a chart under them.
    static let openingSize = NSSize(width: 1000, height: 720)
    /// Below this the three cards stop being readable and the table loses its
    /// columns, so the window refuses to go there.
    static let floorSize = NSSize(width: 840, height: 560)

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
            contentRect: NSRect(origin: .zero, size: Self.openingSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Kept for the Window menu and for VoiceOver, hidden from the window
        // itself: the scope's name is already on the page.
        window.title = "Task Manager"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = Self.floorSize

        super.init(window: window)

        window.contentViewController = TaskManagerViewController(session: session)
        window.setContentSize(Self.openingSize)
        window.setFrameAutosaveName("KylmoraTaskManagerWindow")
        // The autosave name restores whatever frame this window was last left
        // at, which may be one an earlier build saved at its own smaller size.
        // Anything under the floor is thrown away rather than restored.
        if window.frame.width < Self.floorSize.width || window.frame.height < Self.floorSize.height {
            window.setContentSize(Self.openingSize)
            window.center()
        }
    }

    public required init?(coder: NSCoder) {
        fatalError("TaskManagerWindowController is created in code only")
    }
}
