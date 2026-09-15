import AppKit

/// A modal question with one text field: rename this, name that, add a
/// note. Returns what was typed, trimmed, or nil when cancelled. An empty
/// answer comes back as an empty string, because for most of these
/// prompts emptying the field is how something is cleared.
@MainActor
enum TextPrompt {
    static func ask(
        title: String,
        message: String,
        initial: String = "",
        placeholder: String? = nil,
        confirm: String = "OK",
        width: CGFloat = 260
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        field.stringValue = initial
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension NSViewController {
    /// Closes this controller however it was shown: as a presented sheet, as
    /// a window sheet, or in a window of its own.
    func endSheetOrDismiss() {
        if presentingViewController != nil {
            presentingViewController?.dismiss(self)
        } else if let window = view.window, let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            view.window?.close()
        }
    }
}
