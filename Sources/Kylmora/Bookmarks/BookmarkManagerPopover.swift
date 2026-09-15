import AppKit
import Foundation

/// A comprehensive, native manager popover for Bookmarks (search, tags, duplicate cleanup)
/// and local Full-Text History search.
@MainActor
final class BookmarkManagerPopover: NSPopover {
    private let managerController: BookmarkManagerViewController

    init(session: BrowserSession? = nil, initialMode: BookmarkManagerViewController.Mode = .bookmarks) {
        self.managerController = BookmarkManagerViewController(session: session, initialMode: initialMode)
        super.init()
        self.contentViewController = managerController
        self.behavior = .transient
        self.contentSize = NSSize(width: 500, height: 560)
    }

    required init?(coder: NSCoder) {
        fatalError("BookmarkManagerPopover is created in code only")
    }
}

@MainActor
final class BookmarkManagerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    enum Mode: Int {
        case bookmarks = 0
        case historyFTS = 1
    }

    private let session: BrowserSession?
    private var currentMode: Mode = .bookmarks

    private let modeSegment = NSSegmentedControl(labels: ["Bookmarks", "History Full-Text"], trackingMode: .selectOne, target: nil, action: nil)
    private let cleanupDuplicatesButton = NSButton(title: "Clean Duplicates", target: nil, action: nil)
    private let searchField = NSSearchField()
    private let tagFilterControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "No matching items found")

    private var displayedBookmarks: [Bookmark] = []
    private var displayedHistory: [FullTextHistoryResult] = []
    private var availableTags: [String] = []
    private var selectedTag: String? = nil

    private var sessionObserver: Any?

    init(session: BrowserSession? = nil, initialMode: Mode = .bookmarks) {
        self.session = session
        self.currentMode = initialMode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("BookmarkManagerViewController is created in code only")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 560))
        view = container

        // Top bar: Mode Segment + Clean Duplicates
        modeSegment.selectedSegment = currentMode.rawValue
        modeSegment.target = self
        modeSegment.action = #selector(modeChanged)

        cleanupDuplicatesButton.bezelStyle = .rounded
        cleanupDuplicatesButton.font = .systemFont(ofSize: 11)
        cleanupDuplicatesButton.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Clean Duplicates")
        cleanupDuplicatesButton.imagePosition = .imageLeading
        cleanupDuplicatesButton.target = self
        cleanupDuplicatesButton.action = #selector(cleanupDuplicatesClicked)

        let topRow = NSStackView(views: [modeSegment, NSView(), cleanupDuplicatesButton])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY

        // Filter Controls: Search field + Tag dropdown
        searchField.placeholderString = "Search bookmarks, folders, or #tags\u{2026}"
        searchField.target = self
        searchField.action = #selector(searchChanged)

        tagFilterControl.target = self
        tagFilterControl.action = #selector(tagFilterChanged)
        tagFilterControl.font = .systemFont(ofSize: 12)

        let filterRow = NSStackView(views: [searchField, tagFilterControl])
        filterRow.orientation = .horizontal
        filterRow.spacing = 8

        // Table View
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MainColumn"))
        column.width = 470
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 64
        tableView.selectionHighlightStyle = .regular
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.isHidden = true

        let stack = NSStackView(views: [topRow, filterRow, scrollView])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        container.addSubview(emptyLabel)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])

        updateModeUI()
        reloadContent()
    }

    private func updateModeUI() {
        if currentMode == .bookmarks {
            searchField.placeholderString = "Search bookmarks by title, url, or #tag\u{2026}"
            cleanupDuplicatesButton.isHidden = false
            tagFilterControl.isHidden = false
            tableView.rowHeight = 68
        } else {
            searchField.placeholderString = "Full-text search across visited page contents\u{2026}"
            cleanupDuplicatesButton.isHidden = true
            tagFilterControl.isHidden = true
            tableView.rowHeight = 76
        }
    }

    @objc private func modeChanged() {
        currentMode = Mode(rawValue: modeSegment.selectedSegment) ?? .bookmarks
        updateModeUI()
        reloadContent()
    }

    @objc private func searchChanged() {
        reloadContent()
    }

    @objc private func tagFilterChanged() {
        let selectedTitle = tagFilterControl.titleOfSelectedItem ?? "All Tags"
        if selectedTitle == "All Tags" {
            selectedTag = nil
        } else {
            selectedTag = selectedTitle.replacingOccurrences(of: "#", with: "")
        }
        reloadContent()
    }

    @objc private func cleanupDuplicatesClicked() {
        guard let session else { return }
        Task {
            let removed = await session.cleanupDuplicateBookmarks()
            if removed > 0 {
                session.showToast?(Toast(
                    symbolName: "sparkles",
                    message: "Cleaned up \(removed) duplicate bookmark\(removed == 1 ? "" : "s")",
                    identity: "duplicate-bookmarks-cleaned"
                ))
            } else {
                session.showToast?(Toast(
                    symbolName: "checkmark",
                    message: "No duplicate bookmarks found",
                    identity: "no-duplicate-bookmarks"
                ))
            }
            reloadContent()
        }
    }

    func reloadContent() {
        guard let session else { return }
        let query = searchField.stringValue

        Task {
            if currentMode == .bookmarks {
                let tags = await session.allBookmarkTags()
                self.availableTags = tags
                updateTagMenu()

                let results = await session.searchBookmarks(query: query, tag: selectedTag)
                self.displayedBookmarks = results
                self.emptyLabel.stringValue = query.isEmpty ? "No Bookmarks Saved" : "No Bookmarks Matching \"\(query)\""
                self.emptyLabel.isHidden = !results.isEmpty
                self.tableView.reloadData()
            } else {
                guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                    self.displayedHistory = []
                    self.emptyLabel.stringValue = "Type keywords to search page contents"
                    self.emptyLabel.isHidden = false
                    self.tableView.reloadData()
                    return
                }

                let results = await session.searchHistoryFullText(query: query)
                self.displayedHistory = results
                self.emptyLabel.stringValue = "No History Content Matching \"\(query)\""
                self.emptyLabel.isHidden = !results.isEmpty
                self.tableView.reloadData()
            }
        }
    }

    private func updateTagMenu() {
        tagFilterControl.removeAllItems()
        tagFilterControl.addItem(withTitle: "All Tags")
        for tag in availableTags {
            tagFilterControl.addItem(withTitle: "#\(tag)")
        }
        if let selectedTag, availableTags.contains(selectedTag) {
            tagFilterControl.selectItem(withTitle: "#\(selectedTag)")
        } else {
            tagFilterControl.selectItem(withTitle: "All Tags")
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        currentMode == .bookmarks ? displayedBookmarks.count : displayedHistory.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if currentMode == .bookmarks {
            guard row < displayedBookmarks.count else { return nil }
            let bookmark = displayedBookmarks[row]
            return makeBookmarkCell(bookmark: bookmark, row: row)
        } else {
            guard row < displayedHistory.count else { return nil }
            let result = displayedHistory[row]
            return makeHistoryCell(result: result)
        }
    }

    private func makeBookmarkCell(bookmark: Bookmark, row: Int) -> NSView {
        let cell = NSView()

        let titleLabel = NSTextField(labelWithString: bookmark.title.isEmpty ? bookmark.url.absoluteString : bookmark.title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        var subtitleText = bookmark.url.host() ?? bookmark.url.absoluteString
        if !bookmark.folder.isEmpty {
            subtitleText += " • 📁 \(bookmark.folder)"
        }
        let subtitleLabel = NSTextField(labelWithString: subtitleText)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail

        // Tags stack
        let tagsStack = NSStackView()
        tagsStack.orientation = .horizontal
        tagsStack.spacing = 4
        for tag in bookmark.tags {
            let badge = NSTextField(labelWithString: "#\(tag)")
            badge.font = .systemFont(ofSize: 10, weight: .medium)
            badge.textColor = .systemBlue
            tagsStack.addArrangedSubview(badge)
        }

        let editTagsButton = NSButton(title: "Edit Tags", target: self, action: #selector(editTagsClicked(_:)))
        editTagsButton.bezelStyle = .inline
        editTagsButton.font = .systemFont(ofSize: 10)
        editTagsButton.tag = row
        tagsStack.addArrangedSubview(editTagsButton)

        let leftStack = NSStackView(views: [titleLabel, subtitleLabel, tagsStack])
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 2
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(leftStack)

        let deleteButton = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")!, target: self, action: #selector(deleteBookmarkClicked(_:)))
        deleteButton.isBordered = false
        deleteButton.tag = row
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(deleteButton)

        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            leftStack.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),
            leftStack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

            deleteButton.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            deleteButton.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 24),
            deleteButton.heightAnchor.constraint(equalToConstant: 24)
        ])

        return cell
    }

    private func makeHistoryCell(result: FullTextHistoryResult) -> NSView {
        let cell = NSView()

        let titleLabel = NSTextField(labelWithString: result.title.isEmpty ? result.url.absoluteString : result.title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        let urlLabel = NSTextField(labelWithString: result.url.host() ?? result.url.absoluteString)
        urlLabel.font = .systemFont(ofSize: 11)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.lineBreakMode = .byTruncatingTail

        // Clean snippet from <mark> tags into styled text
        let cleanSnippet = result.snippet
            .replacingOccurrences(of: "<mark>", with: "")
            .replacingOccurrences(of: "</mark>", with: "")
        let snippetLabel = NSTextField(labelWithString: cleanSnippet)
        snippetLabel.font = .systemFont(ofSize: 11)
        snippetLabel.textColor = .labelColor
        snippetLabel.maximumNumberOfLines = 2
        snippetLabel.lineBreakMode = .byWordWrapping

        let stack = NSStackView(views: [titleLabel, urlLabel, snippetLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])

        return cell
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0 else { return }

        let targetURL: URL
        if currentMode == .bookmarks {
            guard row < displayedBookmarks.count else { return }
            targetURL = displayedBookmarks[row].url
        } else {
            guard row < displayedHistory.count else { return }
            targetURL = displayedHistory[row].url
        }

        if NSEvent.modifierFlags.contains(.command) || session?.activeTab == nil {
            session?.newTab(url: targetURL)
        } else {
            session?.activeTab?.load(targetURL)
        }
    }

    @objc private func deleteBookmarkClicked(_ sender: NSButton) {
        let row = sender.tag
        guard row < displayedBookmarks.count, let session else { return }
        let bm = displayedBookmarks[row]
        session.removeBookmark(bm)
        reloadContent()
    }

    @objc private func editTagsClicked(_ sender: NSButton) {
        let row = sender.tag
        guard row < displayedBookmarks.count, let session else { return }
        let bm = displayedBookmarks[row]

        let alert = NSAlert()
        alert.messageText = "Edit Tags for Bookmark"
        alert.informativeText = "Enter comma-separated tags (e.g. swift, research, docs):"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.stringValue = bm.tags.joined(separator: ", ")
        alert.accessoryView = input

        if alert.runModal() == .alertFirstButtonReturn {
            let raw = input.stringValue
            let newTags = raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            Task {
                await session.setBookmarkTags(newTags, for: bm.url)
                self.reloadContent()
            }
        }
    }
}
