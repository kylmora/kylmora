import AppKit

/// The tools of the screenshot editor.
enum AnnotationTool: Int, CaseIterable {
    case crop, arrow, rectangle, ellipse, highlight, blur, text

    var title: String {
        switch self {
        case .crop: return "Crop"
        case .arrow: return "Arrow"
        case .rectangle: return "Box"
        case .ellipse: return "Circle"
        case .highlight: return "Highlight"
        case .blur: return "Blur"
        case .text: return "Text"
        }
    }

    var symbol: String {
        switch self {
        case .crop: return "crop"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .highlight: return "highlighter"
        case .blur: return "drop.halffull"
        case .text: return "textformat"
        }
    }
}

/// Where a captured screenshot is marked up before it is saved or copied.
@MainActor
final class ScreenshotEditorWindowController: NSWindowController {
    private(set) var shot: AnnotatedScreenshot
    private let canvas: AnnotationCanvas
    private let tools = NSSegmentedControl()
    private let colours = NSPopUpButton()
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    private let cropButton = NSButton(title: "Apply Crop", target: nil, action: nil)
    private let tabTitle: String?
    private let pageURL: URL?
    var onSaved: ((URL) -> Void)?
    var onCopied: (() -> Void)?

    init(image: NSImage, tabTitle: String?, pageURL: URL?) {
        shot = AnnotatedScreenshot(image: image)
        canvas = AnnotationCanvas(shot: shot)
        self.tabTitle = tabTitle
        self.pageURL = pageURL
        let size = image.size
        let fit = NSSize(width: min(1100, max(560, size.width + 40)), height: min(800, max(420, size.height + 100)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: fit), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Annotate Screenshot"
        super.init(window: window)
        window.center()
        window.isReleasedWhenClosed = false
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("ScreenshotEditorWindowController is created in code only")
    }

    private func build() {
        guard let window else { return }
        tools.segmentCount = AnnotationTool.allCases.count
        for tool in AnnotationTool.allCases {
            tools.setImage(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title), forSegment: tool.rawValue)
            tools.setToolTip(tool.title, forSegment: tool.rawValue)
            tools.setWidth(36, forSegment: tool.rawValue)
        }
        tools.selectedSegment = AnnotationTool.arrow.rawValue
        tools.target = self
        tools.action = #selector(toolChanged)

        colours.addItems(withTitles: AnnotationColor.allCases.map(\.title))
        for (index, colour) in AnnotationColor.allCases.enumerated() {
            let swatch = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                colour.nsColor.setFill()
                NSBezierPath(ovalIn: rect).fill()
                return true
            }
            colours.item(at: index)?.image = swatch
        }
        colours.target = self
        colours.action = #selector(colourChanged)

        undoButton.target = self
        undoButton.action = #selector(undo)
        undoButton.bezelStyle = .rounded
        cropButton.target = self
        cropButton.action = #selector(applyCrop)
        cropButton.bezelStyle = .rounded
        cropButton.isHidden = true

        let copy = NSButton(title: "Copy", target: self, action: #selector(copyImage))
        copy.bezelStyle = .rounded
        let save = NSButton(title: "Save to Downloads", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let saveAs = NSButton(title: "Save As\u{2026}", target: self, action: #selector(saveAs))
        saveAs.bezelStyle = .rounded

        let bar = NSStackView(views: [tools, colours, undoButton, cropButton, NSView(), copy, saveAs, save])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.drawsBackground = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        canvas.onChange = { [weak self] shot in
            self?.shot = shot
            self?.cropButton.isHidden = shot.crop == nil
        }
        canvas.tool = .arrow

        let container = NSView()
        container.addSubview(bar)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        window.contentView = container
    }

    @objc private func toolChanged() {
        canvas.tool = AnnotationTool(rawValue: tools.selectedSegment) ?? .arrow
    }

    @objc private func colourChanged() {
        canvas.color = AnnotationColor.allCases[colours.indexOfSelectedItem]
    }

    @objc func undo() { canvas.undo() }

    @objc func applyCrop() { canvas.applyCrop() }

    @objc func copyImage() {
        ScreenshotService.copyImageToClipboard(image: shot.render())
        onCopied?()
    }

    @objc func save() {
        guard let url = try? ScreenshotService.saveImageToDownloads(image: shot.render(), tabTitle: tabTitle, url: pageURL) else { return }
        onSaved?(url)
        window?.close()
    }

    @objc private func saveAs() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ScreenshotService.generateFilename(title: tabTitle ?? pageURL?.host() ?? "Page")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let target = panel.url, let self,
                  let data = ScreenshotService.pngData(from: self.shot.render()) else { return }
            try? data.write(to: target, options: .atomic)
            self.onSaved?(target)
            self.window?.close()
        }
    }
}

/// The picture and the marks being drawn on it.
@MainActor
final class AnnotationCanvas: NSView {
    private(set) var shot: AnnotatedScreenshot {
        didSet { onChange?(shot); needsDisplay = true }
    }
    var tool: AnnotationTool = .arrow
    var color: AnnotationColor = .red
    var strokeWidth: CGFloat = 4
    var onChange: ((AnnotatedScreenshot) -> Void)?

    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var history: [AnnotatedScreenshot] = []

    init(shot: AnnotatedScreenshot) {
        self.shot = shot
        super.init(frame: NSRect(origin: .zero, size: shot.size))
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("AnnotationCanvas is created in code only")
    }

    override var intrinsicContentSize: NSSize { shot.size }
    override var isFlipped: Bool { false }

    func undo() {
        guard let previous = history.popLast() else { return }
        shot = previous
        frame = NSRect(origin: .zero, size: shot.size)
    }

    /// Bakes the pending crop into a new, smaller picture.
    func applyCrop() {
        guard shot.crop != nil else { return }
        history.append(shot)
        var next = AnnotatedScreenshot(image: shot.render())
        next.crop = nil
        shot = next
        frame = NSRect(origin: .zero, size: shot.size)
        invalidateIntrinsicContentSize()
    }

    /// Adds a mark the way a drag would, for tests and scripting.
    func add(_ annotation: Annotation) {
        history.append(shot)
        shot.annotations.append(annotation)
    }

    override func draw(_ dirtyRect: NSRect) {
        shot.render().draw(in: NSRect(origin: .zero, size: shot.size))
        if let crop = shot.crop {
            NSColor.black.withAlphaComponent(0.4).setFill()
            let outside = NSBezierPath(rect: bounds)
            outside.appendRect(crop)
            outside.windingRule = .evenOdd
            outside.fill()
            NSColor.white.setStroke()
            let frame = NSBezierPath(rect: crop)
            frame.lineWidth = 1
            frame.setLineDash([4, 3], count: 2, phase: 0)
            frame.stroke()
        }
        if let start = dragStart, let current = dragCurrent, let preview = annotation(from: start, to: current) {
            var temp = AnnotatedScreenshot(image: NSImage(size: shot.size))
            temp.annotations = [preview]
            NSGraphicsContext.saveGraphicsState()
            temp.render().draw(in: NSRect(origin: .zero, size: shot.size), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func annotation(from start: CGPoint, to end: CGPoint) -> Annotation? {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        switch tool {
        case .arrow: return .arrow(from: start, to: end, color: color, width: strokeWidth)
        case .rectangle: return .rectangle(rect, color: color, width: strokeWidth)
        case .ellipse: return .ellipse(rect, color: color, width: strokeWidth)
        case .highlight: return .highlight(rect, color: color == .red ? .yellow : color)
        case .blur: return .blur(rect)
        case .crop, .text: return nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if tool == .text {
            promptForText(at: point)
            return
        }
        dragStart = point
        dragCurrent = point
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        if tool == .crop, let start = dragStart, let current = dragCurrent {
            shot.crop = CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragCurrent = nil; needsDisplay = true }
        guard let start = dragStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        if tool == .crop {
            if abs(end.x - start.x) < 4 || abs(end.y - start.y) < 4 { shot.crop = nil }
            return
        }
        guard abs(end.x - start.x) >= 3 || abs(end.y - start.y) >= 3, let mark = annotation(from: start, to: end) else { return }
        add(mark)
    }

    private func promptForText(at point: CGPoint) {
        let alert = NSAlert()
        alert.messageText = "Add text"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Text"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        add(.text(text, at: point, color: color, size: 22))
    }
}
