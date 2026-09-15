import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("Versions compare numerically")
struct AppVersionTests {
    @Test("Each dotted part is a number, not a string", arguments: [
        ("0.9.1", "0.10.0"), ("1.0", "1.0.1"), ("0.1.0", "0.2.0"), ("2", "10"), ("1.9.9", "2.0.0")
    ])
    func ordering(older: String, newer: String) {
        #expect(AppVersion(older) < AppVersion(newer))
        #expect(!(AppVersion(newer) < AppVersion(older)))
    }

    @Test("Missing parts are zero, and tags after a hyphen are ignored")
    func equivalents() {
        #expect(AppVersion("1.0") == AppVersion("1.0.0"))
        #expect(AppVersion("1.0.0-beta.2") == AppVersion("1.0.0"))
        #expect(AppVersion(" 0.1.0\n") == AppVersion("0.1.0"))
    }
}

@Suite("The update check reads the site's answer")
struct UpdateCheckTests {
    private func release(_ json: String) throws -> UpdateCheck.Release {
        try UpdateCheck.decode(Data(json.utf8))
    }

    @Test("A newer version on the site is reported with its link and notes")
    func newer() throws {
        let latest = try release(#"{"version":"0.2.0","url":"https://kylmora.com/download","notes":"Faster tabs."}"#)
        #expect(UpdateCheck.outcome(current: "0.1.0", release: latest)
            == .available(UpdateCheck.Release(version: "0.2.0", url: URL(string: "https://kylmora.com/download"), notes: "Faster tabs.")))
    }

    @Test("The same version, or an older one on the site, means up to date")
    func current() throws {
        let same = try release(#"{"version":"0.1.0"}"#)
        #expect(UpdateCheck.outcome(current: "0.1.0", release: same) == .upToDate(current: "0.1.0"))
        let older = try release(#"{"version":"0.0.9","url":null}"#)
        #expect(UpdateCheck.outcome(current: "0.1.0", release: older) == .upToDate(current: "0.1.0"))
    }

    @Test("An answer that is not a release is refused")
    func malformed() {
        #expect(throws: (any Error).self) { try UpdateCheck.decode(Data("not json".utf8)) }
        #expect(throws: (any Error).self) { try UpdateCheck.decode(Data(#"{"url":"https://x"}"#.utf8)) }
        #expect(throws: (any Error).self) { try UpdateCheck.decode(Data(#"{"version":""}"#.utf8)) }
    }

    @Test("An unreachable feed is a sentence, not a crash")
    func unreachable() async {
        let outcome = await UpdateCheck.run(current: "0.1.0", feed: URL(string: "http://127.0.0.1:1/latest.json")!)
        guard case .unreachable(let reason) = outcome else {
            Issue.record("expected unreachable, got \(outcome)")
            return
        }
        #expect(reason.contains("kylmora.com"))
    }
}

@Suite("The About pane")
@MainActor
struct AboutPaneTests {
    @Test("Is one of the Settings panes, last in the toolbar")
    func registered() {
        #expect(SettingsWindowController.Pane.allCases.last == .about)
        #expect(SettingsWindowController.Pane.about.title == "About")
    }

    @Test("Shows each outcome as a sentence, with a download button only when there is somewhere to go")
    func statusLine() {
        let pane = AboutSettingsViewController()
        _ = pane.view
        pane.show(.upToDate(current: "0.1.0"))
        #expect(pane.updateStatusText.contains("latest version"))
        #expect(!pane.showsDownloadButton)

        pane.show(.available(UpdateCheck.Release(version: "0.2.0", url: URL(string: "https://kylmora.com/download"), notes: "Faster tabs.")))
        #expect(pane.updateStatusText.contains("0.2.0"))
        #expect(pane.updateStatusText.contains("Faster tabs."))
        #expect(pane.showsDownloadButton)

        pane.show(.available(UpdateCheck.Release(version: "0.3.0", url: nil, notes: nil)))
        #expect(!pane.showsDownloadButton)

        pane.show(.unreachable("Could not reach kylmora.com."))
        #expect(pane.updateStatusText == "Could not reach kylmora.com.")
    }
}
