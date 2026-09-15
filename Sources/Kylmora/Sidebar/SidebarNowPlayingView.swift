import AppKit

/// A compact card pinned in the sidebar above the footer that shows the currently
/// playing audio or video track, along with play/pause, mute, and PiP controls.
@MainActor
final class SidebarNowPlayingView: NSView {
    var onSelectTab: ((Tab) -> Void)?

    private weak var currentTab: Tab?

    private let iconView: NSImageView = {
        let iv = NSImageView()
        iv.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Now Playing")
        iv.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        iv.contentTintColor = Style.Colors.secondaryText
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = Style.Fonts.emphasis
        label.textColor = Style.Colors.primaryText
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let subtitleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = Style.Colors.secondaryText
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var playPauseButton = IconButton(
        symbolName: "play.fill",
        label: "Play / Pause",
        side: 20
    )

    private lazy var muteButton = IconButton(
        symbolName: "speaker.wave.2.fill",
        label: "Mute",
        side: 20
    )

    private lazy var pipButton = IconButton(
        symbolName: "pip.enter",
        label: "Picture in Picture",
        side: 20
    )

    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let controlsStack = NSStackView(views: [playPauseButton, muteButton, pipButton])
        controlsStack.orientation = .horizontal
        controlsStack.spacing = 4
        controlsStack.alignment = .centerY
        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        controlsStack.setContentHuggingPriority(.required, for: .horizontal)
        controlsStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(iconView)
        addSubview(textStack)
        addSubview(controlsStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: controlsStack.leadingAnchor, constant: -6),

            controlsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            controlsStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingArea = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point), let currentTab {
            onSelectTab?(currentTab)
        } else {
            super.mouseUp(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill = isHovered ? Style.Colors.rowHoverFill : Style.Colors.folderPlateFill
        fill.setFill()
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        path.fill()
    }

    func update(with tab: Tab?) {
        guard let tab, tab.isPlayingMedia || tab.isPlayingAudio || tab.isInPictureInPicture else {
            isHidden = true
            currentTab = nil
            return
        }

        currentTab = tab
        isHidden = false

        let displayTitle = !tab.mediaTitle.isEmpty ? tab.mediaTitle : tab.displayTitle
        let displaySubtitle = !tab.mediaArtist.isEmpty ? tab.mediaArtist : (tab.url.host() ?? "")

        titleLabel.stringValue = displayTitle
        subtitleLabel.stringValue = displaySubtitle
        subtitleLabel.isHidden = displaySubtitle.isEmpty

        let isPlaying = tab.isPlayingMedia
        playPauseButton.setSymbol(isPlaying ? "pause.fill" : "play.fill", label: isPlaying ? "Pause" : "Play")
        playPauseButton.setClickHandler { [weak tab] in tab?.togglePlayPause() }

        muteButton.setSymbol(tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: tab.isMuted ? "Unmute" : "Mute")
        muteButton.setClickHandler { [weak tab] in tab?.toggleMute() }

        pipButton.setSymbol(tab.isInPictureInPicture ? "pip.exit" : "pip.enter", label: tab.isInPictureInPicture ? "Exit Picture in Picture" : "Picture in Picture")
        pipButton.setClickHandler { [weak tab] in
            guard let tab else { return }
            if tab.isInPictureInPicture {
                tab.exitPictureInPicture()
            } else {
                tab.requestPictureInPicture()
            }
        }
        needsDisplay = true
    }
}
