import AppKit
import UniformTypeIdentifiers

/// The Import pane: bring bookmarks and history over from another browser, so a
/// Safari or Chrome user can switch to Kylmora without leaving their web behind.
///
/// Pick the browser once, then each thing Kylmora can bring in -- bookmarks,
/// history -- has its own line: the guidance for that browser and a button that
/// opens the file picker aimed at the right place. Kylmora reads only the file the
/// user picks; the sandbox allows nothing else, and a browser's profile folder
/// is not somewhere to wander into unasked (D60, D62). The parsing is
/// `BookmarkImporter` and `HistoryImporter`; this pane is the guided way there.
@MainActor
final class ImportSettingsViewController: NSViewController {
    private let session: BrowserSession
    private let sourcePopUp = NSPopUpButton()

    private let bookmarksButton = NSButton(title: "Choose File\u{2026}", target: nil, action: nil)
    private let bookmarksNote = NSTextField(wrappingLabelWithString: "")
    private let bookmarksStatus = NSTextField(wrappingLabelWithString: "")

    private let historyButton = NSButton(title: "Choose File\u{2026}", target: nil, action: nil)
    private let historyNote = NSTextField(wrappingLabelWithString: "")
    private let historyStatus = NSTextField(wrappingLabelWithString: "")

    private let tabsButton = NSButton(title: "Choose File\u{2026}", target: nil, action: nil)
    private let tabsNote = NSTextField(wrappingLabelWithString: "")
    private let tabsStatus = NSTextField(wrappingLabelWithString: "")

    private let cookiesButton = NSButton(title: "Import Logins", target: nil, action: nil)
    private let cookiesNote = NSTextField(wrappingLabelWithString: "")
    private let cookiesStatus = NSTextField(wrappingLabelWithString: "")

    private let sources = BrowserImportSource.allCases

    private var selectedSource: BrowserImportSource {
        let index = sourcePopUp.indexOfSelectedItem
        return sources.indices.contains(index) ? sources[index] : .safari
    }

    init(session: BrowserSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("ImportSettingsViewController is created in code only")
    }

    override func loadView() {
        let form = SettingsForm()
        view = form
        build(in: form)
        sync()
    }

    private func build(in form: SettingsForm) {
        form.addNote("Bring your bookmarks and history over from another browser so you can pick up where you left off. Kylmora reads a file you choose \u{2014} it never opens another browser\u{2019}s data on its own.")
        form.addSeparator()

        sourcePopUp.addItems(withTitles: sources.map(\.title))
        sourcePopUp.target = self
        sourcePopUp.action = #selector(sourceChanged)
        form.addRow("Import from", SettingsForm.fill(sourcePopUp))

        form.addSeparator()
        bookmarksButton.bezelStyle = .rounded
        bookmarksButton.target = self
        bookmarksButton.action = #selector(chooseBookmarks)
        form.addRow("Bookmarks", bookmarksButton)
        form.addNote(bookmarksNote)
        form.addNote(bookmarksStatus)

        form.addSeparator()
        historyButton.bezelStyle = .rounded
        historyButton.target = self
        historyButton.action = #selector(chooseHistory)
        form.addRow("History", historyButton)
        form.addNote(historyNote)
        form.addNote(historyStatus)

        form.addSeparator()
        tabsButton.bezelStyle = .rounded
        tabsButton.target = self
        tabsButton.action = #selector(chooseTabs)
        form.addRow("Open tabs", tabsButton)
        form.addNote(tabsNote)
        form.addNote(tabsStatus)

        form.addSeparator()
        cookiesButton.bezelStyle = .rounded
        cookiesButton.target = self
        cookiesButton.action = #selector(chooseCookies)
        form.addRow("Logins", cookiesButton)
        form.addNote(cookiesNote)
        form.addNote(cookiesStatus)
    }

    @objc private func sourceChanged() { sync() }

    /// Reflects the chosen browser onto both rows: its guidance, and whether the
    /// import is possible from it at all. A fresh browser clears last time's
    /// result.
    private func sync() {
        let source = selectedSource
        bookmarksNote.stringValue = source.instructions(for: .bookmarks)
        historyNote.stringValue = source.instructions(for: .history)
        tabsNote.stringValue = source.instructions(for: .tabs)
        cookiesNote.stringValue = source.instructions(for: .cookies)
        bookmarksButton.isEnabled = source.supports(.bookmarks)
        historyButton.isEnabled = source.supports(.history)
        tabsButton.isEnabled = source.supports(.tabs)
        cookiesButton.isEnabled = source.supports(.cookies)
        bookmarksStatus.stringValue = ""
        historyStatus.stringValue = ""
        tabsStatus.stringValue = ""
        cookiesStatus.stringValue = ""
    }

    // MARK: - Picking

    private func pickFile(for kind: ImportKind) -> URL? {
        let source = selectedSource
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        switch kind {
        case .bookmarks: panel.title = "Import Bookmarks"
        case .history: panel.title = "Import History"
        case .tabs: panel.title = "Import Open Tabs"
        case .cookies: panel.title = "Import Logins" // cookies auto-read; no picker
        }
        if source.picksHTMLExport(for: kind) {
            panel.allowedContentTypes = [.html]
            panel.message = "Choose the bookmarks HTML file you exported from \(source.sentenceName)."
        } else {
            // Chromium's data files have no extension, and Firefox's are plain
            // databases/session files, so no type filter is applied.
            switch kind {
            case .bookmarks:
                panel.message = "Choose the file named \u{201c}Bookmarks\u{201d} in \(source.sentenceName)\u{2019}s profile folder."
            case .history:
                panel.message = "Choose \(source == .firefox ? "\u{201c}places.sqlite\u{201d}" : "the file named \u{201c}History\u{201d}") in \(source.sentenceName)\u{2019}s profile folder."
            case .tabs:
                panel.message = "Choose \u{201c}recovery.jsonlz4\u{201d} in your Firefox profile\u{2019}s \u{201c}sessionstore-backups\u{201d} folder."
            case .cookies:
                break // cookies are read automatically, never through this panel
            }
        }
        if let directory = source.startDirectory(for: kind) { panel.directoryURL = directory }
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Bookmarks

    @objc private func chooseBookmarks() {
        let source = selectedSource
        guard let url = pickFile(for: .bookmarks) else { return }
        guard let data = try? Data(contentsOf: url) else {
            bookmarksStatus.stringValue = "Kylmora could not read that file."
            return
        }
        let entries: [BookmarkImporter.Entry]
        do {
            entries = try BookmarkImporter.entries(in: data)
        } catch {
            bookmarksStatus.stringValue = source.picksHTMLExport(for: .bookmarks)
                ? "That is not a bookmarks HTML file Kylmora can read. Export bookmarks as HTML and try again."
                : "That is not the \u{201c}Bookmarks\u{201d} file Kylmora can read. Choose the file named \u{201c}Bookmarks\u{201d}, not a folder."
            return
        }
        guard !entries.isEmpty else {
            bookmarksStatus.stringValue = "No bookmarks were found in that file."
            return
        }
        bookmarksStatus.stringValue = "Importing \(entries.count) bookmarks\u{2026}"
        Task { [weak self] in
            let added = await self?.session.importBookmarks(entries) ?? 0
            self?.bookmarksStatus.stringValue = added > 0
                ? "Imported \(added == 1 ? "1 bookmark" : "\(added) bookmarks") from \(source.sentenceName)."
                : "No new bookmarks to import from \(source.sentenceName)."
        }
    }

    // MARK: - History

    @objc private func chooseHistory() {
        let source = selectedSource
        guard let url = pickFile(for: .history) else { return }
        let path = url.path(percentEncoded: false)
        historyStatus.stringValue = "Reading history\u{2026}"
        Task { [weak self] in
            let outcome: Result<[HistoryImporter.Visit], HistoryImporter.Failure> = await Task.detached {
                do { return .success(try HistoryImporter.visits(atPath: path)) }
                catch let failure as HistoryImporter.Failure { return .failure(failure) }
                catch { return .failure(.unreadable) }
            }.value
            guard let self else { return }
            switch outcome {
            case .failure(.unreadable):
                self.historyStatus.stringValue = "Kylmora could not read that file. If \(source.sentenceName) is open, quit it and try again."
            case .failure(.unrecognised):
                self.historyStatus.stringValue = "That is not a history database Kylmora recognises."
            case .success(let visits) where visits.isEmpty:
                self.historyStatus.stringValue = "No history was found in that file."
            case .success(let visits):
                self.historyStatus.stringValue = "Importing \(visits.count) pages\u{2026}"
                let added = await self.session.importHistory(visits)
                self.historyStatus.stringValue = added > 0
                    ? "Imported \(added == 1 ? "1 page" : "\(added) pages") of history from \(source.sentenceName)."
                    : "No history to import from \(source.sentenceName)."
            }
        }
    }

    // MARK: - Open tabs

    @objc private func chooseTabs() {
        let source = selectedSource
        guard let url = pickFile(for: .tabs), let data = try? Data(contentsOf: url) else { return }
        tabsStatus.stringValue = "Reading tabs\u{2026}"
        Task { [weak self] in
            let outcome: Result<[TabSessionImporter.Tab], TabSessionImporter.Failure> = await Task.detached {
                do { return .success(try TabSessionImporter.firefoxTabs(in: data)) }
                catch let failure as TabSessionImporter.Failure { return .failure(failure) }
                catch { return .failure(.unrecognised) }
            }.value
            guard let self else { return }
            switch outcome {
            case .failure:
                self.tabsStatus.stringValue = "That is not a Firefox session file Kylmora can read. Choose \u{201c}recovery.jsonlz4\u{201d}."
            case .success(let tabs) where tabs.isEmpty:
                self.tabsStatus.stringValue = "No open tabs were found in that file."
            case .success(let tabs):
                let added = self.session.importTabs(tabs, groupName: "\(source.sentenceName) tabs")
                self.tabsStatus.stringValue = "Opened \(added == 1 ? "1 tab" : "\(added) tabs") from \(source.sentenceName) in a new group."
            }
        }
    }

    // MARK: - Logins (cookies)

    @objc private func chooseCookies() {
        let source = selectedSource
        cookiesStatus.stringValue = "Reading logins\u{2026} allow the Keychain prompt if it appears."
        Task { [weak self] in
            let outcome: Result<[CookieImporter.Cookie], CookieImporter.Failure> = await Task.detached {
                do { return .success(try CookieImporter.cookies(from: source)) }
                catch let failure as CookieImporter.Failure { return .failure(failure) }
                catch { return .failure(.unreadable) }
            }.value
            guard let self else { return }
            switch outcome {
            case .failure(.keyUnavailable):
                self.cookiesStatus.stringValue = "Couldn\u{2019}t read \(source.sentenceName)\u{2019}s key. Click Allow when macOS asks, and make sure \(source.sentenceName) is installed."
            case .failure(.decryptFailed):
                self.cookiesStatus.stringValue = "Read \(source.sentenceName)\u{2019}s cookies but couldn\u{2019}t decrypt them \u{2014} the Keychain didn\u{2019}t release the right key (a signed build is usually needed, not an ad-hoc one)."
            case .failure(.unreadable):
                self.cookiesStatus.stringValue = "Couldn\u{2019}t read \(source.sentenceName)\u{2019}s cookies. Quit \(source.sentenceName) and try again."
            case .failure:
                self.cookiesStatus.stringValue = "\(source.sentenceName)\u{2019}s cookies aren\u{2019}t in a form Kylmora can read."
            case .success(let cookies) where cookies.isEmpty:
                self.cookiesStatus.stringValue = "No logins were found."
            case .success(let cookies):
                self.cookiesStatus.stringValue = "Importing \(cookies.count) cookies\u{2026}"
                let added = await self.session.importCookies(cookies)
                self.cookiesStatus.stringValue = "Imported \(added) logins from \(source.sentenceName) into this space. You should be signed in on those sites now."
            }
        }
    }
}
