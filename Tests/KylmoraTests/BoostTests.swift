import Foundation
import Testing
@testable import Kylmora

private func temporaryDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "kylmora-boost-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("Per-Site Boosts and Universal Dark Mode")
@MainActor
struct BoostTests {
    @Test("Boost model encodes and decodes JSON correctly")
    func boostCodable() throws {
        let boost = Boost(
            id: UUID(),
            host: "github.com",
            isEnabled: true,
            isDarkModeEnabled: true,
            customCSS: "body { background: #000; }",
            customJS: "console.log('boosted');"
        )

        let data = try JSONEncoder().encode(boost)
        let decoded = try JSONDecoder().decode(Boost.self, from: data)

        #expect(decoded.id == boost.id)
        #expect(decoded.host == "github.com")
        #expect(decoded.isEnabled == true)
        #expect(decoded.isDarkModeEnabled == true)
        #expect(decoded.customCSS == "body { background: #000; }")
        #expect(decoded.customJS == "console.log('boosted');")
    }

    @Test("BoostStore saves and retrieves per-site boosts")
    func boostStoreCRUD() {
        let tempDir = temporaryDirectory()
        let store = BoostStore(folder: tempDir)

        #expect(store.boosts.isEmpty)
        #expect(store.boost(for: "wikipedia.org") == nil)

        // Save new boost
        var boost = Boost(host: "wikipedia.org")
        boost.customCSS = ".mw-body { font-size: 18px; }"
        store.save(boost)

        #expect(store.boosts.count == 1)
        #expect(store.boost(for: "wikipedia.org")?.customCSS == ".mw-body { font-size: 18px; }")
        #expect(store.boost(for: "WIKIPEDIA.ORG")?.customCSS == ".mw-body { font-size: 18px; }")
        #expect(store.boost(for: "en.wikipedia.org")?.customCSS == ".mw-body { font-size: 18px; }")

        // Toggle dark mode
        let isDark = store.toggleDarkMode(for: "wikipedia.org")
        #expect(isDark == true)
        #expect(store.boost(for: "wikipedia.org")?.isDarkModeEnabled == true)

        let isDarkAgain = store.toggleDarkMode(for: "wikipedia.org")
        #expect(isDarkAgain == false)
        #expect(store.boost(for: "wikipedia.org")?.isDarkModeEnabled == false)

        // Delete boost
        if let current = store.boost(for: "wikipedia.org") {
            store.remove(id: current.id)
        }
        #expect(store.boosts.isEmpty)
        #expect(store.boost(for: "wikipedia.org") == nil)
    }

    @Test("BoostCoordinator bootstrap script handles empty and populated boosts")
    func boostCoordinatorScript() {
        let emptyScript = BoostCoordinator.bootstrapSource(boosts: [])
        #expect(emptyScript.contains("/* kylmora.boost */"))

        let b1 = Boost(
            host: "news.ycombinator.com",
            isEnabled: true,
            isDarkModeEnabled: true,
            customCSS: "td { font-family: -apple-system; }",
            customJS: "document.title = 'HN';"
        )
        let populatedScript = BoostCoordinator.bootstrapSource(boosts: [b1])
        #expect(populatedScript.contains("news.ycombinator.com"))
        #expect(populatedScript.contains("kylmora-boost-dark-mode"))
        #expect(populatedScript.contains("kylmora-boost-style"))
        #expect(populatedScript.contains(BoostCoordinator.marker))
    }

    @Test("Universal Dark Mode CSS preserves media elements")
    func darkModeCSSPreservation() {
        let css = BoostCoordinator.darkModeCSS
        #expect(css.contains("filter: invert(90%) hue-rotate(180deg)"))
        #expect(css.contains("img, video, canvas, svg, picture"))
        #expect(css.contains("filter: invert(100%) hue-rotate(180deg)"))
    }
}
