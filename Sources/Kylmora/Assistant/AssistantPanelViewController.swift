import AppKit

/// The AI assistant beside the page: a chat with the model the user chose,
/// able to read and use the page.
///
/// Built from the same parts as the extension side panel, because it is the
/// same kind of surface: a rounded card inset by the gutter, on the window's
/// material washed in the space's colour, with a header the height of the
/// page's own top bar and Kylmora's icon buttons.
@MainActor
final class AssistantPanelViewController: NSViewController {
    private let session: AssistantSession
    var onClose: (() -> Void)?

    private let card = NSView()
    private let cardShadow = CALayer()
    private let underlay = NSVisualEffectView()
    private let tint = TintView()
    private var windowEdgeConstraint: NSLayoutConstraint?

    private let header = NSView()
    private let modelButton = NSButton()
    private let chat = AssistantChatView()
    private let models = AssistantModelsView()

    init(browser: BrowserSession) {
        session = AssistantSession(browser: browser)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("AssistantPanelViewController is created in code only")
    }

    override func loadView() {
        let root = CardHostView()
        root.wantsLayer = true
        root.translatesAutoresizingMaskIntoConstraints = false

        underlay.material = .sidebar
        underlay.blendingMode = .behindWindow
        underlay.state = .followsWindowActiveState
        underlay.translatesAutoresizingMaskIntoConstraints = false
        tint.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(underlay)
        root.addSubview(tint)

        cardShadow.cornerCurve = .continuous
        cardShadow.cornerRadius = Style.Metrics.contentCornerRadius
        cardShadow.shadowOffset = CGSize(width: 0, height: -Style.Metrics.cardShadowOffset)
        cardShadow.shadowRadius = Style.Metrics.cardShadowRadius
        cardShadow.shadowOpacity = 1
        cardShadow.actions = ["bounds": NSNull(), "position": NSNull(), "shadowPath": NSNull()]

        card.wantsLayer = true
        card.layer?.cornerRadius = Style.Metrics.contentCornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(card)
        root.layer?.addSublayer(cardShadow)
        root.card = card
        root.cardShadow = cardShadow

        buildHeader()
        for sub in [header, chat, models] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(sub)
        }

        let gutter = Style.Metrics.elementSeparation
        let windowEdge = card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -gutter)
        windowEdgeConstraint = windowEdge
        NSLayoutConstraint.activate([
            underlay.topAnchor.constraint(equalTo: root.topAnchor),
            underlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            underlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            underlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            tint.topAnchor.constraint(equalTo: root.topAnchor),
            tint.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tint.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            // The side facing the page is flush: the page card keeps a gutter
            // of its own there.
            card.topAnchor.constraint(equalTo: root.topAnchor, constant: Style.Metrics.contentTopInset),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -gutter),
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            windowEdge,

            header.topAnchor.constraint(equalTo: card.topAnchor),
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Style.Metrics.topBarHeight),

            chat.topAnchor.constraint(equalTo: header.bottomAnchor),
            chat.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            chat.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            chat.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            models.topAnchor.constraint(equalTo: header.bottomAnchor),
            models.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            models.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            models.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        root.onAppearanceChange = { [weak self] in self?.updateCardColours() }
        view = root
        updateCardColours()
        updateGutters()

        chat.session = session
        chat.onNeedsSetup = { [weak self] in
            guard let self else { return }
            self.models.edit(AssistantConfigStore.selected)
            self.showModels(true)
        }
        models.onDone = { [weak self] in self?.showModels(false) }
        session.onChange = { [weak self] in self?.chat.render() }
        NotificationCenter.default.addObserver(forName: .assistantModelsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateModelButton() }
        }
        updateModelButton()
        // No usable model yet: start on the setup page rather than a chat
        // that can only answer with an error.
        showModels(!AssistantConfigStore.allModels.contains(where: AssistantConfigStore.isReady))
        chat.render()
    }

    override func viewWillLayout() {
        super.viewWillLayout()
        updateGutters()
    }

    func focusInput() {
        if models.isHidden { chat.focusInput() }
    }

    // MARK: - The space's colour, as the strip around the page card wears it

    var spaceWash: NSColor? {
        get { tint.wash }
        set { tint.wash = newValue }
    }

    var spaceGradient: WashGradient? {
        get { tint.gradientWash }
        set { tint.gradientWash = newValue }
    }

    func showSpaceWash(_ wash: NSColor?, animatedOver duration: TimeInterval) {
        tint.transitionDuration = duration
        tint.wash = wash
        tint.transitionDuration = 0
        tint.show(wash, animatedOver: duration)
    }

    func showSpaceGradient(_ gradient: WashGradient?, animatedOver duration: TimeInterval) {
        tint.transitionDuration = duration
        tint.gradientWash = gradient
        tint.transitionDuration = 0
    }

    func blendSpaceWash(toward other: NSColor?, fraction: CGFloat) {
        tint.blend(toward: other, fraction: fraction)
    }

    /// Between the page and the window edge the card keeps the gutter; between
    /// the page and a trailing sidebar, the sidebar is the margin.
    private func updateGutters() {
        let sidebarIsTrailing = Settings.shared.sidebarPosition == .trailing
        windowEdgeConstraint?.constant = sidebarIsTrailing ? 0 : -Style.Metrics.elementSeparation
    }

    private func updateCardColours() {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.backgroundColor = Style.Colors.pageFill.cgColor
            card.layer?.borderColor = Style.Colors.hairline.cgColor
            card.layer?.borderWidth = Style.Metrics.hairline
            cardShadow.shadowColor = Style.Colors.cardShadow.cgColor
        }
    }

    // MARK: - Header

    private func buildHeader() {
        let icon = NSImageView(image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)!)
        icon.contentTintColor = Style.Colors.secondaryText
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.setAccessibilityElement(false)

        modelButton.isBordered = false
        modelButton.bezelStyle = .accessoryBarAction
        modelButton.imagePosition = .imageTrailing
        modelButton.target = self
        modelButton.action = #selector(showModelMenu)
        modelButton.toolTip = "Choose a model"
        modelButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let newChat = IconButton(symbolName: "square.and.pencil", label: "New Chat", side: 22)
        newChat.setClickHandler { [weak self] in
            self?.showModels(false)
            self?.session.reset()
            self?.chat.focusInput()
        }
        let settings = IconButton(symbolName: "slider.horizontal.3", label: "Models and Keys", side: 22)
        settings.setClickHandler { [weak self] in
            guard let self else { return }
            if self.models.isHidden { self.models.edit(AssistantConfigStore.selected) }
            self.showModels(self.models.isHidden)
        }
        let close = IconButton(symbolName: "xmark", label: "Close Panel", side: 22)
        close.setClickHandler { [weak self] in self?.onClose?() }

        let separator = NSBox()
        separator.boxType = .separator

        let titleStack = NSStackView(views: [icon, modelButton])
        titleStack.orientation = .horizontal
        titleStack.alignment = .centerY
        titleStack.spacing = 4
        let actionStack = NSStackView(views: [newChat, settings, close])
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = 2

        for sub in [titleStack, actionStack, separator] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16),
            titleStack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            titleStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: actionStack.leadingAnchor, constant: -6),
            actionStack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
            actionStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])
    }

    private func updateModelButton() {
        let model = AssistantConfigStore.selected
        modelButton.attributedTitle = NSAttributedString(string: model.name, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: Style.Colors.secondaryText,
        ])
        modelButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        modelButton.contentTintColor = Style.Colors.tertiaryText
    }

    @objc private func showModelMenu() {
        let menu = NSMenu()
        let selected = AssistantConfigStore.selected
        var lastFormat: AssistantAPIFormat?
        for model in AssistantConfigStore.allModels {
            if let lastFormat, lastFormat != model.format { menu.addItem(.separator()) }
            lastFormat = model.format
            let item = NSMenuItem(title: model.name, action: #selector(chooseModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model.id.uuidString
            item.state = model.id == selected.id ? .on : .off
            if !AssistantConfigStore.isReady(model) {
                item.attributedTitle = NSAttributedString(string: "\(model.name)  —  needs a key", attributes: [
                    .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor,
                ])
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let add = NSMenuItem(title: "Add a Model…", action: #selector(addModel), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        let manage = NSMenuItem(title: "Models and Keys…", action: #selector(manageModels), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: modelButton.bounds.maxY + 4), in: modelButton)
    }

    @objc private func chooseModel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let model = AssistantConfigStore.allModels.first(where: { $0.id.uuidString == raw }) else { return }
        AssistantConfigStore.selected = model
        if !AssistantConfigStore.isReady(model) {
            models.edit(model)
            showModels(true)
        }
    }

    @objc private func addModel() {
        showModels(true)
        models.startAdding()
    }

    @objc private func manageModels() {
        models.edit(AssistantConfigStore.selected)
        showModels(true)
    }

    private func showModels(_ show: Bool) {
        if show { models.reload() }
        models.isHidden = !show
        chat.isHidden = show
        if !show { chat.focusInput() }
    }
}

// MARK: - Chat

@MainActor
private final class AssistantChatView: NSView {
    weak var session: AssistantSession?
    var onNeedsSetup: (() -> Void)?

    private let transcript = NSStackView()
    private let scroll = NSScrollView()
    private let emptyState = NSStackView()
    private let composer = NSView()
    private let input = ComposerField()
    private let sendButton = SendButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        transcript.orientation = .vertical
        transcript.alignment = .leading
        transcript.spacing = 12
        transcript.edgeInsets = NSEdgeInsets(top: 16, left: 14, bottom: 16, right: 14)
        transcript.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(transcript)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        NSLayoutConstraint.activate([
            transcript.topAnchor.constraint(equalTo: document.topAnchor),
            transcript.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            transcript.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        buildEmptyState()
        buildComposer()
        for sub in [scroll, emptyState, composer] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),

            emptyState.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: -10),
            emptyState.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            emptyState.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),

            composer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            composer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            composer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("AssistantChatView is created in code only")
    }

    func focusInput() {
        window?.makeFirstResponder(input)
    }

    private func buildEmptyState() {
        let title = NSTextField(labelWithString: "Ask about this page")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = Style.Colors.primaryText
        let body = NSTextField(wrappingLabelWithString: "Summarize it, pull something out of it, or say what to do — the assistant clicks, types and scrolls while you watch, and you can take over at any point.")
        body.font = .systemFont(ofSize: 12)
        body.textColor = Style.Colors.secondaryText
        body.alignment = .center

        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 6
        emptyState.setViews([title, body], in: .top)
        emptyState.setCustomSpacing(16, after: body)
        for suggestion in ["Summarize this page", "What are the key points?", "Find the contact details"] {
            let chip = ChipButton(title: suggestion) { [weak self] in self?.send(suggestion) }
            emptyState.addView(chip, in: .top)
        }
    }

    private func buildComposer() {
        composer.wantsLayer = true
        composer.layer?.cornerRadius = 10
        composer.layer?.cornerCurve = .continuous
        composer.layer?.borderWidth = 1

        input.placeholderString = "Ask, or tell it what to do"
        input.onSubmit = { [weak self] in self?.sendOrStop() }
        input.translatesAutoresizingMaskIntoConstraints = false
        sendButton.target = self
        sendButton.action = #selector(sendOrStop)
        sendButton.translatesAutoresizingMaskIntoConstraints = false

        composer.addSubview(input)
        composer.addSubview(sendButton)
        NSLayoutConstraint.activate([
            input.topAnchor.constraint(equalTo: composer.topAnchor, constant: 9),
            input.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -9),
            input.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 11),
            input.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),
            input.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
            sendButton.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -6),
            sendButton.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -6),
        ])
        updateComposerColours()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateComposerColours()
        render()
    }

    /// The address bar's plate and hairline.
    private func updateComposerColours() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            composer.layer?.backgroundColor = Style.Colors.fieldFill.cgColor
            composer.layer?.borderColor = Style.Colors.fieldStroke.cgColor
        }
    }

    func render() {
        guard let session else { return }
        sendButton.isRunning = session.isRunning
        emptyState.isHidden = !session.items.isEmpty

        var rows = session.items.map(Self.row(for:))
        if session.isRunning { rows.append(ThinkingDots()) }
        transcript.setViews(rows, in: .top)
        for (index, row) in rows.enumerated() {
            if index < session.items.count, case .user = session.items[index] {
                row.widthAnchor.constraint(equalTo: transcript.widthAnchor, constant: -28).isActive = true
            } else {
                row.widthAnchor.constraint(lessThanOrEqualTo: transcript.widthAnchor, constant: -28).isActive = true
            }
        }

        layoutSubtreeIfNeeded()
        if let document = scroll.documentView {
            let bottom = max(0, document.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private static func row(for item: AssistantChatItem) -> NSView {
        switch item {
        case .user(let text):
            // The user's own words, right-aligned on a quiet plate.
            let bubble = Plate(text: NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: Style.Colors.primaryText,
            ]))
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let line = NSStackView(views: [spacer, bubble])
            line.orientation = .horizontal
            bubble.widthAnchor.constraint(lessThanOrEqualTo: line.widthAnchor, multiplier: 0.86).isActive = true
            return line
        case .assistant(let text):
            let label = NSTextField(labelWithAttributedString: markdown(text))
            label.isSelectable = true
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return label
        case .step(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return StepRow(text: trimmed, symbol: trimmed.hasPrefix("→") ? "cursorarrow.rays" : "ellipsis", isError: false)
        case .error(let text):
            return StepRow(text: text, symbol: "exclamationmark.triangle.fill", isError: true)
        }
    }

    private static func markdown(_ text: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? NSMutableAttributedString(AttributedString(markdown: text, options: options)))
            ?? NSMutableAttributedString(string: text)
        let range = NSRange(location: 0, length: parsed.length)
        parsed.addAttribute(.foregroundColor, value: Style.Colors.primaryText, range: range)
        parsed.enumerateAttribute(.font, in: range) { value, sub, _ in
            if value == nil { parsed.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: sub) }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        parsed.addAttribute(.paragraphStyle, value: paragraph, range: range)
        return parsed
    }

    @objc private func sendOrStop() {
        guard let session else { return }
        if session.isRunning {
            session.stop()
            return
        }
        let text = input.stringValue
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        input.stringValue = ""
        send(text)
    }

    private func send(_ text: String) {
        guard let session else { return }
        guard AssistantConfigStore.isReady(AssistantConfigStore.selected) else {
            onNeedsSetup?()
            return
        }
        session.send(text)
    }
}

// MARK: - Models and keys

/// Where the user picks, adds and edits models, and gives each server its key.
@MainActor
private final class AssistantModelsView: NSView {
    var onDone: (() -> Void)?

    private let list = NSStackView()
    private let editor = NSStackView()
    private let editorTitle = NSTextField(labelWithString: "")
    private let preset = NSPopUpButton()
    private let nameField = PlateField(placeholder: "My model")
    private let format = NSSegmentedControl(labels: AssistantAPIFormat.allCases.map(\.displayName), trackingMode: .selectOne, target: nil, action: nil)
    private let urlField = PlateField(placeholder: "https://…")
    private let modelField = PlateField(placeholder: "Model ID")
    private let keyField = PlateField(placeholder: "API key", secure: true)
    private let keyHint = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let deleteButton = NSButton(title: "Delete Model", target: nil, action: nil)
    private let useButton = NSButton(title: "Save and Use", target: nil, action: nil)
    private var editing: AssistantModelConfig?
    private var isNew = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 16, left: 14, bottom: 20, right: 14)
        column.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(column)

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2

        let add = ChipButton(title: "Add a Model", symbol: "plus") { [weak self] in self?.startAdding() }
        let done = ChipButton(title: "Back to Chat", symbol: "bubble.left") { [weak self] in self?.onDone?() }
        let buttons = NSStackView(views: [add, done])
        buttons.spacing = 6
        buttons.distribution = .gravityAreas

        let divider = NSBox()
        divider.boxType = .separator

        buildEditor()

        column.setViews([Self.heading("Models"), list, buttons, divider, editor], in: .top)
        column.setCustomSpacing(14, after: buttons)
        column.setCustomSpacing(14, after: divider)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.topAnchor.constraint(equalTo: document.topAnchor),
            column.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -28),
            divider.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -28),
            editor.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -28),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("AssistantModelsView is created in code only")
    }

    private static func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = Style.Colors.tertiaryText
        return label
    }

    private static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = Style.Colors.secondaryText
        return label
    }

    private func buildEditor() {
        editor.orientation = .vertical
        editor.alignment = .leading
        editor.spacing = 6

        editorTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        editorTitle.textColor = Style.Colors.primaryText

        preset.controlSize = .small
        preset.font = .systemFont(ofSize: 11.5)
        preset.addItem(withTitle: "Start from a provider…")
        for item in AssistantProviderPreset.all { preset.addItem(withTitle: item.name) }
        preset.target = self
        preset.action = #selector(presetChosen)

        format.controlSize = .small
        format.segmentStyle = .rounded
        format.target = self
        format.action = #selector(formatChosen)

        // Wrapping labels that never set the panel's width: long text wraps
        // to whatever width the card has.
        for label in [keyHint, status] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.isSelectable = false
        }
        keyHint.font = .systemFont(ofSize: 11)
        keyHint.textColor = Style.Colors.tertiaryText
        status.font = .systemFont(ofSize: 11.5, weight: .medium)

        useButton.bezelStyle = .push
        useButton.keyEquivalent = "\r"
        useButton.target = self
        useButton.action = #selector(save)
        deleteButton.isBordered = false
        deleteButton.contentTintColor = .systemRed
        deleteButton.font = .systemFont(ofSize: 11.5)
        deleteButton.target = self
        deleteButton.action = #selector(deleteModel)
        let actions = NSStackView(views: [useButton, deleteButton])
        actions.spacing = 10

        editor.setViews([
            editorTitle, preset,
            Self.caption("Name"), nameField,
            Self.caption("Format"), format,
            Self.caption("Base URL"), urlField,
            Self.caption("Model"), modelField,
            Self.caption("API key"), keyField, keyHint,
            status, actions,
        ], in: .top)
        editor.setCustomSpacing(10, after: editorTitle)
        editor.setCustomSpacing(12, after: preset)
        for view in [nameField, format, urlField, modelField, keyField] as [NSView] {
            editor.setCustomSpacing(10, after: view)
        }
        for view in [nameField, urlField, modelField, keyField, keyHint, status] as [NSView] {
            view.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
        }
    }

    func reload() {
        let selected = AssistantConfigStore.selected
        list.setViews(AssistantConfigStore.allModels.map { model in
            let row = ModelRow(model: model, isSelected: model.id == selected.id, isEditing: model.id == editing?.id)
            row.onClick = { [weak self] in self?.edit(model) }
            return row
        }, in: .top)
        for row in list.views { row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        if editing == nil {
            editing = selected
            fill(from: selected)
        }
    }

    func edit(_ model: AssistantModelConfig) {
        editing = model
        isNew = false
        fill(from: model)
        reload()
    }

    func startAdding() {
        startAdding(from: 1)
    }

    /// A new model filled in from a provider preset.
    private func startAdding(from presetIndex: Int) {
        let start = AssistantProviderPreset.all[presetIndex]
        let model = AssistantModelConfig(id: UUID(), name: start.name == "Custom" ? "" : start.name,
                                         format: start.format, baseURL: start.baseURL, model: "")
        editing = model
        isNew = true
        fill(from: model)
        preset.selectItem(at: presetIndex + 1)
        modelField.placeholder = start.modelHint
        reload()
        window?.makeFirstResponder(modelField.field)
    }

    private func fill(from model: AssistantModelConfig) {
        editorTitle.stringValue = isNew ? "New model" : model.name
        nameField.stringValue = model.name
        format.selectedSegment = AssistantAPIFormat.allCases.firstIndex(of: model.format) ?? 0
        urlField.stringValue = model.baseURL
        modelField.stringValue = model.model
        keyField.stringValue = ""
        let hasKey = AssistantConfigStore.key(for: model) != nil
        keyField.placeholder = hasKey ? "Saved in your Keychain — type to replace" : (model.isLocal ? "Not needed for a model on this Mac" : "Paste the key")
        keyHint.stringValue = "Kept in your Mac's Keychain and sent only to \(URL(string: model.baseURL)?.host() ?? "the model's server"). One key covers every model on the same server."
        status.stringValue = ""
        preset.selectItem(at: 0)
        // A built-in model is fixed apart from its key; choosing another
        // format or provider on it starts a new model instead.
        let editable = !model.isBuiltIn
        for field in [nameField, urlField, modelField] { field.isEditable = editable }
        deleteButton.isHidden = !editable || isNew
        useButton.title = isNew ? "Add and Use" : "Save and Use"
    }

    @objc private func formatChosen() {
        let chosen = AssistantAPIFormat.allCases[max(0, format.selectedSegment)]
        guard let model = editing else { return }
        guard !model.isBuiltIn else {
            return startAdding(from: AssistantProviderPreset.all.firstIndex { $0.format == chosen } ?? 1)
        }
        // Swap a preset's address for the other format's, but keep one the user typed.
        if let current = AssistantProviderPreset.all.first(where: { $0.baseURL == urlField.stringValue }),
           current.format != chosen,
           let other = AssistantProviderPreset.all.first(where: { $0.format == chosen }) {
            urlField.stringValue = other.baseURL
            modelField.placeholder = other.modelHint
        }
    }

    @objc private func presetChosen() {
        let index = preset.indexOfSelectedItem - 1
        guard AssistantProviderPreset.all.indices.contains(index) else { return }
        if editing?.isBuiltIn == true { return startAdding(from: index) }
        let chosen = AssistantProviderPreset.all[index]
        format.selectedSegment = AssistantAPIFormat.allCases.firstIndex(of: chosen.format) ?? 0
        urlField.stringValue = chosen.baseURL
        modelField.placeholder = chosen.modelHint
        if isNew { nameField.stringValue = chosen.name == "Custom" ? "" : chosen.name }
    }

    @objc private func save() {
        guard var model = editing else { return }
        if !model.isBuiltIn {
            let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            let modelID = modelField.stringValue.trimmingCharacters(in: .whitespaces)
            let base = urlField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !modelID.isEmpty else { return fail("Enter the model ID the server expects.") }
            guard let url = URL(string: base), url.scheme?.hasPrefix("http") == true, url.host() != nil else {
                return fail("Enter the server's base URL, such as https://api.openai.com/v1.")
            }
            model.name = name.isEmpty ? modelID : name
            model.model = modelID
            model.baseURL = base
            model.format = AssistantAPIFormat.allCases[max(0, format.selectedSegment)]
        }
        let key = keyField.stringValue
        if !key.isEmpty, !AssistantConfigStore.setKey(key, for: model) {
            return fail("Couldn't save the key to the Keychain.")
        }
        if !model.isLocal, AssistantConfigStore.key(for: model) == nil {
            return fail("Add an API key for this server, or point it at a model on this Mac.")
        }
        if !model.isBuiltIn { AssistantConfigStore.save(model) }
        AssistantConfigStore.selected = model
        editing = model
        isNew = false
        fill(from: model)
        reload()
        onDone?()
    }

    @objc private func deleteModel() {
        guard let model = editing, !model.isBuiltIn else { return }
        AssistantConfigStore.remove(model)
        editing = nil
        reload()
    }

    private func fail(_ message: String) {
        status.textColor = .systemRed
        status.stringValue = message
    }
}

/// A model in the list: name, where it runs, and whether it is ready.
@MainActor
private final class ModelRow: NSView {
    var onClick: (() -> Void)?
    private let isEditing: Bool

    init(model: AssistantModelConfig, isSelected: Bool, isEditing: Bool) {
        self.isEditing = isEditing
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous

        let name = NSTextField(labelWithString: model.name)
        name.font = .systemFont(ofSize: 12.5, weight: isSelected ? .semibold : .regular)
        name.textColor = Style.Colors.primaryText
        name.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: "\(model.format.displayName) · \(model.model)")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = Style.Colors.tertiaryText
        detail.lineBreakMode = .byTruncatingTail
        let texts = NSStackView(views: [name, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let ready = AssistantConfigStore.isReady(model)
        let badge = NSTextField(labelWithString: isSelected ? "In use" : (ready ? "" : "Needs key"))
        badge.font = .systemFont(ofSize: 10.5, weight: .semibold)
        badge.textColor = isSelected ? Style.Colors.kylmoraBlue : .systemOrange
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [texts, spacer, badge])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 9, bottom: 6, right: 9)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        updateColours()
    }

    required init?(coder: NSCoder) {
        fatalError("ModelRow is created in code only")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColours()
    }

    private func updateColours() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isEditing ? Style.Colors.controlFill.cgColor : NSColor.clear.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - Small parts

/// A text field on the panel-control plate, the way Kylmora's sheets draw them.
@MainActor
private final class PlateField: NSView {
    let field: NSTextField
    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }
    var placeholder: String {
        get { field.placeholderString ?? "" }
        set { field.placeholderString = newValue }
    }
    var isEditable: Bool {
        get { field.isEditable }
        set {
            field.isEditable = newValue
            field.isSelectable = true
            field.textColor = newValue ? Style.Colors.primaryText : Style.Colors.secondaryText
        }
    }

    init(placeholder: String, secure: Bool = false) {
        field = secure ? NSSecureTextField() : NSTextField()
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = secure ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12.5)
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateColours()
    }

    required init?(coder: NSCoder) {
        fatalError("PlateField is created in code only")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColours()
    }

    private func updateColours() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Style.Colors.controlFill.cgColor
        }
    }
}

/// A quiet pill button on the control plate, brighter under the pointer.
@MainActor
private final class ChipButton: NSView {
    private let action: () -> Void
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { updateColours() } }

    init(title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = Style.Colors.primaryText
        var views: [NSView] = []
        if let symbol {
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
            icon.symbolConfiguration = .init(pointSize: 10.5, weight: .semibold)
            icon.contentTintColor = Style.Colors.secondaryText
            views.append(icon)
        }
        views.append(label)
        let stack = NSStackView(views: views)
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        updateColours()
    }

    required init?(coder: NSCoder) {
        fatalError("ChipButton is created in code only")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColours()
    }

    private func updateColours() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (hovered ? Style.Colors.controlHoverFill : Style.Colors.controlFill).cgColor
        }
    }
}

/// The send button: Kylmora's blue disc with an arrow, a stop square while
/// the model is working.
@MainActor
private final class SendButton: NSButton {
    var isRunning = false { didSet { update() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = 12
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        update()
    }

    required init?(coder: NSCoder) {
        fatalError("SendButton is created in code only")
    }

    private func update() {
        image = NSImage(systemSymbolName: isRunning ? "stop.fill" : "arrow.up", accessibilityDescription: isRunning ? "Stop" : "Send")?
            .withSymbolConfiguration(.init(pointSize: isRunning ? 9 : 11, weight: .bold))
        contentTintColor = .white
        layer?.backgroundColor = (isRunning ? NSColor.secondaryLabelColor : Style.Colors.kylmoraBlue).cgColor
        toolTip = isRunning ? "Stop" : "Send"
    }
}

/// The message field: Return sends, Shift-Return starts a new line.
@MainActor
private final class ComposerField: NSTextField, NSTextFieldDelegate {
    var onSubmit: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: 13)
        usesSingleLineMode = false
        cell?.wraps = true
        cell?.isScrollable = false
        maximumNumberOfLines = 6
        delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("ComposerField is created in code only")
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            textView.insertNewlineIgnoringFieldEditor(nil)
        } else {
            onSubmit?()
        }
        return true
    }
}

/// The user's message on the control plate.
@MainActor
private final class Plate: NSView {
    init(text: NSAttributedString) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        let label = NSTextField(labelWithAttributedString: text)
        label.isSelectable = true
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
        ])
        updateColours()
    }

    required init?(coder: NSCoder) {
        fatalError("Plate is created in code only")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColours()
    }

    private func updateColours() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Style.Colors.controlFill.cgColor
        }
    }
}

/// A step or a problem: a small symbol and a line of secondary text.
@MainActor
private final class StepRow: NSStackView {
    init(text: String, symbol: String, isError: Bool) {
        super.init(frame: .zero)
        let tint: NSColor = isError ? .systemRed : Style.Colors.tertiaryText
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        icon.contentTintColor = tint
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let shown = text.hasPrefix("→") ? String(text.dropFirst()).trimmingCharacters(in: .whitespaces) : text
        let label = NSTextField(wrappingLabelWithString: shown)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = isError ? .systemRed : Style.Colors.secondaryText
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        orientation = .horizontal
        alignment = .firstBaseline
        spacing = 6
        setViews([icon, label], in: .leading)
    }

    required init?(coder: NSCoder) {
        fatalError("StepRow is created in code only")
    }
}

/// Three dots that breathe while the model works.
@MainActor
private final class ThinkingDots: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 10))
        wantsLayer = true
        for index in 0..<3 {
            let dot = CALayer()
            dot.frame = CGRect(x: CGFloat(index) * 9, y: 2, width: 5, height: 5)
            dot.cornerRadius = 2.5
            dot.backgroundColor = NSColor.tertiaryLabelColor.cgColor
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.25
            pulse.toValue = 1
            pulse.duration = 0.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.beginTime = CACurrentMediaTime() + Double(index) * 0.2
            dot.add(pulse, forKey: "pulse")
            layer?.addSublayer(dot)
        }
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 10).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("ThinkingDots is created in code only")
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
