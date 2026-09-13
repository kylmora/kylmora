import AppKit

/// What a live folder is currently doing, which is what its header draws.
enum LiveFolderStatus: Sendable, Equatable {
    /// Has contents, nothing to say.
    case ready
    case refreshing
    /// The last fetch succeeded and there was genuinely nothing. A real state,
    /// not a failure dressed as one -- which is the whole point of separating
    /// the two.
    case empty
    case failed(LiveFolderIssue)
}

/// What the manager needs the rest of the browser to do, since it owns no tabs.
///
/// A delegate rather than a reference to `BrowserSession`, because creating and
/// closing tabs is the session's job and a poll timer reaching into the tab list
/// directly is how a subsystem quietly becomes load-bearing. It also means the
/// manager is testable against a stub.
@MainActor
protocol LiveFolderManagerDelegate: AnyObject {
    /// Open a background tab for a remote item and return its id, or `nil` if
    /// it could not be opened -- in which case the item is offered again next
    /// poll rather than being recorded as done.
    func liveFolderManager(
        _ manager: LiveFolderManager,
        openTabFor item: LiveFolderItem,
        inFolder folderID: TabGroup.ID
    ) -> Tab.ID?

    /// Close tabs whose remote item is gone. Only ever tabs the manager itself
    /// created.
    func liveFolderManager(
        _ manager: LiveFolderManager,
        closeTabs tabIDs: [Tab.ID],
        inFolder folderID: TabGroup.ID
    )

    /// The folder's contents or status changed and its rows need redrawing.
    func liveFolderManager(_ manager: LiveFolderManager, didChange folderID: TabGroup.ID)
}

/// Owns every live folder: its configuration, its poll timer and its state.
///
/// One manager for the whole app rather than one per folder, because the two
/// things that must be coordinated -- the wake-from-sleep catch-up and the
/// shared rate-limit budget of a single anonymous client -- are global.
@MainActor
final class LiveFolderManager {
    weak var delegate: LiveFolderManagerDelegate?

    private var records: [TabGroup.ID: LiveFolderRecord] = [:]
    private var tasks: [TabGroup.ID: Task<Void, Never>] = [:]
    private var refreshing: Set<TabGroup.ID> = []
    private let fetcher: LiveFolderFetcher
    private let store: LiveFolderStore
    private var wakeObserver: (any NSObjectProtocol)?
    private var saveTask: Task<Void, Never>?

    init(store: LiveFolderStore = .shared, fetcher: LiveFolderFetcher = .shared) {
        self.store = store
        self.fetcher = fetcher
    }

    // MARK: - Lifecycle

    /// Reads the folders back and starts their timers.
    func start() async {
        let stored = await store.load()
        for record in stored { records[record.id] = record }
        observeWake()
        for id in records.keys { schedule(id) }
    }

    /// Stops every timer without forgetting anything, for window close or
    /// termination.
    ///
    /// The wake observer goes here rather than in `deinit`: a `deinit` is
    /// nonisolated and cannot touch main-actor state, and a manager that lives
    /// as long as the app would never reach it anyway.
    func stop() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// Waking from sleep is the one moment every folder is overdue at once.
    /// Rescheduling them all produces a single catch-up fetch each, because the
    /// delay is computed from `lastFetched` rather than counted down.
    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for id in self.records.keys { self.schedule(id) }
            }
        }
    }

    // MARK: - Folders

    var allRecords: [LiveFolderRecord] {
        records.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func record(for folderID: TabGroup.ID) -> LiveFolderRecord? { records[folderID] }

    func isLive(_ folderID: TabGroup.ID) -> Bool { records[folderID] != nil }

    /// Adopts a folder as live and polls it immediately: a folder that sits
    /// empty for half an hour after being created reads as broken.
    func add(folderID: TabGroup.ID, source: LiveFolderSource, interval: TimeInterval? = nil) {
        var state = LiveFolderState()
        if let interval { state.interval = interval }
        records[folderID] = LiveFolderRecord(id: folderID, source: source, state: state)
        persist()
        schedule(folderID)
    }

    /// Forgets a folder. The tabs are the caller's to deal with -- deleting a
    /// folder and keeping its tabs is a legitimate thing to want, and the
    /// manager is not the right place to decide.
    func remove(folderID: TabGroup.ID) {
        tasks[folderID]?.cancel()
        tasks[folderID] = nil
        records[folderID] = nil
        refreshing.remove(folderID)
        persist()
    }

    /// The metadata a new folder should be created with, before it has ever
    /// been fetched.
    static func metadata(for source: LiveFolderSource) -> LiveFolderMetadata {
        source.makeProvider().metadata
    }

    func status(for folderID: TabGroup.ID, itemCount: Int) -> LiveFolderStatus {
        guard let record = records[folderID] else { return .ready }
        // A poll in flight wins over the error it may be about to clear:
        // showing yesterday's failure next to a spinner reads as two states at
        // once.
        if refreshing.contains(folderID) { return .refreshing }
        if let issue = record.state.lastIssue { return .failed(issue) }
        return itemCount == 0 ? .empty : .ready
    }

    // MARK: - Refreshing

    /// Polls now, whatever the timer thinks. The refresh menu item and the
    /// error state's retry button both land here.
    func refresh(folderID: TabGroup.ID) async {
        guard let record = records[folderID], !refreshing.contains(folderID) else { return }
        refreshing.insert(folderID)
        delegate?.liveFolderManager(self, didChange: folderID)
        defer {
            refreshing.remove(folderID)
            delegate?.liveFolderManager(self, didChange: folderID)
        }

        let provider = record.makeProvider()
        let outcome = await provider.fetchItems(using: fetcher)

        // The folder may have been deleted while the request was in flight.
        guard var current = records[folderID] else { return }

        switch outcome {
        case .blocked(let issue):
            current.state.noteIssue(issue)
            records[folderID] = current
        case .items(let items):
            let plan = current.state.plan(for: items)
            if !plan.staleTabIDs.isEmpty {
                delegate?.liveFolderManager(self, closeTabs: plan.staleTabIDs, inFolder: folderID)
            }
            var opened: [String: Tab.ID] = [:]
            for item in plan.additions {
                if let tabID = delegate?.liveFolderManager(self, openTabFor: item, inFolder: folderID) {
                    opened[item.id] = tabID
                }
            }
            current.state.apply(plan, openedTabs: opened)
            current.source = provider.learning(from: items).source
            records[folderID] = current
        }

        persist()
        schedule(folderID)
    }

    /// The user closed a tab, or dragged it out. Either way it must not come
    /// back on the next poll.
    func tabWasRemoved(_ tabID: Tab.ID, fromFolder folderID: TabGroup.ID) {
        guard var record = records[folderID], record.state.isTracked(tabID: tabID) else { return }
        record.state.dismiss(tabID: tabID)
        records[folderID] = record
        persist()
    }

    /// Whether a refresh is allowed to close this tab. False for anything the
    /// user put in the folder themselves.
    func isProviderTab(_ tabID: Tab.ID, inFolder folderID: TabGroup.ID) -> Bool {
        records[folderID]?.state.isTracked(tabID: tabID) ?? false
    }

    // MARK: - Options

    /// The whole options menu: the two items every provider gets, then the
    /// provider's own.
    func options(for folderID: TabGroup.ID) -> [LiveFolderOption] {
        guard let record = records[folderID] else { return [] }
        var items: [LiveFolderOption] = [
            .action(key: LiveFolderOptionChange.refreshKey, title: "Refresh Now"),
            .choice(
                key: LiveFolderOptionChange.intervalKey,
                title: "Refresh",
                values: LiveFolderState.intervalChoices.map {
                    LiveFolderOption.Value(value: String(Int($0.seconds)), title: $0.title)
                },
                selected: String(Int(record.state.interval))
            ),
            .separator
        ]
        items.append(contentsOf: record.makeProvider().options)
        return items
    }

    /// Applies an option. Refresh and interval are handled here for every
    /// provider, exactly as the specification describes the base class doing;
    /// anything else is handed down.
    func apply(_ change: LiveFolderOptionChange, to folderID: TabGroup.ID) {
        guard var record = records[folderID] else { return }

        switch (change.key, change.value) {
        case (LiveFolderOptionChange.refreshKey, _):
            Task { await self.refresh(folderID: folderID) }
            return
        case (LiveFolderOptionChange.intervalKey, .string(let raw)):
            guard let seconds = TimeInterval(raw), seconds > 0 else { return }
            record.state.interval = seconds
            records[folderID] = record
            persist()
            schedule(folderID)
            return
        default:
            break
        }

        record.source = record.makeProvider().applying(change).source
        // A changed filter invalidates whatever the last error was: "no filter
        // selected" must not survive the user selecting one.
        record.state.lastIssue = nil
        records[folderID] = record
        persist()
        delegate?.liveFolderManager(self, didChange: folderID)
        Task { await self.refresh(folderID: folderID) }
    }

    /// What the error state's action button does: open the page that would fix
    /// it, if there is one, and otherwise retry.
    func recover(from issue: LiveFolderIssue, folderID: TabGroup.ID) -> URL? {
        if let url = issue.recoveryURL { return url }
        if issue.allowsImmediateRetry {
            Task { await self.refresh(folderID: folderID) }
        }
        return nil
    }

    // MARK: - Scheduling

    /// One sleeping task per folder, re-armed after every fetch.
    ///
    /// The delay is always recomputed from the record rather than counted down,
    /// so changing the interval, waking from sleep and backing off after a
    /// failure all work by the same mechanism: cancel, reschedule, ask again.
    private func schedule(_ folderID: TabGroup.ID) {
        tasks[folderID]?.cancel()
        guard records[folderID] != nil else { return }
        tasks[folderID] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let record = self.records[folderID] else { return }
                let delay = record.state.nextFetchDelay()
                if delay > 0 {
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                }
                guard !Task.isCancelled else { return }
                await self.refresh(folderID: folderID)
                return // `refresh` re-arms, so this task's job is done.
            }
        }
    }

    /// Coalesced, because a refresh writes the file and several folders can
    /// finish within the same runloop turn.
    private func persist() {
        saveTask?.cancel()
        let snapshot = allRecords
        saveTask = Task { [store] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await store.save(snapshot)
        }
    }
}
