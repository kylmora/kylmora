import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("Window borders")
@MainActor
struct WindowBorderTests {
    @Test("A space starts with no border, and the border is the space's own")
    func perSpace() {
        let session = TestSession.make().0
        #expect(session.activeSpace.border == .none)
        #expect(session.activeSpace.border.isVisible == false)

        let work = session.addSpace(named: "Work")
        let rim = WindowBorder(style: .gradient, thickness: .thick, animation: .fast, palette: .ocean)
        session.setBorder(rim, for: work)
        #expect(work.border == rim)
        #expect(session.spaces[0].border == .none, "Only the space that was edited changes")
    }

    @Test("Changing a border is reported like a recolour, and an unchanged one is not")
    func reportsChanges() {
        let session = TestSession.make().0
        var reports = 0
        let subscription = session.changes.sink { change in
            if case .spaces = change { reports += 1 }
        }
        defer { subscription.cancel() }

        session.setBorder(.sample, for: session.activeSpace)
        #expect(reports == 1)
        session.setBorder(.sample, for: session.activeSpace)
        #expect(reports == 1, "Setting the same border again is not a change")
    }

    @Test("Borders survive a relaunch, and a session without them restores with none")
    func roundTrip() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "kylmora-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = SessionStore(fileURL: file)
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!

        let first = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        let rim = WindowBorder(style: .solid, thickness: .medium, animation: .slow, palette: .gold)
        let work = first.addSpace(named: "Work")
        first.setBorder(rim, for: work)
        first.saveNow()

        let second = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        #expect(second.spaces[0].border == .none)
        #expect(second.spaces[1].border == rim)

        // The same file with the border stripped out is a session from before
        // borders existed.
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var spaces = try #require(json["spaces"] as? [[String: Any]])
        spaces[1]["border"] = nil
        json["spaces"] = spaces
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let third = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        #expect(third.spaces[1].border == .none)
    }

    @Test("A border from a build with fields this one lacks still decodes")
    func toleratesUnknownValues() throws {
        let json = #"{"style":"gradient","thickness":"hairline","animation":"warp","palette":"nebula","glow":true}"#
        let border = try JSONDecoder().decode(WindowBorder.self, from: Data(json.utf8))
        #expect(border.style == .gradient, "A known field is kept")
        #expect(border.thickness == WindowBorder.none.thickness, "An unknown value falls back on its own")
        #expect(border.animation == WindowBorder.none.animation)
        #expect(border.palette == WindowBorder.none.palette)

        let empty = try JSONDecoder().decode(WindowBorder.self, from: Data("{}".utf8))
        #expect(empty == .none)
    }

    @Test("Only a moving gradient animates; thickness and speed have three named stops each")
    func stops() {
        #expect(WindowBorder(style: .gradient, thickness: .thin, animation: .fast, palette: .glow).isAnimated)
        #expect(WindowBorder(style: .gradient, thickness: .thin, animation: .still, palette: .glow).isAnimated == false)
        #expect(WindowBorder(style: .solid, thickness: .thin, animation: .fast, palette: .glow).isAnimated == false,
                "A solid rim has nothing to sweep")
        #expect(WindowBorder.Thickness.allCases.map(\.points) == WindowBorder.Thickness.allCases.map(\.points).sorted())
        #expect(WindowBorder.Animation.still.secondsPerRevolution == 0)
        #expect(WindowBorder.Animation.fast.secondsPerRevolution < WindowBorder.Animation.slow.secondsPerRevolution)
        for palette in WindowBorder.Palette.allCases {
            #expect(palette.stops.count >= 2, "\(palette.title) needs at least two colours to be a gradient")
            #expect(palette.stops.contains(palette.solidColor))
        }
    }

    @Test("The rim view draws only when there is a border, and clips to the window's corner")
    func viewDraws() {
        let view = WindowBorderView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.layoutSubtreeIfNeeded()
        #expect(view.hitTest(NSPoint(x: 1, y: 1)) == nil, "The rim never takes a click")
        #expect(view.layer?.sublayers?.allSatisfy { $0.isHidden } == true, "No border, nothing drawn")

        view.show(.sample, animatedOver: 0)
        view.layoutSubtreeIfNeeded()
        let coats = view.layer?.sublayers ?? []
        let shown = coats.filter { !$0.isHidden }
        #expect(shown.count == 1)
        let ring = shown.first?.mask
        #expect(ring?.cornerRadius == Style.Metrics.windowCornerRadius)
        #expect(ring?.cornerCurve == .continuous)
        #expect(ring?.borderWidth == WindowBorder.Thickness.thin.points)
        let paint = shown.first?.sublayers?.first as? CAGradientLayer
        #expect(paint?.type == .conic)
        #expect(paint?.colors?.count == WindowBorder.Palette.flare.stops.count + 1, "The sweep closes on its first colour")

        view.cornerRadius = 0
        #expect(ring?.cornerRadius == 0, "Full screen has no corners")

        view.show(.none, animatedOver: 0)
        view.layoutSubtreeIfNeeded()
        #expect(view.layer?.sublayers?.allSatisfy { $0.isHidden } == true)
    }

    @Test("A drag blends the rim towards the neighbour's, and a release finishes there")
    func blends() {
        let view = WindowBorderView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.show(.sample, animatedOver: 0)
        let other = WindowBorder(style: .solid, thickness: .thick, animation: .still, palette: .mint)
        view.blend(toward: other, fraction: 0.25)
        let opacities = (view.layer?.sublayers ?? []).map(\.opacity).sorted()
        #expect(opacities == [0.25, 0.75])

        view.show(other, animatedOver: 0)
        #expect(view.border == other)
        let after = (view.layer?.sublayers ?? []).filter { $0.opacity == 1 }
        #expect(after.count == 1)
        #expect((after.first?.mask)?.borderWidth == WindowBorder.Thickness.thick.points)
    }
}
