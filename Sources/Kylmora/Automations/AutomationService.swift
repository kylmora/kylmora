import AppKit
import Combine
import Foundation

/// Carries out one action. The session-backed performer is the real one; a
/// test records what it was asked.
@MainActor
protocol AutomationPerformer: AnyObject {
    func perform(_ action: AutomationAction, on tab: Tab?, event: AutomationEvent, rule: AutomationRule)
}

/// Owns the rules, watches the browser for the events they name, and runs
/// their actions.
@MainActor
final class AutomationService {
    static let shared = AutomationService()

    private(set) var rules: AutomationRules
    private let store: AutomationStore
    private weak var session: BrowserSession?
    private var performer: AutomationPerformer?
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var idleTimer: Timer?

    /// Tabs that were playing at the last look, so only a start fires.
    private var playing: Set<UUID> = []
    /// Downloads already reported, so a row's later changes do not refire.
    private var finishedDownloads: Set<UUID> = []
    /// For each tab, the activity stamp its idle rules last fired for; a tab
    /// touched since then may fire again.
    private var idleFired: [UUID: Date] = [:]

    var onChange: (() -> Void)?

    init(store: AutomationStore = AutomationStore()) {
        self.store = store
        self.rules = store.load()
    }

    // MARK: - Editing

    func replace(with rules: AutomationRules) {
        self.rules = rules.discardingEmptyRules()
        try? store.save(self.rules)
        onChange?()
    }

    func add(_ rule: AutomationRule) {
        var next = rules
        next.rules.append(rule)
        replace(with: next)
    }

    func update(_ rule: AutomationRule) {
        var next = rules
        if let index = next.rules.firstIndex(where: { $0.id == rule.id }) {
            next.rules[index] = rule
        } else {
            next.rules.append(rule)
        }
        replace(with: next)
    }

    func remove(id: UUID) {
        var next = rules
        next.rules.removeAll { $0.id == id }
        replace(with: next)
    }

    func exportData() throws -> Data { try store.data(for: rules) }

    // MARK: - Custom commands

    /// The rules that run by hand, as palette entries. The id carries the
    /// rule's id so the window can hand it back to `run`.
    static let commandPrefix = "automation:"

    var paletteCommands: [CommandCandidate] {
        rules.rules.filter { $0.isEnabled && $0.trigger.kind == .manual }.map { rule in
            CommandCandidate(
                id: Self.commandPrefix + rule.id.uuidString,
                title: rule.name.isEmpty ? "Untitled command" : rule.name,
                subtitle: "Custom command: " + rule.actions.map { $0.summary(spaceName: { _ in nil }) }.joined(separator: ", "),
                symbolName: "bolt.fill",
                shortcut: nil,
                keywords: ["custom", "command", "rule", "automation"] + rule.name.lowercased().split(separator: " ").map(String.init)
            )
        }
    }

    /// Runs the rule behind a palette entry on `tab`. Returns whether the id
    /// named one of ours.
    @discardableResult
    func runCommand(id: String, tab: Tab?) -> Bool {
        guard id.hasPrefix(Self.commandPrefix),
              let ruleID = UUID(uuidString: String(id.dropFirst(Self.commandPrefix.count))),
              let rule = rules.rules.first(where: { $0.id == ruleID }) else { return false }
        run(rule, on: tab)
        return true
    }

    /// Runs one rule's actions now, whatever its trigger.
    func run(_ rule: AutomationRule, on tab: Tab?) {
        guard let performer else { return }
        let event = AutomationEvent.pageLoaded(url: tab?.displayURL ?? URL(string: "about:blank")!)
        let ordered = rule.actions.filter { $0.kind != .moveToSpace } + rule.actions.filter { $0.kind == .moveToSpace }
        for action in ordered {
            if tab == nil, !action.kind.worksWithoutTab { continue }
            performer.perform(action, on: tab, event: event, rule: rule)
        }
    }

    func importRules(from data: Data) throws {
        let imported = try AutomationStore.rules(from: data)
        var next = rules
        for rule in imported.rules where !next.rules.contains(where: { $0.id == rule.id }) {
            next.rules.append(rule)
        }
        replace(with: next)
    }

    // MARK: - Watching

    /// Hooks the session's tabs, media and downloads. Idle is checked once a
    /// minute; the rest arrive as they happen.
    func start(session: BrowserSession, performer: AutomationPerformer? = nil, idleCheckInterval: TimeInterval = 60) {
        self.session = session
        self.performer = performer ?? SessionAutomationPerformer(session: session)

        session.onVisit = { [weak self] tab, url in
            self?.handle(.pageLoaded(url: url), tab: tab)
        }

        // The payload is the tab, but it is not sendable; the session's own
        // list says which tabs started playing since the last look.
        let observer = NotificationCenter.default.addObserver(
            forName: .tabMediaStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweepMedia() }
        }
        observers.append(observer)

        DownloadManager.shared.changes
            .sink { [weak self] change in
                guard let self, case .download(let download) = change,
                      download.state == .finished, !self.finishedDownloads.contains(download.id) else { return }
                self.finishedDownloads.insert(download.id)
                self.handle(.downloadFinished(fileURL: download.destination), tab: nil)
            }
            .store(in: &cancellables)

        idleTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: idleCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdleTabs() }
        }
        timer.tolerance = idleCheckInterval / 10
        idleTimer = timer
    }

    func stop() {
        idleTimer?.invalidate()
        idleTimer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        cancellables.removeAll()
        session?.onVisit = nil
    }

    /// Fires the media trigger for every tab that started playing since the
    /// last sweep, and forgets the ones that stopped.
    func sweepMedia() {
        guard let session else { return }
        var nowPlaying: Set<UUID> = []
        for tab in session.allTabs where tab.isPlayingMedia {
            nowPlaying.insert(tab.id)
            if !playing.contains(tab.id) {
                handle(.mediaStarted(url: tab.displayURL), tab: tab)
            }
        }
        playing = nowPlaying
    }

    /// Looks at every background tab and fires idle rules once per stretch
    /// of inactivity.
    func checkIdleTabs(now: Date = .now) {
        guard let session, rules.rules.contains(where: { $0.isEnabled && $0.trigger.kind == .tabIdle }) else { return }
        for tab in session.allTabs where tab.id != session.activeTab?.id {
            if idleFired[tab.id] == tab.lastActiveAt { continue }
            let minutes = Int(now.timeIntervalSince(tab.lastActiveAt) / 60)
            guard minutes >= 1 else { continue }
            let fired = handle(.tabIdle(url: tab.displayURL, idleMinutes: minutes), tab: tab)
            if fired { idleFired[tab.id] = tab.lastActiveAt }
        }
    }

    /// Runs every rule that matches. Returns whether any did.
    @discardableResult
    func handle(_ event: AutomationEvent, tab: Tab?) -> Bool {
        let firing = AutomationEngine.rules(firing: event, in: rules.rules)
        guard !firing.isEmpty, let performer else { return false }
        for rule in firing {
            // A move detaches the tab, so anything else happens first.
            let ordered = rule.actions.filter { $0.kind != .moveToSpace } + rule.actions.filter { $0.kind == .moveToSpace }
            for action in ordered {
                if tab == nil, !action.kind.worksWithoutTab { continue }
                performer.perform(action, on: tab, event: event, rule: rule)
            }
        }
        return true
    }
}

/// The real performer: acts on the session's tabs and the Mac.
@MainActor
final class SessionAutomationPerformer: AutomationPerformer {
    private weak var session: BrowserSession?

    init(session: BrowserSession) {
        self.session = session
    }

    func perform(_ action: AutomationAction, on tab: Tab?, event: AutomationEvent, rule: AutomationRule) {
        guard let session else { return }
        let url: URL? = tab?.displayURL ?? {
            if case .downloadFinished(let file) = event { return file }
            return nil
        }()
        let file: URL? = { if case .downloadFinished(let file) = event { return file }; return nil }()
        let title = tab?.displayTitle ?? file?.lastPathComponent

        switch action {
        case .moveToSpace(let id):
            guard let tab, let space = session.spaces.first(where: { $0.id == id }) else { return }
            session.move(tab, toSpace: space)
        case .pinTab:
            guard let tab else { return }
            session.pin(tab)
        case .muteTab:
            tab?.setMuted(true)
        case .keepAwake:
            tab?.setKeepsAwake(true)
        case .readerMode:
            guard let webView = tab?.currentWebView else { return }
            ReaderModeController.shared.toggleReader(in: webView, force: true)
        case .setZoom(let zoom):
            tab?.setPageZoom(zoom)
        case .archiveTab:
            guard let tab else { return }
            session.archive([tab])
        case .closeTab:
            guard let tab else { return }
            _ = session.closeTab(tab)
        case .notify(let text):
            let message = AutomationPlaceholders.fill(text, url: url, title: title, file: file)
            session.showToast?(Toast(symbolName: "bolt.fill", message: message.isEmpty ? rule.name : message, identity: "automation-\(rule.id)"))
        case .runShortcut(let name):
            var components = URLComponents(string: "shortcuts://run-shortcut")!
            components.queryItems = [
                URLQueryItem(name: "name", value: name),
                URLQueryItem(name: "input", value: "text"),
                URLQueryItem(name: "text", value: url?.absoluteString ?? file?.path ?? "")
            ]
            if let shortcutURL = components.url { NSWorkspace.shared.open(shortcutURL) }
        case .runAppleScript(let source):
            let script = AutomationPlaceholders.fill(source, url: url, title: title, file: file)
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
        case .openURL(let template):
            let address = AutomationPlaceholders.fill(template, url: url, title: title, file: file)
            guard let target = URL(string: address) else { return }
            _ = session.newTab(url: target, select: false)
        }
    }
}
