import AppKit

@MainActor
protocol FindBarViewDelegate: AnyObject {
    func findBar(_ bar: FindBarView, didChangeQuery query: String)
    func findBarDidChangeOptions(_ bar: FindBarView)
    func findBarWantsNextMatch(_ bar: FindBarView)
    func findBarWantsPreviousMatch(_ bar: FindBarView)
    func findBarWantsDismissal(_ bar: FindBarView)
}

/// The find bar: a floating capsule over the top-trailing corner of the page.
///
/// It floats rather than pushing the page down because the page is laid out by
/// `WebContainerView`, and a find bar that resized the web view would reflow
/// the document — moving the very text the user is looking for.
final class FindBarView: NSVisualEffectView, NSSearchFieldDelegate {
    weak var delegate: (any FindBarViewDelegate)?

    private let field = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let matchCaseButton = NSButton(title: "Aa", target: nil, action: nil)
    private let previousButton = FindBarView.iconButton("chevron.up", "Previous Match")
    private let nextButton = FindBarView.iconButton("chevron.down", "Next Match")
    private let doneButton = FindBarView.iconButton("xmark", "Done")

    var query: String { field.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        maskImage = nil
        setAccessibilityLabel("Find on Page")

        buildLayout()
        applyBorderColor()
    }

    required init?(coder: NSCoder) {
        fatalError("FindBarView is created in code only")
    }

    private func buildLayout() {
        field.placeholderString = "Find on Page"
        field.font = .systemFont(ofSize: 12)
        // Whole-string search would only fire on Return; find-as-you-type is
        // the point, and `controlTextDidChange` gives us every keystroke.
        field.sendsWholeSearchString = false
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        matchCaseButton.setButtonType(.pushOnPushOff)
        matchCaseButton.bezelStyle = .accessoryBarAction
        matchCaseButton.font = .systemFont(ofSize: 11, weight: .semibold)
        matchCaseButton.toolTip = "Match Case"
        matchCaseButton.setAccessibilityLabel("Match Case")
        matchCaseButton.target = self
        matchCaseButton.action = #selector(toggleMatchCase)
        matchCaseButton.setContentHuggingPriority(.required, for: .horizontal)

        previousButton.target = self
        previousButton.action = #selector(findPrevious)
        nextButton.target = self
        nextButton.action = #selector(findNext)
        doneButton.target = self
        doneButton.action = #selector(dismiss)

        let stack = NSStackView(views: [
            field, statusLabel, matchCaseButton, previousButton, nextButton, doneButton
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(equalToConstant: 200)
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBorderColor()
    }

    private func applyBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    /// Mirrors the state the controller holds. Nothing here decides anything.
    func update(with state: FindState) {
        if field.stringValue != state.query { field.stringValue = state.query }
        matchCaseButton.state = state.matchesCase ? .on : .off
        statusLabel.stringValue = state.statusMessage ?? ""
        statusLabel.isHidden = state.statusMessage == nil
        // WebKit reports no match count, so the arrows cannot know whether
        // there is somewhere to go. They are live whenever there is a term.
        previousButton.isEnabled = state.canRepeat
        nextButton.isEnabled = state.canRepeat
        field.textColor = state.isFailing ? .systemRed : .labelColor
    }

    /// Takes focus and selects what is already there, so typing replaces the
    /// previous term the way Cmd-F does everywhere else.
    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    // MARK: - Actions

    @objc private func toggleMatchCase() {
        delegate?.findBarDidChangeOptions(self)
    }

    @objc private func findNext() {
        delegate?.findBarWantsNextMatch(self)
    }

    @objc private func findPrevious() {
        delegate?.findBarWantsPreviousMatch(self)
    }

    @objc private func dismiss() {
        delegate?.findBarWantsDismissal(self)
    }

    var matchesCaseIsOn: Bool { matchCaseButton.state == .on }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        delegate?.findBar(self, didChangeQuery: field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Shift-Return walks backwards. AppKit sends `insertNewline:` for
            // both, so the modifier has to come from the event itself.
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            if shift { delegate?.findBarWantsPreviousMatch(self) } else { delegate?.findBarWantsNextMatch(self) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Beats NSSearchField's own Escape handling, which would only empty
            // the field and leave the bar sitting there.
            delegate?.findBarWantsDismissal(self)
            return true
        default:
            return false
        }
    }

    private static func iconButton(_ symbolName: String, _ label: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        let button = NSButton(image: image ?? NSImage(), target: nil, action: nil)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }
}
