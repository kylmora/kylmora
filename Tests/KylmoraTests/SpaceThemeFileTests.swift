import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("Theme files and sidebar density")
@MainActor
struct SpaceThemeFileTests {
    @Test("A theme file carries a space's look and puts it on another space")
    func roundTrip() throws {
        let (session, _) = TestSession.make()
        let source = session.activeSpace
        var look = SpaceLook()
        look.appearance = .dark
        look.customColorHex = "#336699"
        look.showsBookmarksBar = true
        look.washOpacity = 0.6
        session.setTheme(.custom, for: source)
        session.setLook(look, for: source)
        var border = WindowBorder.none
        border.style = WindowBorder.Style.allCases.last!
        session.setBorder(border, for: source)

        let file = SpaceThemeFile(space: source)
        #expect(file.name == source.name)
        #expect(file.suggestedFileName.hasSuffix(".kylmoratheme"))
        let data = try file.data()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("336699"))
        #expect(!text.contains("tabs"), "tabs never travel with a theme")

        let decoded = try SpaceThemeFile(data: data)
        #expect(decoded == file)

        let target = session.addSpace(named: "Other")
        decoded.apply(to: target, in: session)
        #expect(target.theme == .custom)
        #expect(target.look.customColorHex == "#336699")
        #expect(target.look.appearance == .dark)
        #expect(target.look.showsBookmarksBar)
        #expect(target.border.style == border.style)
        #expect(target.name == "Other", "the name stays")
    }

    @Test("A theme file with a slash in its name still has a file name")
    func fileName() {
        let file = SpaceThemeFile(name: "Work / Home", theme: .blue, look: SpaceLook(), border: .none)
        #expect(file.suggestedFileName == "Work - Home.kylmoratheme")
        #expect(SpaceThemeFile(name: "  ", theme: .blue, look: SpaceLook(), border: .none).suggestedFileName == "Theme.kylmoratheme")
    }

    @Test("Sidebar density sets the row height, and the metrics follow the setting")
    func density() {
        let settings = Settings.shared
        let before = settings.sidebarDensity
        defer { settings.sidebarDensity = before }
        #expect(SidebarDensity.compact.rowHeight < SidebarDensity.regular.rowHeight)
        #expect(SidebarDensity.regular.rowHeight < SidebarDensity.roomy.rowHeight)
        for density in SidebarDensity.allCases {
            #expect(density.pillHeight == density.rowHeight - 6)
        }

        var notified = 0
        let token = NotificationCenter.default.addObserver(forName: .sidebarDensityDidChange, object: nil, queue: nil) { _ in notified += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        settings.sidebarDensity = .roomy
        #expect(Style.Metrics.rowHeight == 38)
        #expect(Style.Metrics.rowPillHeight == 32)
        settings.sidebarDensity = .roomy
        #expect(notified == 1, "setting the same density again is not a change")
        settings.sidebarDensity = .compact
        #expect(Style.Metrics.rowHeight == 28)
        #expect(notified == 2)
    }
}
