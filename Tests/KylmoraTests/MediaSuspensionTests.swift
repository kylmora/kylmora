import Foundation
import Testing
@testable import Kylmora

/// A background tab keeps its own live web view, and WebKit does not pause its
/// media just because it left the screen. `updateMediaSuspension` is what stops
/// a video or song playing on behind whatever is in front of it, and what keeps
/// two media tabs from playing at once. These check the model side of that: only
/// the tabs in `visibleTabIDs` are left playing, every other one is paused.
@Suite("Background media suspension")
@MainActor
struct MediaSuspensionTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test("Only the visible tab may play; every other loaded tab is paused")
    func onlyVisiblePlays() {
        let session = TestSession.make().0
        let a = session.activeTab!
        let b = session.newTab(url: url("https://b.example"))
        let c = session.newTab(url: url("https://c.example"))
        session.selectTab(a)

        session.updateMediaSuspension()
        #expect(a.isMediaSuspended == false)
        #expect(b.isMediaSuspended)
        #expect(c.isMediaSuspended)
    }

    @Test("Switching tab resumes the new one and pauses the one left behind")
    func switchingTabMovesPlayback() {
        let session = TestSession.make().0
        let a = session.activeTab!
        let b = session.newTab(url: url("https://b.example"))
        session.selectTab(a)
        session.updateMediaSuspension()
        #expect(a.isMediaSuspended == false)
        #expect(b.isMediaSuspended)

        session.selectTab(b)
        session.updateMediaSuspension()
        #expect(b.isMediaSuspended == false)
        #expect(a.isMediaSuspended)
    }

    @Test("Switching space pauses the media in the space left behind")
    func switchingSpacePausesTheOther() {
        let session = TestSession.make().0
        let personal = session.activeSpace
        let personalTab = session.activeTab!

        // addSpace makes the new space active and gives it a tab.
        _ = session.addSpace(named: "Work")
        let workTab = session.activeTab!
        session.updateMediaSuspension()
        #expect(workTab.isMediaSuspended == false)
        #expect(personalTab.isMediaSuspended)

        session.selectSpace(personal)
        session.updateMediaSuspension()
        #expect(personalTab.isMediaSuspended == false)
        #expect(workTab.isMediaSuspended)
    }

    @Test("Both panes of a split keep playing; a tab outside it does not")
    func splitPanesBothPlay() {
        let session = TestSession.make().0
        let a = session.activeTab!
        let b = session.newTab(url: url("https://b.example"))
        let c = session.newTab(url: url("https://c.example"))

        #expect(session.splitTabs([a, b]))
        session.updateMediaSuspension()
        #expect(session.visibleTabIDs == Set([a.id, b.id]))
        #expect(a.isMediaSuspended == false)
        #expect(b.isMediaSuspended == false)
        #expect(c.isMediaSuspended)
    }

    @Test("A tab created in the background starts paused")
    func backgroundTabStartsPaused() {
        let session = TestSession.make().0
        let bg = session.newTab(url: url("https://bg.example"), select: false)
        session.updateMediaSuspension()
        #expect(bg.isMediaSuspended)
        #expect(session.activeTab?.isMediaSuspended == false)
    }

    @Test("With no tab on screen, nothing is left playing")
    func nothingVisibleSuspendsEverything() {
        let session = TestSession.make().0
        let a = session.activeTab!
        session.activeSpace.setActiveTabID(nil)
        session.updateMediaSuspension()
        #expect(session.visibleTabIDs.isEmpty)
        #expect(a.isMediaSuspended)
    }
}
