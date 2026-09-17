import AppKit
import Testing
@testable import Kylmora

// How wide the sidebar rests: one width for the whole browser, or one per
// space. Shared leads, because a window whose sidebar moves every time you
// switch space is the complaint this setting exists to answer -- and the
// setting exists because the opposite is a real want when one space holds long
// titles and another holds six pinned tabs.

@Suite("The sidebar's resting width")
@MainActor
struct SidebarWidthTests {
    private func settings() -> Settings {
        Settings(defaults: UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!)
    }

    @Test("Shared by every space, until told otherwise")
    func sharedByDefault() {
        #expect(settings().sidebarWidthIsPerSpace == false)
    }

    @Test("A dragged width outlives the window that was dragged")
    func widthPersists() {
        // It used to be read from `Style.Metrics` every time a window opened,
        // so dragging the divider lasted exactly as long as that window did.
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!
        Settings(defaults: defaults).sidebarWidth = 320
        #expect(Settings(defaults: defaults).sidebarWidth == 320)
    }

    @Test("With nothing saved it is the width the browser ships with")
    func fallsBackToTheShippedWidth() {
        #expect(settings().sidebarWidth == Style.Metrics.sidebarWidth)
    }

    @Test("A width the split view could not honour is brought inside the bounds")
    func widthIsClamped() {
        // A value saved by an older build, or on a much wider screen, has to
        // land inside what the split view will accept or the window opens with
        // a sidebar it cannot draw.
        let wide = settings()
        wide.sidebarWidth = 5000
        #expect(wide.sidebarWidth == Style.Metrics.sidebarMaxWidth)

        let narrow = settings()
        narrow.sidebarWidth = 10
        #expect(narrow.sidebarWidth == Style.Metrics.sidebarMinWidth)
    }

    @Test("A space carries a width of its own, and a new one does not")
    func spaceKeepsItsOwn() {
        let session = TestSession.make().0
        let space = session.activeSpace
        #expect(space.look.sidebarWidth == nil, "a new space has no width of its own")

        var look = space.look
        look.sidebarWidth = 300
        session.setLook(look, for: space)
        #expect(session.activeSpace.look.sidebarWidth == 300)
    }

    @Test("A per-space width survives being written down and read back")
    func widthSurvivesTheSessionFile() throws {
        // It rides in `SpaceLook`, which is what the session file stores, so a
        // space that was left wide is still wide after a relaunch.
        var look = SpaceLook()
        look.sidebarWidth = 288
        let data = try JSONEncoder().encode(look)
        let back = try JSONDecoder().decode(SpaceLook.self, from: data)
        #expect(back.sidebarWidth == 288)
    }

    @Test("A look written by a build without the setting still decodes")
    func olderSessionFilesStillOpen() throws {
        let older = Data(#"{"appearance":"system","washOpacity":1}"#.utf8)
        let look = try JSONDecoder().decode(SpaceLook.self, from: older)
        #expect(look.sidebarWidth == nil)
    }

    @Test("Turning the setting off keeps the widths, it does not throw them away")
    func widthsAreKeptWhileSharedIsOn() {
        // So that changing your mind twice does not cost you the sizes you set.
        let session = TestSession.make().0
        var look = session.activeSpace.look
        look.sidebarWidth = 300
        session.setLook(look, for: session.activeSpace)

        let prefs = settings()
        prefs.sidebarWidthIsPerSpace = true
        prefs.sidebarWidthIsPerSpace = false
        #expect(session.activeSpace.look.sidebarWidth == 300)
    }

    @Test("Both scopes are offered, shared first")
    func theSettingOffersBoth() {
        #expect(SidebarWidthScope.allCases.map(\.rawValue) == [0, 1])
        #expect(SidebarWidthScope.shared.rawValue == 0, "the default leads the list")
        #expect(SidebarWidthScope.allCases.allSatisfy { !$0.title.isEmpty })
    }
}
