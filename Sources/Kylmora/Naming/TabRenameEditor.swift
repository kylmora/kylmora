import AppKit

/// The inline field that replaces a tab's title while it is being renamed.
///
/// Return commits, Escape cancels, and losing focus cancels too. That last one
/// is the rule worth stating: a field that commits on blur turns a click
/// somewhere else in the window into an edit the user did not ask for, and a
/// rename has no undo.
@MainActor
final class TabRenameEditor: NSTextField, NSTextFieldDelegate {
    private let onCommit: (String) -> Void
    private let onCancel: () -> Void
    /// Both endings run exactly once: Escape ends editing, which also fires the
    /// blur path, and a cancel after a commit would undo the rename.
    private var hasFinished = false

    /// `currentName` is the name the tab already has, if any, so re-opening the
    /// editor shows what is there to be edited rather than an empty box the
    /// user has to guess the meaning of.
    init(currentName: String?, placeholder: String, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.onCommit = onCommit
        self.onCancel = onCancel
        super.init(frame: .zero)

        stringValue = currentName ?? ""
        placeholderString = placeholder
        font = Style.Fonts.body
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        lineBreakMode = .byTruncatingTail
        usesSingleLineMode = true
        cell?.sendsActionOnEndEditing = false
        delegate = self
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel("Tab name")
    }

    required init?(coder: NSCoder) {
        fatalError("TabRenameEditor is created in code only")
    }

    /// Selecting the whole name means the common case -- replacing it -- is one
    /// keystroke, while editing it is one arrow key away.
    func beginEditing() {
        window?.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finish { self.onCommit(self.stringValue) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finish { self.onCancel() }
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        finish { self.onCancel() }
    }

    private func finish(_ ending: () -> Void) {
        guard !hasFinished else { return }
        hasFinished = true
        ending()
    }
}
