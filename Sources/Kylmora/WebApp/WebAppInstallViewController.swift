import AppKit

/// A modal sheet presenting the user with options to install a web site
/// as a standalone macOS application.
@MainActor
final class WebAppInstallViewController: NSViewController {
    var onInstall: ((String, URL, UUID?, NSImage?) -> Void)?
    var onCancel: (() -> Void)?

    private let initialName: String
    private let initialURL: URL
    private let initialIcon: NSImage?
    private let spaces: [(id: UUID, name: String)]
    private let defaultSpaceID: UUID?

    private let iconView = NSImageView()
    private let nameField = NSTextField()
    private let urlField = NSTextField()
    private let spacePopup = NSPopUpButton()
    private let openAfterInstallCheckbox = NSButton(checkboxWithTitle: "Open application after install", target: nil, action: nil)

    init(
        name: String,
        url: URL,
        icon: NSImage? = nil,
        spaces: [(id: UUID, name: String)] = [],
        defaultSpaceID: UUID? = nil
    ) {
        self.initialName = name
        self.initialURL = url
        self.initialIcon = icon
        self.spaces = spaces
        self.defaultSpaceID = defaultSpaceID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("WebAppInstallViewController is created in code only")
    }

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 290))
        self.view = view

        let titleLabel = NSTextField(labelWithString: "Install Site as Web App")
        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: "Creates a dedicated macOS application for this site in your Applications folder.")
        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(subtitleLabel)

        // Icon preview
        let previewIcon = WebAppGenerator.generateIcon(name: initialName, sourceImage: initialIcon)
        iconView.image = previewIcon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(iconView)

        // Name
        let nameLabel = NSTextField(labelWithString: "Name:")
        nameLabel.font = NSFont.systemFont(ofSize: 12)
        nameLabel.alignment = .right
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nameLabel)

        nameField.stringValue = initialName
        nameField.placeholderString = "Application Name"
        nameField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nameField)

        // URL
        let urlLabel = NSTextField(labelWithString: "URL:")
        urlLabel.font = NSFont.systemFont(ofSize: 12)
        urlLabel.alignment = .right
        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(urlLabel)

        urlField.stringValue = initialURL.absoluteString
        urlField.placeholderString = "https://example.com"
        urlField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(urlField)

        // Space
        let spaceLabel = NSTextField(labelWithString: "Space:")
        spaceLabel.font = NSFont.systemFont(ofSize: 12)
        spaceLabel.alignment = .right
        spaceLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spaceLabel)

        spacePopup.translatesAutoresizingMaskIntoConstraints = false
        spacePopup.removeAllItems()
        for space in spaces {
            spacePopup.addItem(withTitle: space.name)
            spacePopup.lastItem?.representedObject = space.id
            if space.id == defaultSpaceID {
                spacePopup.select(spacePopup.lastItem)
            }
        }
        view.addSubview(spacePopup)

        // Open after install
        openAfterInstallCheckbox.state = .on
        openAfterInstallCheckbox.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(openAfterInstallCheckbox)

        // Buttons
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancelButton)

        let installButton = NSButton(title: "Install", target: self, action: #selector(installClicked))
        installButton.bezelStyle = .rounded
        installButton.keyEquivalent = "\r"
        installButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(installButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            iconView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 18),
            iconView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 16),
            nameLabel.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            nameLabel.widthAnchor.constraint(equalToConstant: 50),

            nameField.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 16),
            nameField.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            nameField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            urlLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            urlLabel.centerYAnchor.constraint(equalTo: urlField.centerYAnchor),
            urlLabel.widthAnchor.constraint(equalToConstant: 50),

            urlField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 10),
            urlField.leadingAnchor.constraint(equalTo: urlLabel.trailingAnchor, constant: 8),
            urlField.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),

            spaceLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            spaceLabel.centerYAnchor.constraint(equalTo: spacePopup.centerYAnchor),
            spaceLabel.widthAnchor.constraint(equalToConstant: 50),

            spacePopup.topAnchor.constraint(equalTo: urlField.bottomAnchor, constant: 10),
            spacePopup.leadingAnchor.constraint(equalTo: spaceLabel.trailingAnchor, constant: 8),
            spacePopup.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),

            openAfterInstallCheckbox.leadingAnchor.constraint(equalTo: spacePopup.leadingAnchor),
            openAfterInstallCheckbox.topAnchor.constraint(equalTo: spacePopup.bottomAnchor, constant: 14),

            cancelButton.trailingAnchor.constraint(equalTo: installButton.leadingAnchor, constant: -12),
            cancelButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),

            installButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            installButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18)
        ])
    }

    @objc private func cancelClicked() {
        onCancel?()
        dismiss(nil)
    }

    @objc private func installClicked() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = name.isEmpty ? initialName : name

        let urlString = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: urlString) ?? URL(string: "https://\(urlString)") else {
            return
        }

        let selectedSpaceID = spacePopup.selectedItem?.representedObject as? UUID
        onInstall?(finalName, url, selectedSpaceID, initialIcon)
        dismiss(nil)
    }
}
