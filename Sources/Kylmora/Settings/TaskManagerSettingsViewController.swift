import AppKit

/// The Task Manager pane: the switch that puts its button in the sidebar, and
/// under it the whole Task Manager, live.
///
/// The pane exists because of the switch. A control that hides a way in has to
/// leave another one behind, and it has to be somewhere the person who just
/// hid it will think to look -- so the setting lives in the same place as the
/// thing it hides, and turning the button off leaves you looking at the very
/// window you were worried about losing.
///
/// Wide, not held to a reading width: the charts and the table have columns to
/// show, and a form column would clip them.
@MainActor
final class TaskManagerSettingsViewController: NSViewController, SettingsWidePane {
    private let session: BrowserSession
    private let settings: Settings
    private let sidebarSwitch = NSButton(
        checkboxWithTitle: "Put a gauge in the sidebar's footer, beside Downloads",
        target: nil,
        action: nil
    )
    /// The same controller the window uses, in its embedded dress: no rail of
    /// its own, no scroller of its own, and a pop-up where the rail was.
    private let activity: TaskManagerViewController

    init(session: BrowserSession, settings: Settings = .shared) {
        self.session = session
        self.settings = settings
        activity = TaskManagerViewController(session: session, presentation: .embedded)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("TaskManagerSettingsViewController is created in code only")
    }

    override func loadView() {
        let form = SettingsForm()
        view = form

        sidebarSwitch.target = self
        sidebarSwitch.action = #selector(sidebarSwitchChanged)
        form.addSection("Sidebar")
        form.addRow("Show in the sidebar", sidebarSwitch)
        form.addNote(
            "With it off, the Task Manager is still on the Window menu, on ⇧⌘U, and here."
        )

        form.addSection("Right now")
        addChild(activity)
        let row = form.addHero(activity.view)
        activity.view.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true

        reload()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    /// Read rather than remembered: the switch is one of two places this
    /// setting can be changed from, and a pane that trusted its own last write
    /// would show the wrong state after the other one.
    private func reload() {
        sidebarSwitch.state = settings.showsTaskManagerInSidebar ? .on : .off
    }

    @objc private func sidebarSwitchChanged() {
        settings.showsTaskManagerInSidebar = sidebarSwitch.state == .on
    }
}
