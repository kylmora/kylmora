import AppKit

/// The row a live folder shows instead of tabs when it has none.
///
/// It exists because "empty" and "broken" are different things and a folder
/// that renders both as blank space is lying about one of them. Refreshing gets
/// its own treatment too: the first fetch of a newly made folder takes a couple
/// of seconds, and nothing at all on screen during those seconds reads as a
/// feature that did not work.
@MainActor
final class LiveFolderStatusView: NSView {
    /// Tapped when the status offers something to do about itself.
    var onAction: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private var leadingInset: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        label.font = Style.Fonts.body
        label.textColor = Style.Colors.secondaryText
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        actionButton.bezelStyle = .inline
        actionButton.controlSize = .small
        actionButton.font = .systemFont(ofSize: 11)
        actionButton.target = self
        actionButton.action = #selector(actionTapped)
        actionButton.isHidden = true

        let stack = NSStackView(views: [spinner, label, actionButton])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let leading = stack.leadingAnchor.constraint(equalTo: leadingAnchor)
        leadingInset = leading

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Style.Metrics.rowHeight),
            leading,
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LiveFolderStatusView is created in code only")
    }

    /// - Parameter indent: the folder's own indent plus one level, so the row
    ///   sits where the folder's first tab would.
    func show(_ status: LiveFolderStatus, indent: CGFloat) {
        leadingInset?.constant = indent + Style.Metrics.sidebarInset
        spinner.stopAnimation(nil)
        actionButton.isHidden = true

        switch status {
        case .ready:
            isHidden = true
            return
        case .refreshing:
            isHidden = false
            label.stringValue = "Refreshing…"
            spinner.startAnimation(nil)
        case .empty:
            isHidden = false
            label.stringValue = "Nothing right now"
        case .failed(let issue):
            isHidden = false
            label.stringValue = issue.message
            actionButton.isHidden = false
            actionButton.title = issue.recoveryURL == nil ? "Retry" : "Open"
        }
        setAccessibilityLabel(label.stringValue)
    }

    @objc private func actionTapped() {
        onAction?()
    }
}
