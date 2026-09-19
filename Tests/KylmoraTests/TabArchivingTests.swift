import Foundation
import Testing
@testable import Kylmora

@Suite("Tab archiving policy")
@MainActor
struct TabArchivingTests {
    private func state(
        _ id: UUID = UUID(),
        asleep: Bool = true,
        idleFor seconds: TimeInterval = 86_400,
        keepsAwake: Bool = false,
        keepsInSidebar: Bool = false,
        isPinned: Bool = false,
        isProviderManaged: Bool = false
    ) -> TabArchiving.TabState {
        TabArchiving.TabState(
            id: id,
            isAsleep: asleep,
            lastActiveAt: Date.now.addingTimeInterval(-seconds),
            keepsAwake: keepsAwake,
            keepsInSidebar: keepsInSidebar,
            isPinned: isPinned,
            isProviderManaged: isProviderManaged
        )
    }

    private let day: TimeInterval = 86_400

    @Test("Nothing is archived when the setting is off, however old the tab")
    func offByDefault() {
        let chosen = TabArchiving.candidateIDs(
            among: [state(idleFor: 365 * 86_400)],
            threshold: nil
        )
        #expect(chosen.isEmpty)
    }

    @Test("A tab that is still holding a page is never archived")
    func requiresTheFirstStage() {
        // The whole point of two stages: a tab has to have stopped holding a
        // page before it can lose its row. An open tab is never archived
        // however long the clock says, which is also what stops the sweep
        // touching anything in a split or on screen.
        let chosen = TabArchiving.candidateIDs(
            among: [state(asleep: false, idleFor: 30 * 86_400)],
            threshold: day
        )
        #expect(chosen.isEmpty)
    }

    @Test("A tab opened in the background and never read is archivable")
    func neverOpenedTabsQualify() {
        // It holds no page, so it is asleep by the only definition that means
        // anything to the user -- and it is precisely the clutter the setting
        // exists for. Its snapshot carries its address and title, which is
        // everything such a tab ever had, so nothing is lost by filing it.
        let unread = state(asleep: true, idleFor: 5 * 86_400)
        #expect(TabArchiving.candidateIDs(among: [unread], threshold: day) == [unread.id])
    }

    @Test("A suspended tab is archived once it passes the threshold")
    func archivesWhenStale() {
        let stale = state(idleFor: 2 * 86_400)
        let fresh = state(idleFor: 3_600)
        let chosen = TabArchiving.candidateIDs(among: [stale, fresh], threshold: day)
        #expect(chosen == [stale.id])
    }

    @Test("The threshold is inclusive, so the setting means what it says")
    func thresholdIsInclusive() {
        let exactly = state(idleFor: day)
        #expect(TabArchiving.candidateIDs(among: [exactly], threshold: day) == [exactly.id])
    }

    @Test("Every lock and every exemption keeps a stale tab in the sidebar")
    func exemptions() {
        let cases: [(String, TabArchiving.TabState)] = [
            ("keeps awake", state(keepsAwake: true)),
            ("keeps in sidebar", state(keepsInSidebar: true)),
            ("pinned", state(isPinned: true)),
            ("live folder", state(isProviderManaged: true))
        ]
        for (name, tab) in cases {
            let chosen = TabArchiving.candidateIDs(among: [tab], threshold: day)
            #expect(chosen.isEmpty, "a \(name) tab must not be archived")
        }
    }

    @Test("A rendered tab is protected even if it somehow reports as suspended")
    func protectedTabsAreSkipped() {
        let tab = state()
        let chosen = TabArchiving.candidateIDs(among: [tab], protecting: [tab.id], threshold: day)
        #expect(chosen.isEmpty)
    }

    @Test("A split is archived whole or not at all")
    func splitsGoTogether() {
        // One pane stale, its sibling still fresh. Taking the stale one would
        // dismantle an arrangement the user built by hand and leave the other
        // pane orphaned.
        let stale = state(idleFor: 3 * 86_400)
        let fresh = state(idleFor: 60)
        let chosen = TabArchiving.candidateIDs(
            among: [stale, fresh],
            threshold: day,
            cohorts: [[stale.id, fresh.id]]
        )
        #expect(chosen.isEmpty)

        // Both stale: the whole split goes, and comes back as a unit.
        let otherStale = state(idleFor: 3 * 86_400)
        let both = TabArchiving.candidateIDs(
            among: [stale, otherStale],
            threshold: day,
            cohorts: [[stale.id, otherStale.id]]
        )
        #expect(both == [stale.id, otherStale.id])
    }

    @Test("One locked pane saves its whole split")
    func lockedPaneSavesTheSplit() {
        let locked = state(idleFor: 3 * 86_400, keepsInSidebar: true)
        let other = state(idleFor: 3 * 86_400)
        let chosen = TabArchiving.candidateIDs(
            among: [locked, other],
            threshold: day,
            cohorts: [[locked.id, other.id]]
        )
        #expect(chosen.isEmpty)
    }
}

@Suite("Tab lifecycle locks")
@MainActor
struct TabLifecycleLockTests {
    private let url = URL(string: "https://example.com")!

    @Test("Keep Awake stops an idle sweep suspending the tab")
    func keepAwakeBlocksIdleSuspension() {
        let id = UUID()
        let locked = TabSuspension.TabState(
            id: id,
            isLoaded: true,
            lastActiveAt: Date.now.addingTimeInterval(-3_600),
            keepsAwake: true
        )
        for trigger in [TabSuspension.Trigger.idle, .memoryWarning] {
            let chosen = TabSuspension.candidateIDs(
                among: [locked],
                protecting: [],
                idleThreshold: 60,
                trigger: trigger
            )
            #expect(chosen.isEmpty, "trigger \(trigger) must honour Keep Awake")
        }
    }

    @Test("A critically low system overrules the lock, because the alternative is worse")
    func criticalPressureOverrulesTheLock() {
        let id = UUID()
        let locked = TabSuspension.TabState(
            id: id,
            isLoaded: true,
            lastActiveAt: Date.now.addingTimeInterval(-3_600),
            keepsAwake: true
        )
        let chosen = TabSuspension.candidateIDs(
            among: [locked],
            protecting: [],
            idleThreshold: 60,
            trigger: .memoryCritical
        )
        #expect(chosen == [id])
    }

    @Test("A kept-awake pane keeps its split loaded too")
    func lockedPaneProtectsItsSplit() {
        let locked = UUID()
        let sibling = UUID()
        let states = [
            TabSuspension.TabState(id: locked, isLoaded: true, lastActiveAt: .distantPast, keepsAwake: true),
            TabSuspension.TabState(id: sibling, isLoaded: true, lastActiveAt: .distantPast)
        ]
        let chosen = TabSuspension.candidateIDs(
            among: states,
            protecting: [],
            idleThreshold: 60,
            trigger: .idle,
            cohorts: [[locked, sibling]]
        )
        #expect(chosen.isEmpty)
    }

    @Test("A tab that was never opened reports as asleep, because it is")
    func neverOpenedTabsAreAsleep() {
        // The bug this replaced: `isSuspended` requires a saved interaction
        // state, which a tab that never had a page does not have. Such a tab
        // reported as neither loaded nor suspended, so the sidebar drew it as
        // if it were open -- which is the one thing it certainly was not.
        let session = TestSession.make().0
        let tab = session.newTab(url: url)
        #expect(!tab.isLoaded)
        #expect(!tab.isSuspended, "it has no saved page, so it is not restorable")
        #expect(tab.isAsleep, "but it holds nothing, so the sidebar must say so")
    }

    @Test("A tab restored from a session with no saved page is asleep too")
    func restoredUnreadTabsAreAsleep() {
        let restored = Tab(restoring: SessionSnapshot.Tab(url: url), identity: .standard)
        #expect(restored.isAsleep)
        #expect(!restored.isSuspended)
    }

    @Test("The locks survive a relaunch")
    func locksRoundTrip() {
        let session = TestSession.make().0
        let tab = session.newTab(url: url)
        tab.setKeepsAwake(true)
        tab.setKeepsInSidebar(true)

        let restored = Tab(restoring: tab.snapshot(), identity: .standard)
        #expect(restored.keepsAwake)
        #expect(restored.keepsInSidebar)
    }

    @Test("The idle clock survives a relaunch, so archiving measures real time")
    func idleClockRoundTrips() {
        let session = TestSession.make().0
        let tab = session.newTab(url: url)
        let snapshot = tab.snapshot()
        #expect(snapshot.lastActiveAt != nil)

        var aged = snapshot
        aged.lastActiveAt = Date.now.addingTimeInterval(-5 * 86_400)
        let restored = Tab(restoring: aged, identity: .standard)
        #expect(restored.idleDuration() > 4 * 86_400)
    }

    @Test("A session written before the clock existed restores as just now")
    func missingClockRestoresFresh() {
        var snapshot = SessionSnapshot.Tab(url: url)
        snapshot.lastActiveAt = nil
        let restored = Tab(restoring: snapshot, identity: .standard)
        // Never archived for idleness accrued while nobody was measuring.
        #expect(restored.idleDuration() < 5)
        #expect(!restored.keepsAwake)
        #expect(!restored.keepsInSidebar)
    }
}

@Suite("The archive")
@MainActor
struct ArchiveTests {
    private let url = URL(string: "https://example.com/page")!

    @Test("An archived tab leaves the sidebar and lands in the archive")
    func archivingMovesTheTab() {
        let session = TestSession.make().0
        let keep = session.activeTab!
        let going = session.newTab(url: url)
        session.selectTab(keep)

        session.archive([going])
        #expect(session.activeSpace.tabs.count == 1)
        #expect(session.archivedTabs.count == 1)
        #expect(session.archivedTabs[0].snapshot.url == url)
    }

    @Test("Putting one back returns it to the space it left")
    func restoringReturnsTheTab() {
        let session = TestSession.make().0
        let going = session.newTab(url: url)
        session.archive([going])

        let restored = session.restoreArchived(session.archivedTabs[0])
        #expect(restored != nil)
        #expect(restored?.url == url)
        #expect(session.archivedTabs.isEmpty)
        #expect(session.activeSpace.tabs.contains { $0.url == url })
    }

    @Test("A restored tab starts its idle clock again")
    func restoringResetsTheClock() {
        // Otherwise the next sweep, seeing a month-old timestamp, would archive
        // the tab the user just asked for -- the worst bug this feature has.
        // The tab is aged before archiving, so the record carries the old clock.
        let session = TestSession.make().0
        let keep = session.activeTab!
        let going = session.newTab(url: url)
        session.selectTab(keep)
        going.backdateLastActive(by: 30 * 86_400)

        session.archive([going])
        #expect(session.archivedTabs[0].snapshot.lastActiveAt.map {
            Date.now.timeIntervalSince($0) > 29 * 86_400
        } == true)

        let restored = session.restoreArchived(session.archivedTabs[0])
        #expect(restored?.idleDuration() ?? .infinity < 5)
    }

    @Test("Forgetting drops it without bringing it back")
    func forgetting() {
        let session = TestSession.make().0
        let going = session.newTab(url: url)
        session.archive([going])
        session.forgetArchived(session.archivedTabs[0])
        #expect(session.archivedTabs.isEmpty)
        #expect(!session.activeSpace.tabs.contains { $0.url == url })
    }

    @Test("A private space archives nothing")
    func privateSpacesArchiveNothing() {
        let session = TestSession.make().0
        let space = session.addSpace(named: "Private", isPrivate: true)
        session.selectSpace(space)
        let tab = session.newTab(url: url)

        session.archive([tab])
        #expect(session.archivedTabs.isEmpty)
        // And it is still there: refusing to archive must not close it either.
        #expect(session.activeSpace.tabs.contains { $0 === tab })
    }

    @Test("Each Space has its own archive, and sees only its own")
    func archivesAreFiledBySpace() {
        let session = TestSession.make().0
        let first = session.activeSpace
        session.archive([session.newTab(url: url)])

        let other = session.addSpace(named: "Other")
        session.selectSpace(other)
        let otherURL = URL(string: "https://other.example/page")!
        session.archive([session.newTab(url: otherURL)])

        #expect(session.archivedTabs(in: first).count == 1)
        #expect(session.archivedTabs(in: first)[0].snapshot.url == url)
        #expect(session.archivedTabs(in: other).count == 1)
        #expect(session.archivedTabs(in: other)[0].snapshot.url == otherURL)
    }

    @Test("Clearing one Space's archive leaves every other Space's alone")
    func clearingIsPerSpace() {
        let session = TestSession.make().0
        let first = session.activeSpace
        session.archive([session.newTab(url: url)])
        let other = session.addSpace(named: "Other")
        session.selectSpace(other)
        session.archive([session.newTab(url: URL(string: "https://other.example/page")!)])

        session.clearArchive(in: other)
        #expect(session.archivedTabs(in: other).isEmpty)
        #expect(session.archivedTabs(in: first).count == 1, "The other Space's drawer was not touched")
    }

    @Test("Clearing everything empties every Space's archive at once")
    func clearingTheWholeArchive() {
        let session = TestSession.make().0
        session.archive([session.newTab(url: url)])
        let other = session.addSpace(named: "Other")
        session.selectSpace(other)
        session.archive([session.newTab(url: URL(string: "https://other.example/page")!)])
        #expect(session.archivedTabs.count == 2)

        session.clearArchive()
        #expect(session.archivedTabs.isEmpty)
    }

    @Test("A deleted Space takes its archive with it")
    func removingASpaceDropsItsArchive() {
        // Otherwise the records sit there forever: no list can show them, since
        // every list is one space's, and nothing can restore them.
        let session = TestSession.make().0
        let first = session.activeSpace
        session.archive([session.newTab(url: url)])
        let other = session.addSpace(named: "Other")
        session.selectSpace(other)
        session.archive([session.newTab(url: URL(string: "https://other.example/page")!)])

        session.removeSpace(other)
        #expect(session.archivedTabs.count == 1)
        #expect(session.archivedTabs(in: first).count == 1)
    }

    @Test("The archive of each Space comes back to that Space after a relaunch")
    func perSpaceArchivesRoundTrip() {
        let (session, store) = TestSession.make()
        session.archive([session.newTab(url: url)])
        let other = session.addSpace(named: "Other")
        session.selectSpace(other)
        let otherURL = URL(string: "https://other.example/page")!
        session.archive([session.newTab(url: otherURL)])
        try? store.save(session.snapshot())

        let settings = Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
        let reopened = BrowserSession(database: nil, sessionStore: store, settings: settings)
        #expect(reopened.spaces.count == 2)
        // Matched by name rather than by id: the ids are rebuilt on the way in.
        let reopenedOther = reopened.spaces.first { $0.name == "Other" }
        #expect(reopenedOther.map { reopened.archivedTabs(in: $0).map(\.snapshot.url) } == [otherURL])
        let reopenedFirst = reopened.spaces.first { $0.name != "Other" }
        #expect(reopenedFirst.map { reopened.archivedTabs(in: $0).map(\.snapshot.url) } == [url])
    }

    @Test("The archive survives a relaunch")
    func archiveRoundTrips() {
        let (session, store) = TestSession.make()
        let going = session.newTab(url: url)
        session.archive([going])
        try? store.save(session.snapshot())

        let settings = Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
        let reopened = BrowserSession(database: nil, sessionStore: store, settings: settings)
        #expect(reopened.archivedTabs.count == 1)
        #expect(reopened.archivedTabs[0].snapshot.url == url)
        // Filed against the space that came back, not a stale identifier.
        #expect(reopened.spaces.contains { $0.id == reopened.archivedTabs[0].spaceID })
    }
}

@Suite("The idle badge")
@MainActor
struct TabIdleLabelTests {
    @Test("Anything too recent to be interesting says nothing")
    func belowTheFloor() {
        #expect(TabIdleLabel.text(for: 0) == nil)
        #expect(TabIdleLabel.text(for: 4) == nil)
    }

    @Test("Seconds, minutes, hours and days, in the shortest honest form")
    func units() {
        #expect(TabIdleLabel.text(for: 5) == "5s")
        #expect(TabIdleLabel.text(for: 59) == "59s")
        #expect(TabIdleLabel.text(for: 60) == "1m")
        #expect(TabIdleLabel.text(for: 600) == "10m")
        #expect(TabIdleLabel.text(for: 3_599) == "59m")
        #expect(TabIdleLabel.text(for: 3_600) == "1h")
        #expect(TabIdleLabel.text(for: 86_399) == "23h")
        #expect(TabIdleLabel.text(for: 86_400) == "1d")
        #expect(TabIdleLabel.text(for: 5 * 86_400) == "5d")
    }

    @Test("Values are floored, so the badge never overstates the idleness")
    func floors() {
        #expect(TabIdleLabel.text(for: 119) == "1m")
        #expect(TabIdleLabel.text(for: 7_199) == "1h")
    }

    @Test("VoiceOver gets words, and the singular is singular")
    func spoken() {
        #expect(TabIdleLabel.spoken(for: 60) == "idle 1 minute")
        #expect(TabIdleLabel.spoken(for: 120) == "idle 2 minutes")
        #expect(TabIdleLabel.spoken(for: 86_400) == "idle 1 day")
        #expect(TabIdleLabel.spoken(for: 1) == nil)
    }

    @Test("The badge mode decides which rows carry one")
    func modes() {
        #expect(!TabIdleBadgeMode.never.showsBadge(isAsleep: true))
        #expect(TabIdleBadgeMode.asleep.showsBadge(isAsleep: true))
        #expect(!TabIdleBadgeMode.asleep.showsBadge(isAsleep: false))
        #expect(TabIdleBadgeMode.all.showsBadge(isAsleep: false))
    }

    @Test("Archiving is off by default and the hours map to a delay")
    func archiveSettings() {
        let settings = Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
        #expect(settings.tabArchiveHours == 0)
        #expect(settings.tabArchiveDelay == nil)

        settings.tabArchiveHours = 72
        // Spelled as a Double: two integer literals multiplied together infer
        // as `Int`, which compiles against a `TimeInterval?` and is never equal.
        #expect(settings.tabArchiveDelay == 259_200.0)
    }

    @Test("SiteSettings allowlist prevents tabs on that domain from suspending or archiving")
    func siteAllowlistNeverSuspends() {
        let siteURL = URL(string: "https://critical-dashboard.example.com/app")!
        let host = "critical-dashboard.example.com"
        
        #expect(SiteSettings.shared.allowsSuspension(for: siteURL) == true)
        
        // Add to never suspend allowlist
        SiteSettings.shared.update {
            $0.set("never", for: host, in: .tabSuspension)
        }
        
        #expect(SiteSettings.shared.allowsSuspension(for: siteURL) == false)
        
        let tab = Tab(url: siteURL, identity: .standard)
        #expect(tab.keepsAwake == true)
        #expect(tab.keepsInSidebar == true)
        
        // Reset site choice
        SiteSettings.shared.update {
            $0.remove(host, from: .tabSuspension)
        }
        #expect(SiteSettings.shared.allowsSuspension(for: siteURL) == true)
    }

    @Test("Space archiveHours override is respected and round-trips")
    func spaceArchiveHoursOverride() {
        let space = Space(name: "Temporary Space", identity: .standard, archiveHours: 12)
        #expect(space.archiveHours == 12)

        let session = TestSession.make().0
        session.spaces[0].archiveHours = 6
        let snapshot = session.snapshot()
        #expect(snapshot.spaces[0].archiveHours == 6)

        let restoredSpaces = BrowserSession.spaces(from: snapshot)
        #expect(restoredSpaces?[0].archiveHours == 6)
    }
}
