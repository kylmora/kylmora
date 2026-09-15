import AppKit
import PDFKit

/// A PDF in a tab: a thin toolbar over a PDFKit view.
///
/// The toolbar has the things WebKit's own viewer keeps to itself: page
/// number and count, previous and next, zoom, fit to width, search with
/// a match count, rotate, thumbnails, Open in Preview and Save. Keyboard
/// paging, selection and links are PDFKit's own.
@MainActor
final class PDFDocumentView: NSView {
    private(set) var document: PDFDocument?
    private(set) var fileURL: URL?

    private let pdfView = PDFView()
    private let thumbnails = PDFThumbnailView()
    private let toolbar = NSStackView()
    private let pageField = NSTextField()
    private let pageCountLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let matchLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var thumbnailsWidth: NSLayoutConstraint!
    private var matches: [PDFSelection] = []
    private var matchIndex = 0

    /// Called when the user asks to keep the file somewhere.
    var onSave: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("PDFDocumentView is created in code only")
    }

    // MARK: - State

    /// Shows the fetch in progress for `url`.
    func showLoading(url: URL) {
        document = nil
        fileURL = nil
        pdfView.document = nil
        statusLabel.stringValue = "Loading \(url.lastPathComponent.isEmpty ? "PDF" : url.lastPathComponent)…"
        statusLabel.isHidden = false
        spinner.startAnimation(nil)
        toolbar.isHidden = true
        pdfView.isHidden = true
        thumbnails.isHidden = true
    }

    func showFailure(_ message: String) {
        spinner.stopAnimation(nil)
        statusLabel.stringValue = message
        statusLabel.isHidden = false
        toolbar.isHidden = true
        pdfView.isHidden = true
        thumbnails.isHidden = true
    }

    /// Shows `document`, read from `fileURL`.
    func show(_ document: PDFDocument, fileURL: URL) {
        self.document = document
        self.fileURL = fileURL
        spinner.stopAnimation(nil)
        statusLabel.isHidden = true
        toolbar.isHidden = false
        pdfView.isHidden = false
        thumbnails.isHidden = thumbnailsWidth.constant == 0
        pdfView.document = document
        pdfView.autoScales = true
        matches = []
        matchLabel.stringValue = ""
        searchField.stringValue = ""
        updatePageLabel()
    }

    /// Page count of what is shown, for the tab's title and tests.
    var pageCount: Int { document?.pageCount ?? 0 }

    /// The page on screen, 1-based.
    var currentPageNumber: Int {
        guard let document, let page = pdfView.currentPage else { return 0 }
        return document.index(for: page) + 1
    }

    func go(toPage number: Int) {
        guard let document, number >= 1, number <= document.pageCount, let page = document.page(at: number - 1) else { return }
        pdfView.go(to: page)
        updatePageLabel()
    }

    /// Puts the cursor in the search field, for ⌘F.
    func focusSearch() {
        window?.makeFirstResponder(searchField)
    }

    /// Finds `text` and selects the first match. Returns how many there are.
    @discardableResult
    func find(_ text: String) -> Int {
        guard let document else { return 0 }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            matches = []
            pdfView.setCurrentSelection(nil, animate: false)
            pdfView.highlightedSelections = nil
            matchLabel.stringValue = ""
            return 0
        }
        matches = document.findString(trimmed, withOptions: [.caseInsensitive])
        matchIndex = 0
        for match in matches { match.color = .systemYellow.withAlphaComponent(0.5) }
        pdfView.highlightedSelections = matches
        showCurrentMatch()
        return matches.count
    }

    func findNext() { step(by: 1) }
    func findPrevious() { step(by: -1) }

    private func step(by delta: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + delta + matches.count) % matches.count
        showCurrentMatch()
    }

    private func showCurrentMatch() {
        guard !matches.isEmpty else {
            matchLabel.stringValue = "No matches"
            return
        }
        let match = matches[matchIndex]
        pdfView.setCurrentSelection(match, animate: true)
        pdfView.scrollSelectionToVisible(nil)
        matchLabel.stringValue = "\(matchIndex + 1) of \(matches.count)"
        updatePageLabel()
    }

    // MARK: - Building

    private func build() {
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        pdfView.backgroundColor = .windowBackgroundColor
        addSubview(pdfView)

        thumbnails.translatesAutoresizingMaskIntoConstraints = false
        thumbnails.pdfView = pdfView
        thumbnails.thumbnailSize = NSSize(width: 96, height: 128)
        thumbnails.backgroundColor = .underPageBackgroundColor
        thumbnails.isHidden = true
        addSubview(thumbnails)
        thumbnailsWidth = thumbnails.widthAnchor.constraint(equalToConstant: 0)

        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 6
        toolbar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        addSubview(toolbar)

        let hairline = NSBox()
        hairline.boxType = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)

        pageField.controlSize = .small
        pageField.alignment = .right
        pageField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        pageField.widthAnchor.constraint(equalToConstant: 40).isActive = true
        pageField.target = self
        pageField.action = #selector(pageEntered)
        pageCountLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        pageCountLabel.textColor = .secondaryLabelColor

        searchField.controlSize = .small
        searchField.placeholderString = "Find in PDF"
        searchField.target = self
        searchField.action = #selector(searchEntered)
        searchField.sendsSearchStringImmediately = false
        searchField.widthAnchor.constraint(equalToConstant: 170).isActive = true
        matchLabel.font = .systemFont(ofSize: 11)
        matchLabel.textColor = .secondaryLabelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        toolbar.addArrangedSubview(button("sidebar.left", "Thumbnails", #selector(toggleThumbnails)))
        toolbar.addArrangedSubview(button("chevron.up", "Previous Page", #selector(previousPage)))
        toolbar.addArrangedSubview(button("chevron.down", "Next Page", #selector(nextPage)))
        toolbar.addArrangedSubview(pageField)
        toolbar.addArrangedSubview(pageCountLabel)
        toolbar.addArrangedSubview(button("minus.magnifyingglass", "Zoom Out", #selector(zoomOut)))
        toolbar.addArrangedSubview(button("plus.magnifyingglass", "Zoom In", #selector(zoomIn)))
        toolbar.addArrangedSubview(button("arrow.left.and.right.square", "Fit Width", #selector(fitWidth)))
        toolbar.addArrangedSubview(button("rotate.right", "Rotate", #selector(rotatePage)))
        toolbar.addArrangedSubview(spacer)
        toolbar.addArrangedSubview(searchField)
        toolbar.addArrangedSubview(matchLabel)
        toolbar.addArrangedSubview(button("chevron.backward", "Previous Match", #selector(previousMatch)))
        toolbar.addArrangedSubview(button("chevron.forward", "Next Match", #selector(nextMatch)))
        toolbar.addArrangedSubview(button("arrow.up.forward.app", "Open in Preview", #selector(openInPreview)))
        toolbar.addArrangedSubview(button("square.and.arrow.down", "Save PDF", #selector(save)))

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 34),
            hairline.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            thumbnails.topAnchor.constraint(equalTo: hairline.bottomAnchor),
            thumbnails.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumbnails.bottomAnchor.constraint(equalTo: bottomAnchor),
            thumbnailsWidth,
            pdfView.topAnchor.constraint(equalTo: hairline.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: thumbnails.trailingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20)
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView
        )
    }

    private func button(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    // MARK: - Actions

    @objc private func pageChanged() { updatePageLabel() }

    private func updatePageLabel() {
        pageField.stringValue = pageCount == 0 ? "" : String(currentPageNumber)
        pageCountLabel.stringValue = pageCount == 0 ? "" : "of \(pageCount)"
    }

    @objc private func pageEntered() {
        if let number = Int(pageField.stringValue) { go(toPage: number) } else { updatePageLabel() }
    }

    @objc private func previousPage() { pdfView.goToPreviousPage(nil) }
    @objc private func nextPage() { pdfView.goToNextPage(nil) }
    @objc private func zoomIn() { pdfView.autoScales = false; pdfView.zoomIn(nil) }
    @objc private func zoomOut() { pdfView.autoScales = false; pdfView.zoomOut(nil) }
    @objc private func fitWidth() { pdfView.autoScales = true }

    @objc private func rotatePage() {
        guard let page = pdfView.currentPage else { return }
        page.rotation = (page.rotation + 90) % 360
        pdfView.layoutDocumentView()
    }

    @objc func toggleThumbnails() {
        let showing = thumbnailsWidth.constant > 0
        thumbnailsWidth.constant = showing ? 0 : 128
        thumbnails.isHidden = showing
    }

    var showsThumbnails: Bool { thumbnailsWidth.constant > 0 }

    @objc private func searchEntered() { find(searchField.stringValue) }
    @objc private func previousMatch() { findPrevious() }
    @objc private func nextMatch() { findNext() }

    @objc private func openInPreview() {
        guard let fileURL else { return }
        NSWorkspace.shared.open(fileURL)
    }

    @objc private func save() {
        guard let fileURL, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = fileURL.lastPathComponent
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let target = panel.url else { return }
            try? FileManager.default.removeItem(at: target)
            if (try? FileManager.default.copyItem(at: fileURL, to: target)) != nil {
                self?.onSave?(target)
            }
        }
    }
}
