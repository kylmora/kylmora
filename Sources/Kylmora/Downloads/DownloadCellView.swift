import AppKit
import UniformTypeIdentifiers

/// One row in the downloads list: file icon, name, a progress bar while the
/// transfer runs, and the one action that row currently affords.
///
/// Styled as a row of this app rather than as a table row: the same pill on
/// hover and selection the sidebar's rows draw, the same type, and the same
/// hover button for the action.
@MainActor
final class DownloadCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("DownloadCell")
    static let rowHeight: CGFloat = 54

    /// Fired by the trailing button, whose meaning changes with the state.
    var onAction: (() -> Void)?

    /// Drawn by the row itself, because the pill is rounded and inset and the
    /// table's own highlight cannot be. The table runs with
    /// `selectionHighlightStyle = .none` and tells rows when they are selected.
    var isSelected = false {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }

    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var trackingArea: NSTrackingArea?

    private let icon: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let nameLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = Style.Fonts.body
        label.textColor = Style.Colors.primaryText
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private let statusLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        // The sidebar's badge font: this line is the same kind of thing as an
        // idle badge, a small grey rider on the row's real content.
        label.font = Style.Fonts.badge
        label.textColor = Style.Colors.secondaryText
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    /// Driven by `observedProgress` rather than by our own KVO: WebKit's
    /// `Progress` is updated from whatever thread the transfer runs on, and
    /// `NSProgressIndicator` already knows how to observe one safely and how to
    /// coalesce redraws. This is the "does Apple already provide it" test
    /// passing.
    private let progressBar: NSProgressIndicator = {
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.controlSize = .small
        bar.translatesAutoresizingMaskIntoConstraints = false
        return bar
    }()

    /// The app's own icon button, so the row's one action has the same hover
    /// highlight as every other button in the chrome.
    private lazy var actionButton = IconButton(
        symbolName: "stop.circle",
        label: "Stop",
        side: 22
    ) { [weak self] in self?.onAction?() }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        [icon, nameLabel, statusLabel, progressBar, actionButton].forEach(addSubview)
        textField = nameLabel
        imageView = icon

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),

            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -8),

            progressBar.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            progressBar.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),

            statusLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: nameLabel.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("DownloadCellView is created in code only")
    }

    @MainActor
    func configure(with download: Download) {
        nameLabel.stringValue = download.filename
        icon.image = Self.icon(for: download)

        let running = download.state == .running
        progressBar.isHidden = !running
        progressBar.observedProgress = download.progress
        if running { progressBar.startAnimation(nil) } else { progressBar.stopAnimation(nil) }

        statusLabel.stringValue = Self.status(for: download)
        statusLabel.textColor = Self.isFailure(download.state) ? .systemRed : Style.Colors.secondaryText
        toolTip = download.sourceURL.absoluteString

        let action = Self.action(for: download)
        actionButton.setSymbol(action.symbol, label: action.title)

        // VoiceOver reads the row, so the state shown by the bar and the colour
        // of the status line has to be spoken as well.
        setAccessibilityLabel("\(download.filename), \(Self.status(for: download))")
    }

    // MARK: - Drawing

    /// The pill behind a hovered or selected row, inset from the row on all
    /// four sides -- the shape the sidebar's rows and the New Tab row use.
    var pillRect: NSRect {
        bounds.insetBy(dx: Style.Metrics.sidebarInset, dy: 3)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let fill: NSColor?
        if isSelected {
            fill = Style.Colors.rowSelectedFill
        } else if isHovered {
            fill = Style.Colors.rowHoverFill
        } else {
            fill = nil
        }
        guard let fill else { return }
        fill.setFill()
        NSBezierPath(
            roundedRect: pillRect,
            xRadius: Style.Metrics.rowCornerRadius,
            yRadius: Style.Metrics.rowCornerRadius
        ).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// A recycled row must not inherit the previous download's hover, or the
    /// handler that would have acted on it.
    override func prepareForReuse() {
        super.prepareForReuse()
        onAction = nil
        isHovered = false
        isSelected = false
        toolTip = nil
    }

    // MARK: - Presentation

    /// What the trailing button does in each state. There is exactly one
    /// affordance per row, so no button is ever present without a job.
    @MainActor
    static func action(for download: Download) -> (symbol: String, title: String) {
        switch download.state {
        case .running: ("stop.circle", "Stop")
        case .finished: ("magnifyingglass.circle", "Show in Finder")
        case .failed, .cancelled:
            download.host != nil ? ("arrow.clockwise.circle", download.canResume ? "Resume" : "Try Again")
                                 : ("trash.circle", "Remove")
        }
    }

    private static func isFailure(_ state: DownloadState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    @MainActor
    private static func status(for download: Download) -> String {
        switch download.state {
        case .running:
            // `Progress` already localises "2.4 MB of 9.1 MB" and a time
            // estimate. Formatting bytes by hand would be a worse version of a
            // string the system produces for free.
            download.progress?.localizedAdditionalDescription ?? "Starting\u{2026}"
        case .finished:
            [download.finalByteCount.map(byteCount), download.sourceURL.host()]
                .compactMap { $0 }
                .joined(separator: " \u{2014} ")
        case .failed(let message):
            message
        case .cancelled:
            "Cancelled"
        }
    }

    private static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The real file's icon once it exists, and the icon for its type before
    /// that, so a row does not change shape the instant it finishes.
    @MainActor
    private static func icon(for download: Download) -> NSImage {
        if download.fileExists {
            return NSWorkspace.shared.icon(forFile: download.destination.path(percentEncoded: false))
        }
        let type = UTType(filenameExtension: download.destination.pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}
