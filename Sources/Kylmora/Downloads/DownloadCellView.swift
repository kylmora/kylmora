import AppKit
import UniformTypeIdentifiers

/// One row in the downloads list: file icon, name, a progress bar while the
/// transfer runs, and the one action that row currently affords.
final class DownloadCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("DownloadCell")
    static let rowHeight: CGFloat = 54

    /// Fired by the trailing button, whose meaning changes with the state.
    var onAction: (() -> Void)?

    private let icon: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let nameLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private let statusLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
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

    private lazy var actionButton: NSButton = {
        let button = NSButton(image: NSImage(), target: self, action: #selector(performAction))
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.imageScaling = .scaleProportionallyDown
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        [icon, nameLabel, statusLabel, progressBar, actionButton].forEach(addSubview)
        textField = nameLabel
        imageView = icon

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),

            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            nameLabel.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -8),

            progressBar.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            progressBar.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),

            statusLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.widthAnchor.constraint(equalToConstant: 22),
            actionButton.heightAnchor.constraint(equalToConstant: 22)
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
        statusLabel.textColor = Self.isFailure(download.state) ? .systemRed : .secondaryLabelColor
        toolTip = download.sourceURL.absoluteString

        let action = Self.action(for: download)
        actionButton.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title)
        actionButton.setAccessibilityLabel(action.title)
        actionButton.toolTip = action.title

        // VoiceOver reads the row, so the state shown by the bar and the colour
        // of the status line has to be spoken as well.
        setAccessibilityLabel("\(download.filename), \(Self.status(for: download))")
    }

    @objc private func performAction() {
        onAction?()
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
