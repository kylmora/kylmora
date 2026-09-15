import AppKit

/// Everything a tab row draws, as plain values.
///
/// Deliberately not a `Tab`: the row is then testable without a session, and a
/// row can be built for something that is not a tab at all. The one exception
/// is the favicon, which stays a `FaviconImageView` because that view already
/// owns the whole fetch-and-reuse dance and re-deriving it here would be worse
/// than the coupling.
struct TabRowContent {
    var title: String
    /// Shown in the tooltip and read by VoiceOver. `nil` for a row that has no
    /// address, such as a brand-new empty tab.
    var address: String?
    var isLoading: Bool = false
    /// Holding no web view: released after being loaded, or never loaded at
    /// all. Dimmed rather than hidden, because the memory really is not being
    /// held and pretending otherwise would be a lie about state. It also earns
    /// a moon on the trailing edge, because dimming alone is a difference
    /// nobody can name -- "is that row greyer than the others?" is not a thing
    /// a user should have to ask.
    var isAsleep: Bool = false
    var isFailed: Bool = false
    /// How long since the tab was last on screen, already formatted -- `10m`,
    /// `2h`. `nil` when the setting hides it, or the tab is too recent to say
    /// anything interesting.
    var idleText: String?
    /// The same fact for VoiceOver, which would read `10m` as two letters.
    var idleSpoken: String?
    /// Never suspended, by the user's instruction. Drawn as a filled pin so the
    /// lock is visible from the sidebar and not only from the menu that set it.
    var keepsAwake: Bool = false
    /// Never archived, by the user's instruction.
    var keepsInSidebar: Bool = false
    /// Refuses to close. Drawn as a padlock, and it takes the close button's
    /// place rather than sitting beside it: a cross that does nothing when
    /// clicked is worse than no cross at all.
    var isLocked: Bool = false
    /// Whether audio is actively playing in this tab.
    var isPlayingAudio: Bool = false
    /// Whether audio has been muted for this tab.
    var isMuted: Bool = false
    /// The user's colour tag, drawn as a dot on the favicon's corner.
    var colorTag: TabColorTag? = nil
    /// The page changed its title while the tab was out of sight.
    var hasUnreadChange: Bool = false
    /// An emoji standing in for the favicon.
    var emoji: String? = nil

    init(
        title: String,
        address: String? = nil,
        isLoading: Bool = false,
        isAsleep: Bool = false,
        isFailed: Bool = false,
        idleText: String? = nil,
        idleSpoken: String? = nil,
        keepsAwake: Bool = false,
        keepsInSidebar: Bool = false,
        isLocked: Bool = false,
        isPlayingAudio: Bool = false,
        isMuted: Bool = false,
        colorTag: TabColorTag? = nil,
        hasUnreadChange: Bool = false,
        emoji: String? = nil
    ) {
        self.title = title
        self.address = address
        self.isLoading = isLoading
        self.isAsleep = isAsleep
        self.isFailed = isFailed
        self.idleText = idleText
        self.idleSpoken = idleSpoken
        self.keepsAwake = keepsAwake
        self.keepsInSidebar = keepsInSidebar
        self.isLocked = isLocked
        self.isPlayingAudio = isPlayingAudio
        self.isMuted = isMuted
        self.colorTag = colorTag
        self.hasUnreadChange = hasUnreadChange
        self.emoji = emoji
    }
}

/// One row in the sidebar's tab list: favicon and title, with a spinner or a
/// close button on the trailing edge. A page thumbnail was also tried there
/// on the selected row; it was built and then removed at the user's request.
///
/// The row draws its own selection pill rather than using the table view's
/// highlight, because the pill is inset from the row on all four sides and
/// rounded; `NSTableView` cannot draw that. The consequence is that the table
/// must run with `selectionHighlightStyle = .none` and tell rows when they are
/// selected, which the integration note spells out.
@MainActor
final class TabRowView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("TabRow")

    /// Close button clicked. When `nil` the button never appears, which is what
    /// a row that is not a closable tab wants.
    var onClose: (() -> Void)?

    /// Toggle mute clicked for playing audio.
    var onToggleMute: (() -> Void)?

    /// Exposed so the caller can drive it from a `Tab` without this view ever
    /// seeing one.
    let favicon = FaviconImageView()

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            updateHighlight()
            updateTrailing()
        }
    }

    /// Leading inset, on top of the pill's own. Rows inside a group are stepped
    /// in by `Style.Metrics.rowIndent`; loose rows pass 0.
    var indentation: CGFloat = Style.Metrics.rowIndent {
        didSet {
            leadingConstraint?.constant = contentInset + indentation
            needsLayout = true
        }
    }

    /// A row inside a group's plate. Its pill -- and the close button and spinner
    /// inside it -- are inset from the plate's trailing edge by one indent level,
    /// mirroring the indent that already holds the content off the leading edge,
    /// so the whole row sits balanced inside the plate instead of running flush
    /// into its rounded right corner. Loose rows have no plate and keep the
    /// content out at the row edge.
    var isInGroupPlate = false {
        didSet {
            guard isInGroupPlate != oldValue else { return }
            let extra = isInGroupPlate ? Style.Metrics.rowIndent : 0
            for constraint in trailingConstraints { constraint.constant = -(contentInset + extra) }
            needsLayout = true
        }
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    /// The emoji drawn where the favicon goes, when the tab has one.
    private let emojiLabel = NSTextField(labelWithString: "")
    var showsEmoji: Bool { !emojiLabel.isHidden }
    /// The colour tag on the favicon's lower trailing corner.
    private let tagDot = NSView()
    /// The unread mark on the favicon's upper trailing corner.
    private let unreadDot = NSView()

    var showsTagDot: Bool { !tagDot.isHidden }
    var showsUnreadDot: Bool { !unreadDot.isHidden }

    /// The band of the row the pill -- and everything in it -- occupies,
    /// pinned to the row's top edge.
    ///
    /// A row is normally exactly `rowHeight`, but the row that ends a folder's
    /// plate is taller, so that the plate has room under its last pill. Pinning
    /// the content here keeps the favicon, title and close button in the top
    /// `rowHeight` points of such a row instead of following its centre down
    /// into the padding; an ordinary row is unaffected.
    private let pillStrip = NSLayoutGuide()

    /// The trailing badge: the locks the user set, whether the tab is asleep,
    /// and how long it has been idle. A stack rather than four constraints
    /// because its contents come and go independently, and a stack with no
    /// visible arranged subview measures zero -- which is what lets the title
    /// run the full width of a row that has nothing to say.
    // The padlock belongs to the close lock, which is what a user means by
    // "locked". "Kept in sidebar" is the narrower promise -- only that idleness
    // will not carry the tab off -- so it gets the idle clock, struck through,
    // which reads correctly sitting immediately beside the idle time itself.
    private let lockedIcon = TabRowView.badgeIcon("lock.fill", label: "locked")
    private let stayIcon = TabRowView.badgeIcon("clock.badge.xmark", label: "kept in sidebar")
    private let awakeIcon = TabRowView.badgeIcon("sun.max.fill", label: "kept awake")
    private let sleepIcon = TabRowView.badgeIcon("moon.zzz.fill", label: "sleeping")
    private let idleLabel = NSTextField(labelWithString: "")
    private lazy var badge: NSStackView = {
        let stack = NSStackView(views: [lockedIcon, stayIcon, awakeIcon, sleepIcon, idleLabel])
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        // The badge yields the row to the title before it truncates itself:
        // "10m" is worth less than another word of the page's name.
        stack.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        stack.setContentHuggingPriority(.required, for: .horizontal)
        return stack
    }()

    private static func badgeIcon(_ symbol: String, label: String) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        view.contentTintColor = Style.Colors.tertiaryText
        view.isHidden = true
        view.setAccessibilityElement(false)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }
    private lazy var closeButton = IconButton(
        symbolName: "xmark",
        label: "Close Tab",
        side: 18,
        onClick: { [weak self] in self?.onClose?() }
    )

    private lazy var audioButton = IconButton(
        symbolName: "speaker.wave.2.fill",
        label: "Mute Tab",
        side: 18,
        onClick: { [weak self] in self?.onToggleMute?() }
    )

    private var content = TabRowContent(title: "")
    /// The animated plate behind the row. Drawn by a layer rather than in
    /// `draw(_:)` so selection and hover fade rather than blink, and so the
    /// selected row can carry a hairline and a shadow.
    private var highlight: RowHighlight?
    /// A cell that has just been built or recycled arrives already looking
    /// right, rather than fading in from the last row's state. Cleared on the
    /// first layout pass, by which point both `configure` and `isSelected`
    /// have had their say about this row.
    private var isFresh = true
    private var leadingConstraint: NSLayoutConstraint?
    /// The spinner's and close button's trailing constraints, kept so a row on a
    /// group plate can pull them in to match the pill's trailing inset.
    private var trailingConstraints: [NSLayoutConstraint] = []
    private var audioTrailingClose: NSLayoutConstraint?
    private var audioTrailingEdge: NSLayoutConstraint?
    private var titleAudioConstraint: NSLayoutConstraint?
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            updateHighlight()
            updateTrailing()
        }
    }

    /// Half the difference between the row and the pill: the margin the pill
    /// keeps at the leading and trailing edges, and the one it keeps above and
    /// below itself in an ordinary row. A row taller than `rowHeight` -- the
    /// last one on a folder's plate -- keeps this margin at its top and puts
    /// every extra point underneath the pill, where the plate's bottom edge is.
    private var pillInset: CGFloat {
        (Style.Metrics.rowHeight - Style.Metrics.rowPillHeight) / 2
    }

    /// Where the favicon starts: the pill's own margin plus the padding inside
    /// it. Kept as one number so the close button on the trailing edge is inset
    /// by exactly as much as the icon on the leading one.
    private var contentInset: CGFloat {
        pillInset + Style.Metrics.rowContentInset
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The selected row's plate casts a shadow, and a pill inset three
        // points inside its row needs about four to lay one down. Clipped to
        // the cell, the shadow was sliced off in a hard straight line a
        // fraction below the pill -- which reads as a grey rectangle stuck
        // behind the row rather than as a shadow. A shadow that leaves its
        // own row and falls on the neighbouring ones is what a shadow does.
        clipsToBounds = false
        if let layer { highlight = RowHighlight(in: layer) }

        titleLabel.font = Style.Fonts.body
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setAccessibilityElement(false)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        closeButton.isHidden = true
        audioButton.isHidden = true

        idleLabel.font = Style.Fonts.badge
        idleLabel.textColor = Style.Colors.tertiaryText
        idleLabel.setAccessibilityElement(false)
        idleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(favicon)
        emojiLabel.font = .systemFont(ofSize: 13)
        emojiLabel.alignment = .center
        emojiLabel.isHidden = true
        emojiLabel.translatesAutoresizingMaskIntoConstraints = false
        emojiLabel.setAccessibilityElement(false)
        addSubview(emojiLabel)
        NSLayoutConstraint.activate([
            emojiLabel.centerXAnchor.constraint(equalTo: favicon.centerXAnchor),
            emojiLabel.centerYAnchor.constraint(equalTo: favicon.centerYAnchor)
        ])
        for dot in [tagDot, unreadDot] {
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.borderWidth = 1.5
            dot.isHidden = true
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.setAccessibilityElement(false)
            addSubview(dot)
        }
        unreadDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        NSLayoutConstraint.activate([
            tagDot.widthAnchor.constraint(equalToConstant: 7),
            tagDot.heightAnchor.constraint(equalToConstant: 7),
            tagDot.centerXAnchor.constraint(equalTo: favicon.trailingAnchor, constant: -1),
            tagDot.centerYAnchor.constraint(equalTo: favicon.bottomAnchor, constant: -1),
            unreadDot.widthAnchor.constraint(equalToConstant: 7),
            unreadDot.heightAnchor.constraint(equalToConstant: 7),
            unreadDot.centerXAnchor.constraint(equalTo: favicon.trailingAnchor, constant: -1),
            unreadDot.centerYAnchor.constraint(equalTo: favicon.topAnchor, constant: 1)
        ])
        addSubview(titleLabel)
        addSubview(badge)
        addSubview(spinner)
        addSubview(audioButton)
        addSubview(closeButton)
        textField = titleLabel

        addLayoutGuide(pillStrip)
        NSLayoutConstraint.activate([
            pillStrip.topAnchor.constraint(equalTo: topAnchor),
            pillStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            pillStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            pillStrip.heightAnchor.constraint(equalToConstant: Style.Metrics.rowHeight)
        ])

        let leading = favicon.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: contentInset + indentation
        )
        leadingConstraint = leading

        let spinnerTrailing = spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -contentInset)
        let closeTrailing = closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -contentInset)
        let badgeTrailing = badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -contentInset)
        let audioEdge = audioButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -contentInset)
        let audioClose = audioButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2)
        audioTrailingEdge = audioEdge
        audioTrailingClose = audioClose

        trailingConstraints = [spinnerTrailing, closeTrailing, badgeTrailing, audioEdge]

        let titleAudio = titleLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: audioButton.leadingAnchor,
            constant: -Style.Metrics.rowContentSpacing
        )
        titleAudioConstraint = titleAudio

        NSLayoutConstraint.activate([
            leading,
            favicon.centerYAnchor.constraint(equalTo: pillStrip.centerYAnchor),

            titleLabel.leadingAnchor.constraint(
                equalTo: favicon.trailingAnchor,
                constant: Style.Metrics.rowContentSpacing
            ),
            titleLabel.centerYAnchor.constraint(equalTo: pillStrip.centerYAnchor),
            // The title stops short of the trailing slot, so a long one is
            // truncated rather than run under the spinner or close button.
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: spinner.leadingAnchor,
                constant: -Style.Metrics.rowContentSpacing
            ),
            // And short of the badge, which is wider than the slot and shares
            // the same edge. An empty badge measures zero, so this constraint
            // costs a row with nothing to report exactly nothing.
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: badge.leadingAnchor,
                constant: -Style.Metrics.rowContentSpacing
            ),

            badgeTrailing,
            badge.centerYAnchor.constraint(equalTo: pillStrip.centerYAnchor),

            spinnerTrailing,
            spinner.centerYAnchor.constraint(equalTo: pillStrip.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),

            audioButton.centerYAnchor.constraint(equalTo: pillStrip.centerYAnchor),
            audioEdge,

            closeTrailing,
            closeButton.centerYAnchor.constraint(equalTo: pillStrip.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("TabRowView is created in code only")
    }

    func configure(_ content: TabRowContent) {
        self.content = content
        titleLabel.stringValue = content.title
        titleLabel.textColor = content.isAsleep
            ? Style.Colors.secondaryText
            : Style.Colors.primaryText
        toolTip = content.address

        emojiLabel.stringValue = content.emoji ?? ""
        emojiLabel.isHidden = content.emoji == nil
        favicon.isHidden = content.emoji != nil

        effectiveAppearance.performAsCurrentDrawingAppearance {
            if let tag = content.colorTag {
                tagDot.layer?.backgroundColor = tag.nsColor.cgColor
                tagDot.layer?.borderColor = Style.Colors.dotRing.cgColor
                tagDot.isHidden = false
            } else {
                tagDot.isHidden = true
            }
            unreadDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            unreadDot.layer?.borderColor = Style.Colors.dotRing.cgColor
        }
        unreadDot.isHidden = !content.hasUnreadChange

        // VoiceOver reads the row, so state that is only shown visually --
        // dimming for suspended, a spinner for loading -- has to be spoken too.
        var described = content.title
        if content.isFailed {
            described += ", failed to load"
        } else if content.isAsleep {
            described += ", sleeping"
        } else if content.isLoading {
            described += ", loading"
        }
        // The locks and the timer are spoken whatever the state above, because
        // each is a separate fact about the row and any of them can be the one
        // the listener is looking for.
        if content.keepsAwake { described += ", kept awake" }
        // One or the other, matching the badge: the lock says both.
        if content.isLocked {
            described += ", locked"
        } else if content.keepsInSidebar {
            described += ", kept in sidebar"
        }
        if content.isMuted {
            described += ", muted"
        } else if content.isPlayingAudio {
            described += ", playing audio"
        }
        if let tag = content.colorTag { described += ", tagged \(tag.title.lowercased())" }
        if content.hasUnreadChange { described += ", changed since you last looked" }
        if let spoken = content.idleSpoken { described += ", \(spoken)" }
        setAccessibilityRole(.row)
        setAccessibilityLabel(described)
        closeButton.setAccessibilityLabel("Close \(content.title)")
        updateTrailing()
    }

    /// Updates only the idle timer, for the sidebar's tick.
    ///
    /// Not `configure`: that re-runs the favicon lookup, and a badge that
    /// counts minutes would then re-fetch every icon in the sidebar for the
    /// rest of the session. Returns whether anything actually changed, so a
    /// tick over an unchanged sidebar costs one string comparison per row.
    @discardableResult
    func updateIdle(text: String?, spoken: String?) -> Bool {
        guard text != content.idleText else { return false }
        content.idleText = text
        content.idleSpoken = spoken
        updateTrailing()
        // The row's spoken label carries the timer, so it has to be rebuilt
        // with it rather than left describing a tab that went quiet an hour ago.
        configure(content)
        return true
    }

    /// The trailing edge has candidates for the trailing slot -- close button,
    /// audio/mute button, and spinner -- so the precedence lives in one place.
    private func updateTrailing() {
        // A locked tab has no close button at any point, hovered or selected.
        // The padlock that stands there instead is the whole affordance: it
        // says why the cross is missing, in the exact spot the eye went to
        // look for it.
        let canClose = onClose != nil && !content.isLocked
        let showClose = (isHovered || isSelected) && canClose
        closeButton.isHidden = !showClose
        if content.isLoading && !showClose {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }

        let hasAudio = content.isPlayingAudio || content.isMuted
        audioButton.isHidden = !hasAudio
        if hasAudio {
            if content.isMuted {
                audioButton.setSymbol("speaker.slash.fill", label: "Unmute Tab")
            } else {
                audioButton.setSymbol("speaker.wave.2.fill", label: "Mute Tab")
            }
            if showClose {
                audioTrailingEdge?.isActive = false
                audioTrailingClose?.isActive = true
            } else {
                audioTrailingClose?.isActive = false
                audioTrailingEdge?.isActive = true
            }
            titleAudioConstraint?.isActive = true
        } else {
            titleAudioConstraint?.isActive = false
        }

        // Third in line for the trailing slot, yielding to close, spinner and audio.
        let showBadge = !showClose && !content.isLoading && !hasAudio
        // The lock outranks the badge's own yielding: it is the reason the row
        // has no close button, so it shows even while the row is hovered.
        lockedIcon.isHidden = !(content.isLocked && !hasAudio)
        // Suppressed under a padlock rather than drawn next to it. Locking a
        // tab already keeps it in the sidebar, and two glyphs for one promise
        // invites the reader to hunt for a difference that is not there.
        stayIcon.isHidden = !(showBadge && content.keepsInSidebar && !content.isLocked)
        awakeIcon.isHidden = !(showBadge && content.keepsAwake)
        sleepIcon.isHidden = !(showBadge && content.isAsleep)
        let idle = showBadge ? content.idleText : nil
        idleLabel.stringValue = idle ?? ""
        idleLabel.isHidden = idle == nil
    }

    /// The plate drawn behind a selected or hovered row.
    ///
    /// It starts at the row's own indent, not at the cell's edge. A full-width
    /// plate under an indented title is what made a folder's children read as
    /// loose rows: the only thing saying they were nested was the icon, and the
    /// selection undid even that. Exposed so the shape can be checked without
    /// rendering the view.
    var pillRect: NSRect {
        // The pill keeps its own height whatever the row's. A row taller than
        // `rowHeight` -- the last one on a folder's plate -- spends its extra
        // points below the pill, inside the plate, rather than stretching the
        // pill down to meet the plate's bottom edge and reading as part of the
        // card's outline. It is anchored to the row's top edge, which is the
        // same thing in an ordinary row and keeps the rhythm of the rows above
        // it in a taller one.
        var pill = NSRect(
            x: pillInset,
            y: isFlipped ? pillInset : bounds.height - pillInset - Style.Metrics.rowPillHeight,
            width: bounds.width - 2 * pillInset,
            height: Style.Metrics.rowPillHeight
        )
        pill.origin.x += indentation
        pill.size.width -= indentation
        if isInGroupPlate {
            // One indent level of trailing margin, matching the leading indent,
            // so the pill is inset from the plate by the same amount on both
            // sides rather than sitting flush against its right edge. The
            // plate's bottom edge is cleared by the row's own height instead:
            // the row that ends the plate carries `folderPlateBottomPadding`
            // below its pill.
            pill.size.width -= Style.Metrics.rowIndent
        }
        return pill
    }

    override func layout() {
        super.layout()
        highlight?.layout(
            pillRect,
            in: bounds.height,
            flipped: isFlipped,
            radius: Style.Metrics.rowCornerRadius,
            scale: highlightScale
        )
        resyncHover()
        // Both halves of this row's state have been applied by now, so from
        // here on a change is a change the user made and is worth animating.
        if isFresh {
            isFresh = false
            updateHighlight(animated: false)
        }
    }

    /// What the plate is currently showing. Exposed so the rule that selection
    /// outranks hover can be checked without rendering anything.
    var highlightState: RowHighlight.State { highlight?.state ?? .rest }

    /// The plate's state follows from the row's, in one place.
    private func updateHighlight(animated: Bool = true) {
        let state: RowHighlight.State = isSelected ? .selected : (isHovered ? .hover : .rest)
        highlight?.apply(state, appearance: effectiveAppearance, animated: animated && !isFresh)
    }

    /// Drops a hover the pointer has already left.
    ///
    /// `mouseExited` is not guaranteed: a list that reloads or scrolls under a
    /// pointer that never moves, or an app that deactivates with the pointer on
    /// a row, both leave the row lit with nothing on it -- and, worse, wearing
    /// a close button, so a row that is not the one under the pointer offers to
    /// close itself. Checked only while the row believes it is hovered, so the
    /// common case costs nothing.
    private func resyncHover() {
        if isHovered && !isPointerInside { isHovered = false }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        highlight?.refresh(appearance: effectiveAppearance)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea = installHoverTracking(replacing: trackingArea)
        // The tracking area is rebuilt when the row moves or the list changes
        // shape, which is exactly when an exit event is most likely to have
        // been missed.
        isHovered = isPointerInside
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// A recycled row must not inherit the previous tab's hover state, and the
    /// close handler must be cleared before the next configure so a stale
    /// closure cannot close the wrong tab.
    override func prepareForReuse() {
        super.prepareForReuse()
        onClose = nil
        // Whatever this cell shows next arrives already correct rather than
        // fading out of the previous row's selection.
        isFresh = true
        onToggleMute = nil
        isHovered = false
        isSelected = false
        content = TabRowContent(title: "")
        for view in [lockedIcon, stayIcon, awakeIcon, sleepIcon] { view.isHidden = true }
        idleLabel.stringValue = ""
        idleLabel.isHidden = true
        // Set by `configure`, and the one thing there that is not derived
        // from `content` on the next configure if the new address is nil.
        toolTip = nil
    }
}
