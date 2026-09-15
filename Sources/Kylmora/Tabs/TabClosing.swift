import AppKit

/// The one question asked before a tab closes: is a video from it playing
/// in picture in picture? Closing would take the video away, and the user
/// may not have the tab in view at all.
@MainActor
enum TabClosing {
    /// True to go ahead.
    static func confirm(closing tab: Tab, settings: Settings = .shared) -> Bool {
        guard settings.confirmsClosingPictureInPicture, tab.isInPictureInPicture else { return true }
        let alert = NSAlert()
        alert.messageText = "Close \u{201c}\(tab.displayTitle)\u{201d}?"
        alert.informativeText = "A video from this tab is playing in Picture in Picture. Closing the tab stops it."
        alert.addButton(withTitle: "Close Tab")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

extension Toast {
    /// Raised when a close the user aimed at one particular tab hit a lock.
    ///
    /// The button closes the tab as well as unlocking it, because that is what
    /// the user was trying to do a second ago; an Unlock that left the tab
    /// sitting there would need a second Cmd-W to finish the thought.
    static func closeRefused(tab: String, unlock: @escaping () -> Void) -> Toast {
        Toast(
            symbolName: "lock.fill",
            message: "\u{201c}\(tab)\u{201d} is locked",
            action: Action(title: "Unlock and Close", handler: unlock),
            duration: 6,
            identity: "tab-locked"
        )
    }
}
