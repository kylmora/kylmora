import AppKit

/// The Sparkle-style software update window for Kylmora.
///
/// Presents new version announcements, release notes, download progress,
/// and prompt to install and relaunch. Also displays security assurances
/// explaining that WebKit security patches arrive automatically with macOS updates.
@MainActor
final class UpdateWindowController: NSWindowController {
    let release: UpdateCheck.Release
    private weak var controller: UpdateController?

    // Views
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let securityNoticeBox = NSBox()
    private let notesScrollView = NSScrollView()
    private let notesTextView = NSTextView()
    private let autoUpdateCheckbox = NSButton(checkboxWithTitle: "Automatically download and install updates in the future", target: nil, action: nil)

    // Action buttons
    private let skipButton = NSButton(title: "Skip This Version", target: nil, action: nil)
    private let remindLaterButton = NSButton(title: "Remind Me Later", target: nil, action: nil)
    private let installButton = NSButton(title: "Download & Install", target: nil, action: nil)

    // Progress elements
    private let progressContainer = NSStackView()
    private let progressLabel = NSTextField(labelWithString: "Downloading update…")
    private let progressIndicator = NSProgressIndicator()
    private let progressDetailLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    // Ready elements
    private let readyContainer = NSStackView()
    private let readyLabel = NSTextField(labelWithString: "Update Ready to Install")
    private let readyDetailLabel = NSTextField(wrappingLabelWithString: "")
    private let relaunchButton = NSButton(title: "Install and Relaunch", target: nil, action: nil)
    private let laterButton = NSButton(title: "Later", target: nil, action: nil)

    // Containers
    private let contentStack = NSStackView()
    private let buttonStack = NSStackView()

    enum DisplayState: Equatable {
        case prompt
        case downloading(progress: Double, bytesWritten: Int64, totalBytes: Int64)
        case readyToInstall(fileURL: URL)
        /// Checking the download and putting it in place.
        case installing
    }

    private(set) var displayState: DisplayState = .prompt

    init(release: UpdateCheck.Release, controller: UpdateController) {
        self.release = release
        self.controller = controller

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Software Update"
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        guard let contentView = window?.contentView else { return }

        // Icon
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64)
        ])

        // Titles
        titleLabel.font = .systemFont(ofSize: 16, weight: .bold)
        titleLabel.stringValue = "A new version of \(AppInfo.name) is available!"

        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.stringValue = "\(AppInfo.name) \(release.version) is now available (you have \(AppInfo.version)). Would you like to download it now?"
        subtitleLabel.preferredMaxLayoutWidth = 430

        // WebKit Security Notice
        setupSecurityNotice()

        // Release Notes
        notesScrollView.hasVerticalScroller = true
        notesScrollView.borderType = .bezelBorder
        notesScrollView.translatesAutoresizingMaskIntoConstraints = false
        notesScrollView.heightAnchor.constraint(equalToConstant: 160).isActive = true

        notesTextView.isEditable = false
        notesTextView.isSelectable = true
        notesTextView.font = .systemFont(ofSize: 12)
        notesTextView.textColor = .labelColor
        notesTextView.backgroundColor = .textBackgroundColor
        notesTextView.textContainerInset = NSSize(width: 8, height: 8)
        let formattedNotes = release.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Performance improvements and bug fixes."
        notesTextView.string = "Release Notes:\n\n\(formattedNotes)"
        notesScrollView.documentView = notesTextView

        // Auto update checkbox
        autoUpdateCheckbox.state = Settings.shared.automaticallyDownloadUpdates ? .on : .off
        autoUpdateCheckbox.target = self
        autoUpdateCheckbox.action = #selector(autoUpdateCheckboxToggled(_:))

        // Buttons
        skipButton.target = self
        skipButton.action = #selector(skipClicked(_:))
        skipButton.bezelStyle = .rounded

        remindLaterButton.target = self
        remindLaterButton.action = #selector(remindLaterClicked(_:))
        remindLaterButton.bezelStyle = .rounded

        installButton.target = self
        installButton.action = #selector(installClicked(_:))
        installButton.bezelStyle = .rounded
        installButton.keyEquivalent = "\r"

        buttonStack.orientation = .horizontal
        buttonStack.spacing = 10
        buttonStack.distribution = .fill
        buttonStack.addView(skipButton, in: .leading)
        buttonStack.addView(NSView(), in: .leading) // spacer
        buttonStack.addView(remindLaterButton, in: .trailing)
        buttonStack.addView(installButton, in: .trailing)

        // Progress elements
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0.0
        progressIndicator.maxValue = 1.0
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.widthAnchor.constraint(equalToConstant: 440).isActive = true

        progressLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        progressDetailLabel.font = .systemFont(ofSize: 11)
        progressDetailLabel.textColor = .secondaryLabelColor

        cancelButton.target = self
        cancelButton.action = #selector(cancelDownloadClicked(_:))
        cancelButton.bezelStyle = .rounded

        progressContainer.orientation = .vertical
        progressContainer.alignment = .leading
        progressContainer.spacing = 8
        progressContainer.addArrangedSubview(progressLabel)
        progressContainer.addArrangedSubview(progressIndicator)
        progressContainer.addArrangedSubview(progressDetailLabel)
        let cancelRow = NSStackView(views: [NSView(), cancelButton])
        cancelRow.orientation = .horizontal
        cancelRow.alignment = .centerY
        cancelRow.translatesAutoresizingMaskIntoConstraints = false
        cancelRow.widthAnchor.constraint(equalToConstant: 440).isActive = true
        progressContainer.addArrangedSubview(cancelRow)
        progressContainer.isHidden = true

        // Ready elements
        readyLabel.font = .systemFont(ofSize: 15, weight: .bold)
        readyDetailLabel.font = .systemFont(ofSize: 13)
        readyDetailLabel.stringValue = "\(AppInfo.name) \(release.version) is downloaded and ready to install. Relaunch now to apply the update."
        readyDetailLabel.preferredMaxLayoutWidth = 440

        relaunchButton.target = self
        relaunchButton.action = #selector(relaunchClicked(_:))
        relaunchButton.bezelStyle = .rounded
        relaunchButton.keyEquivalent = "\r"

        laterButton.target = self
        laterButton.action = #selector(laterClicked(_:))
        laterButton.bezelStyle = .rounded

        let readyButtonRow = NSStackView(views: [NSView(), laterButton, relaunchButton])
        readyButtonRow.orientation = .horizontal
        readyButtonRow.spacing = 10
        readyButtonRow.translatesAutoresizingMaskIntoConstraints = false
        readyButtonRow.widthAnchor.constraint(equalToConstant: 440).isActive = true

        readyContainer.orientation = .vertical
        readyContainer.alignment = .leading
        readyContainer.spacing = 10
        readyContainer.addArrangedSubview(readyLabel)
        readyContainer.addArrangedSubview(readyDetailLabel)
        readyContainer.addArrangedSubview(readyButtonRow)
        readyContainer.isHidden = true

        // Header stack
        let headerTextStack = NSStackView(views: [titleLabel, subtitleLabel, securityNoticeBox])
        headerTextStack.orientation = .vertical
        headerTextStack.alignment = .leading
        headerTextStack.spacing = 6

        let topRow = NSStackView(views: [iconView, headerTextStack])
        topRow.orientation = .horizontal
        topRow.alignment = .top
        topRow.spacing = 16

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        contentStack.addArrangedSubview(topRow)
        contentStack.addArrangedSubview(notesScrollView)
        contentStack.addArrangedSubview(autoUpdateCheckbox)
        contentStack.addArrangedSubview(buttonStack)
        contentStack.addArrangedSubview(progressContainer)
        contentStack.addArrangedSubview(readyContainer)

        contentView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
            notesScrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            buttonStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            securityNoticeBox.widthAnchor.constraint(equalTo: headerTextStack.widthAnchor)
        ])
    }

    private func setupSecurityNotice() {
        securityNoticeBox.boxType = .custom
        securityNoticeBox.borderWidth = 1
        securityNoticeBox.borderColor = NSColor.separatorColor.withAlphaComponent(0.5)
        securityNoticeBox.cornerRadius = 6
        securityNoticeBox.fillColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.25)

        let shieldImageView = NSImageView()
        if #available(macOS 11.0, *) {
            shieldImageView.image = NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: "Security")
        }
        shieldImageView.contentTintColor = .systemGreen
        shieldImageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            shieldImageView.widthAnchor.constraint(equalToConstant: 14),
            shieldImageView.heightAnchor.constraint(equalToConstant: 14)
        ])

        let securityLabel = NSTextField(wrappingLabelWithString: "WebKit security patches arrive automatically with macOS system updates.")
        securityLabel.font = .systemFont(ofSize: 11, weight: .medium)
        securityLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [shieldImageView, securityLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        securityNoticeBox.contentView = stack
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: securityNoticeBox.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: securityNoticeBox.bottomAnchor, constant: -5),
            stack.leadingAnchor.constraint(equalTo: securityNoticeBox.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: securityNoticeBox.trailingAnchor, constant: -8)
        ])
    }

    // MARK: - State Management

    func transition(to state: DisplayState) {
        self.displayState = state
        switch state {
        case .prompt:
            notesScrollView.isHidden = false
            autoUpdateCheckbox.isHidden = false
            buttonStack.isHidden = false
            progressContainer.isHidden = true
            readyContainer.isHidden = true
        case .downloading(let progress, let bytesWritten, let totalBytes):
            notesScrollView.isHidden = true
            autoUpdateCheckbox.isHidden = true
            buttonStack.isHidden = true
            progressContainer.isHidden = false
            readyContainer.isHidden = true

            if totalBytes > 0 {
                progressIndicator.isIndeterminate = false
                progressIndicator.doubleValue = progress
                let writtenMB = Double(bytesWritten) / (1024 * 1024)
                let totalMB = Double(totalBytes) / (1024 * 1024)
                progressDetailLabel.stringValue = String(format: "%.1f MB of %.1f MB (%.0f%%)", writtenMB, totalMB, progress * 100)
            } else {
                progressIndicator.isIndeterminate = true
                progressIndicator.startAnimation(nil)
                let writtenMB = Double(bytesWritten) / (1024 * 1024)
                progressDetailLabel.stringValue = String(format: "%.1f MB downloaded", writtenMB)
            }
        case .readyToInstall:
            notesScrollView.isHidden = true
            autoUpdateCheckbox.isHidden = true
            buttonStack.isHidden = true
            progressContainer.isHidden = true
            readyContainer.isHidden = false
            readyDetailLabel.stringValue = "\(AppInfo.name) \(release.version) has been downloaded. Installing it replaces this copy and reopens it."
        case .installing:
            // The window keeps the progress bar it was already showing, now
            // without a percentage: checking a signature and copying a bundle
            // finish when they finish, and a bar that guesses at how long is
            // worse than one that admits it does not know.
            notesScrollView.isHidden = true
            autoUpdateCheckbox.isHidden = true
            buttonStack.isHidden = true
            progressContainer.isHidden = false
            readyContainer.isHidden = true
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(nil)
            progressDetailLabel.stringValue = "Checking the download and installing it\u{2026}"
        }
    }

    // MARK: - Actions

    @objc private func autoUpdateCheckboxToggled(_ sender: NSButton) {
        Settings.shared.automaticallyDownloadUpdates = (sender.state == .on)
    }

    @objc private func skipClicked(_ sender: Any?) {
        Settings.shared.skippedUpdateVersion = release.version
        close()
    }

    @objc private func remindLaterClicked(_ sender: Any?) {
        close()
    }

    @objc private func installClicked(_ sender: Any?) {
        controller?.startDownload(for: release)
    }

    @objc private func cancelDownloadClicked(_ sender: Any?) {
        controller?.cancelDownload()
        transition(to: .prompt)
    }

    @objc private func relaunchClicked(_ sender: Any?) {
        controller?.relaunchAndInstall()
    }

    @objc private func laterClicked(_ sender: Any?) {
        close()
    }
}
