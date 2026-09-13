import Foundation
import Testing
@testable import Kylmora

@Suite("Tab suspension policy")
@MainActor
struct TabSuspensionTests {
    /// A tab that reports itself as loaded without touching WebKit, so the
    /// policy can be tested without a window on screen.
    private func loadedTab(idleFor seconds: TimeInterval, in session: BrowserSession) -> Tab {
        let tab = session.newTab(url: URL(string: "https://example.com")!, select: true)
        session.selectTab(tab)
        tab.markActive()
        return tab
    }

    @Test("Nothing is suspended when the user has turned it off")
    func suspensionOff() {
        let session = TestSession.make().0
        let candidates = TabSuspension.candidates(
            among: session.allTabs,
            protecting: [],
            idleThreshold: nil,
            trigger: .idle
        )
        #expect(candidates.isEmpty)
    }

    @Test("An unloaded tab is never a candidate: there is nothing to reclaim")
    func unloadedTabsAreSkipped() {
        let session = TestSession.make().0
        // Tabs are lazy, so nothing in a fresh session has a web view yet.
        #expect(session.allTabs.allSatisfy { !$0.isLoaded })

        for trigger in [TabSuspension.Trigger.idle, .memoryWarning, .memoryCritical] {
            let candidates = TabSuspension.candidates(
                among: session.allTabs,
                protecting: [],
                idleThreshold: 60,
                trigger: trigger
            )
            #expect(candidates.isEmpty, "trigger \(trigger) should skip unloaded tabs")
        }
    }

    @Test("The visible tab is protected under every trigger")
    func visibleTabIsProtected() {
        let session = TestSession.make().0
        let tab = session.activeTab!
        for trigger in [TabSuspension.Trigger.idle, .memoryWarning, .memoryCritical] {
            let candidates = TabSuspension.candidates(
                among: [tab],
                protecting: [tab.id],
                idleThreshold: 0,
                trigger: trigger
            )
            #expect(candidates.isEmpty, "trigger \(trigger) must not suspend the visible tab")
        }
    }

    @Test("Suspending never touches the tab on screen")
    func suspendRespectsVisibility() {
        let session = TestSession.make().0
        let visible = session.activeTab!
        session.suspend(session.allTabs)
        #expect(session.activeSpace.tabs.contains { $0 === visible })
        #expect(session.allTabs.count == 1)
    }

    @Test("Suspension leaves the tab in the sidebar")
    func suspensionKeepsTheTab() {
        let session = TestSession.make().0
        let first = session.activeTab!
        let second = session.newTab(url: URL(string: "https://example.com")!)
        session.selectTab(first)

        session.suspend([second])
        #expect(session.activeSpace.tabs.count == 2)
        #expect(session.activeTab === first)
    }

    @Test("A warning tightens the idle threshold rather than replacing it")
    func warningUsesItsOwnThreshold() {
        #expect(TabSuspension.warningThreshold < 5 * 60)
    }

    @Test("Settings map minutes to a delay, and zero means never")
    func settingsMapping() {
        let settings = Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
        #expect(settings.tabSuspensionMinutes == 10)
        #expect(settings.tabSuspensionDelay == 600)

        settings.tabSuspensionMinutes = 0
        #expect(settings.tabSuspensionDelay == nil)

        settings.tabSuspensionMinutes = 30
        #expect(settings.tabSuspensionDelay == 1800)
    }

    // MARK: - What is rendered, not what is selected

    /// The policy reads three facts per tab, so a test can state them directly
    /// rather than standing a window up to produce them.
    private func state(_ id: UUID, loaded: Bool = true, idleFor seconds: TimeInterval = 0) -> TabSuspension.TabState {
        TabSuspension.TabState(id: id, isLoaded: loaded, lastActiveAt: Date.now.addingTimeInterval(-seconds))
    }

    @Test("Every rendered tab is protected, not just the focused one")
    func everyRenderedTabIsProtected() {
        // The split case: two panes on screen, one of them focused. The other
        // has been idle for an hour because nothing has clicked in it, which is
        // exactly the tab the old rule would have blanked.
        let focused = UUID()
        let unfocused = UUID()
        let background = UUID()
        let tabs = [state(focused), state(unfocused, idleFor: 3600), state(background, idleFor: 3600)]

        for trigger in [TabSuspension.Trigger.idle, .memoryWarning, .memoryCritical] {
            let chosen = TabSuspension.candidateIDs(
                among: tabs,
                protecting: [focused, unfocused],
                idleThreshold: 60,
                trigger: trigger
            )
            #expect(chosen == [background], "trigger \(trigger) must spare every pane on screen")
        }
    }

    @Test("A rendered pane protects the tabs it is split with")
    func aCohortIsProtectedAsAUnit() {
        // Belt and braces for a caller that reports only the focused pane: a
        // split cannot render one pane and blank its sibling.
        let focused = UUID()
        let sibling = UUID()
        let chosen = TabSuspension.candidateIDs(
            among: [state(focused), state(sibling, idleFor: 3600)],
            protecting: [focused],
            idleThreshold: 60,
            trigger: .memoryCritical,
            cohorts: [[focused, sibling]]
        )
        #expect(chosen.isEmpty)
    }

    @Test("Unloading a split is all or nothing")
    func anOffScreenCohortGoesTogether() {
        // A split in a background space: one pane crossed the threshold and the
        // other did not. Unloading half of it would hold most of the memory for
        // none of the benefit, since the group comes back as a unit anyway.
        let idle = UUID()
        let recent = UUID()
        let chosen = TabSuspension.candidateIDs(
            among: [state(idle, idleFor: 3600), state(recent, idleFor: 1)],
            protecting: [],
            idleThreshold: 60,
            trigger: .idle,
            cohorts: [[idle, recent]]
        )
        #expect(chosen == [idle, recent])
    }

    @Test("Escalation never resurrects an unloaded pane as a candidate")
    func escalationSkipsUnloadedMembers() {
        let idle = UUID()
        let alreadyGone = UUID()
        let chosen = TabSuspension.candidateIDs(
            among: [state(idle, idleFor: 3600), state(alreadyGone, loaded: false, idleFor: 3600)],
            protecting: [],
            idleThreshold: 60,
            trigger: .idle,
            cohorts: [[idle, alreadyGone]]
        )
        #expect(chosen == [idle])
    }

    @Test("A cohort no tab is idle enough for is left alone")
    func aFreshCohortIsNotEscalated() {
        let first = UUID()
        let second = UUID()
        let chosen = TabSuspension.candidateIDs(
            among: [state(first, idleFor: 1), state(second, idleFor: 2)],
            protecting: [],
            idleThreshold: 60,
            trigger: .idle,
            cohorts: [[first, second]]
        )
        #expect(chosen.isEmpty)
    }

    @Test("Only the tab on screen is protected, not every space's selection")
    func onlyVisibleTabIsProtected() {
        let session = TestSession.make().0
        let personalTab = session.activeTab!
        session.addSpace(named: "Work")
        let workTab = session.activeTab!

        #expect(workTab !== personalTab)
        #expect(session.visibleTabIDs == [workTab.id])
    }
}
