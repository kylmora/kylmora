import AppKit

/// The editable address bar in the top bar.
///
/// Shows the current page's address and lets the user click straight in to
/// edit it: Return navigates (a URL or a search, resolved by `URLResolver`),
/// Escape reverts to the page's own address. A copy button at the trailing
/// edge puts the full URL on the clipboard in one click.
///
/// It draws no background of its own -- it sits on the top bar as plain text,
/// the same colour as everything around it -- and always holds the full URL,
/// so what you edit or copy is the whole address.
@MainActor
final class AddressField: NSView, NSTextFieldDelegate {
    /// The text the user committed with Return. The controller resolves it to
    /// a destination and loads it.
    var onNavigate: ((String) -> Void)?

    private let field = SelectAllTextField()
    private let securityIcon = NSImageView()
    private let copyButton = IconButton(symbolName: "doc.on.doc", label: "Copy Address")
    /// The page's address as shown while idle; what Escape and an abandoned
    /// edit revert to.
    private var currentDisplay = ""
    /// The full URL, for the tooltip and the copy button.
    private var currentURL: URL?
    private var isEditing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        field.translatesAutoresizingMaskIntoConstraints = false
        field.delegate = self
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Style.Fonts.body
        field.textColor = Style.Colors.primaryText
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderString = "Search or enter address"
        field.setAccessibilityLabel("Address")

        securityIcon.translatesAutoresizingMaskIntoConstraints = false
        securityIcon.imageScaling = .scaleProportionallyDown
        securityIcon.setContentHuggingPriority(.required, for: .horizontal)
        securityIcon.setAccessibilityRole(.image)

        addSubview(securityIcon)
        addSubview(field)

        copyButton.setClickHandler { [weak self] in self?.copyAddress() }
        addSubview(copyButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Style.Metrics.iconButtonSide),
            securityIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            securityIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            securityIcon.widthAnchor.constraint(equalToConstant: 15),
            securityIcon.heightAnchor.constraint(equalToConstant: 15),
            field.leadingAnchor.constraint(equalTo: securityIcon.trailingAnchor, constant: 6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -4),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            copyButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("AddressField is created in code only") }

    /// Loads a page's address into the bar. Ignored while the user is editing,
    /// so a page finishing in the background does not yank the text out from
    /// under them. The copy button hides when there is nothing to copy.
    func show(display: String?, url: URL?) {
        currentDisplay = display ?? ""
        currentURL = url
        field.toolTip = url?.absoluteString
        copyButton.isHidden = (url == nil)
        showSecurity(of: url)
        if !isEditing {
            field.stringValue = currentDisplay
        }
    }

    /// A lock for HTTPS, a warning for plain HTTP, nothing for the schemes where
    /// "secure or not" is not the question (a new tab, a local file).
    private func showSecurity(of url: URL?) {
        let symbol: (name: String, tint: NSColor, help: String)?
        switch url?.scheme?.lowercased() {
        case "https":
            symbol = ("lock.fill", Style.Colors.secondaryText, "Connection is secure (HTTPS)")
        case "http":
            symbol = ("exclamationmark.triangle.fill", .systemOrange, "Connection is not secure (HTTP)")
        default:
            symbol = nil
        }
        guard let symbol else {
            securityIcon.isHidden = true
            return
        }
        securityIcon.isHidden = false
        let image = NSImage(systemSymbolName: symbol.name, accessibilityDescription: symbol.help)
        securityIcon.image = image
        securityIcon.contentTintColor = symbol.tint
        securityIcon.toolTip = symbol.help
        securityIcon.setAccessibilityLabel(symbol.help)
    }

    private func copyAddress() {
        guard let url = currentURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        // A one-second checkmark, so a silent copy still says it happened.
        copyButton.setSymbol("checkmark", label: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.copyButton.setSymbol("doc.on.doc", label: "Copy Address")
        }
    }

    // MARK: - Editing

    func controlTextDidBeginEditing(_ obj: Notification) {
        isEditing = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        isEditing = false
        // An edit left unsubmitted -- a click elsewhere -- is discarded: the
        // bar shows where the page actually is, never a half-typed address.
        field.stringValue = currentDisplay
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { onNavigate?(text) }
            window?.makeFirstResponder(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            field.stringValue = currentDisplay
            window?.makeFirstResponder(nil)
            return true
        default:
            return false
        }
    }

    /// An `NSTextField` that selects its whole contents when it gains focus, so
    /// the first keystroke replaces the address rather than inserting into it.
    private final class SelectAllTextField: NSTextField {
        override func becomeFirstResponder() -> Bool {
            let began = super.becomeFirstResponder()
            if began {
                DispatchQueue.main.async { [weak self] in self?.currentEditor()?.selectAll(nil) }
            }
            return began
        }
    }
}
