import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("Space gradient wash")
@MainActor
struct SpaceGradientTests {
    @Test("A gradient supersedes the theme: the colour and wash follow its first stop")
    func gradientDrivesColour() {
        let session = TestSession.make().0
        let space = session.activeSpace
        session.setSpaceGradient(SpaceGradient(startHex: "#ff0000", endHex: "#0000ff", direction: .right), for: space)

        #expect(space.color.hexString == "#ff0000")
        #expect(space.wash != nil)
        let gradient = try! #require(space.washGradient(for: nil))
        #expect(gradient == WashGradient(startHex: "#ff0000", endHex: "#0000ff", direction: .right))
    }

    @Test("No gradient means no gradient wash, whatever the theme")
    func solidHasNoGradient() {
        let session = TestSession.make().0
        #expect(session.activeSpace.washGradient(for: nil) == nil)
        session.setTheme(.green, for: session.activeSpace)
        #expect(session.activeSpace.washGradient(for: nil) == nil)
    }

    @Test("Picking a solid colour or a swatch clears a gradient")
    func solidClearsGradient() {
        let session = TestSession.make().0
        let space = session.activeSpace
        session.setSpaceGradient(SpaceGradient(startHex: "#ff0000", endHex: "#0000ff"), for: space)
        #expect(space.look.gradient != nil)

        session.setCustomColor(NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1), for: space)
        #expect(space.look.gradient == nil)

        session.setSpaceGradient(SpaceGradient(startHex: "#00ff00", endHex: "#00ffff"), for: space)
        #expect(space.look.gradient != nil)
        session.setTheme(.blue, for: space)
        #expect(space.look.gradient == nil)
    }

    @Test("A space's gradient survives a relaunch")
    func gradientRoundTrips() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "kylmora-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = SessionStore(fileURL: file)
        let defaults = UserDefaults(suiteName: "kylmora.tests.\(UUID().uuidString)")!

        let first = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        let space = first.addSpace(named: "Painted")
        first.setSpaceGradient(SpaceGradient(startHex: "#112233", endHex: "#445566", direction: .upRight), for: space)
        first.saveNow()

        let second = BrowserSession(database: nil, sessionStore: store, settings: Settings(defaults: defaults))
        let restored = try #require(second.spaces.first(where: { $0.name == "Painted" }))
        #expect(restored.look.gradient == SpaceGradient(startHex: "#112233", endHex: "#445566", direction: .upRight))
        #expect(restored.color.hexString == "#112233")
    }

    @Test("A half-written gradient still resolves to real colours")
    func tolerantDecoding() throws {
        // Missing end stop falls back to the start; junk direction to the default.
        let json = Data(##"{"startHex":"#abcdef","direction":"sideways"}"##.utf8)
        let gradient = try JSONDecoder().decode(SpaceGradient.self, from: json)
        #expect(gradient.startHex == "#abcdef")
        #expect(gradient.endHex == "#abcdef")
        #expect(gradient.direction == .down)
    }
}

@Suite("Gradient direction")
struct GradientDirectionTests {
    @Test("The group's Direction is the shared type")
    func aliasIsShared() {
        #expect(TabGroupAppearance.Direction.down == GradientDirection.down)
        #expect(TabGroupAppearance.Direction.allCases.count == GradientDirection.allCases.count)
    }

    @Test("Every direction has a distinct angle and layer axis")
    func distinctGeometry() {
        let angles = GradientDirection.allCases.map(\.angle)
        #expect(Set(angles).count == angles.count)
        // Top to bottom runs down the layer: first stop at the top (y = 1).
        #expect(GradientDirection.down.layerPoints.start == CGPoint(x: 0.5, y: 1))
        #expect(GradientDirection.down.layerPoints.end == CGPoint(x: 0.5, y: 0))
        #expect(GradientDirection.right.layerPoints.start == CGPoint(x: 0, y: 0.5))
    }
}
