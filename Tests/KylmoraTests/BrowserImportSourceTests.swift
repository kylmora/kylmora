import Foundation
import Testing
@testable import Kylmora

@Suite("Browser import sources")
struct BrowserImportSourceTests {
    @Test("Safari and Chrome, the two Kylmora names most, are both offered")
    func offersTheHeadliners() {
        let all = BrowserImportSource.allCases
        #expect(all.contains(.safari))
        #expect(all.contains(.chrome))
    }

    @Test("Every source has a non-empty title and sentence name")
    func namesAreFilled() {
        for source in BrowserImportSource.allCases {
            #expect(!source.title.isEmpty)
            #expect(!source.sentenceName.isEmpty)
        }
    }

    @Test("Titles are distinct, so the pop-up has no two identical rows")
    func titlesAreDistinct() {
        let titles = BrowserImportSource.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
    }

    @Test("Chromium sources have a profile folder; the rest do not")
    func chromiumProfiles() {
        for source in [BrowserImportSource.chrome, .edge, .brave] {
            #expect(source.chromiumProfile?.hasSuffix("/Default") == true)
        }
        for source in [BrowserImportSource.safari, .firefox, .htmlFile] {
            #expect(source.chromiumProfile == nil)
        }
    }

    @Test("Bookmarks import from anywhere; history only where it is reachable")
    func supportByKind() {
        for source in BrowserImportSource.allCases {
            #expect(source.supports(.bookmarks))
        }
        for source in [BrowserImportSource.chrome, .edge, .brave, .firefox] {
            #expect(source.supports(.history))
        }
        // Safari's history is macOS-protected; an HTML file holds none.
        #expect(!BrowserImportSource.safari.supports(.history))
        #expect(!BrowserImportSource.htmlFile.supports(.history))
    }

    @Test("Only bookmarks from the export browsers are picked as HTML")
    func picksHTML() {
        for source in [BrowserImportSource.safari, .firefox, .htmlFile] {
            #expect(source.picksHTMLExport(for: .bookmarks))
        }
        for source in [BrowserImportSource.chrome, .edge, .brave] {
            #expect(!source.picksHTMLExport(for: .bookmarks))
        }
        // History is always a data file, never an HTML export.
        for source in BrowserImportSource.allCases {
            #expect(!source.picksHTMLExport(for: .history))
        }
    }

    @Test("A Chromium source opens the panel in its profile folder, under home")
    func startDirectoryIsTheProfileFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for source in [BrowserImportSource.chrome, .edge, .brave] {
            for kind in [ImportKind.bookmarks, .history] {
                let directory = try! #require(source.startDirectory(for: kind))
                #expect(directory.lastPathComponent == "Default")
                #expect(directory.path.hasPrefix(home.path))
            }
        }
    }

    @Test("Firefox history opens in its profiles folder; its bookmarks are exported")
    func firefoxDirectories() {
        #expect(BrowserImportSource.firefox.startDirectory(for: .history)?.lastPathComponent == "Profiles")
        #expect(BrowserImportSource.firefox.startDirectory(for: .bookmarks) == nil)
    }

    @Test("The export sources let the panel open wherever the user last was")
    func exportSourcesHaveNoStartDirectory() {
        #expect(BrowserImportSource.safari.startDirectory(for: .bookmarks) == nil)
        #expect(BrowserImportSource.htmlFile.startDirectory(for: .bookmarks) == nil)
    }

    @Test("Open tabs import only from Firefox")
    func tabsAreFirefoxOnly() {
        #expect(BrowserImportSource.firefox.supports(.tabs))
        for source in [BrowserImportSource.safari, .chrome, .edge, .brave, .htmlFile] {
            #expect(!source.supports(.tabs))
        }
        // Firefox aims the panel at its profiles folder for a session file.
        #expect(BrowserImportSource.firefox.startDirectory(for: .tabs)?.lastPathComponent == "Profiles")
    }

    @Test("Every combination, supported or not, explains itself")
    func instructionsAreFilled() {
        for source in BrowserImportSource.allCases {
            #expect(!source.instructions(for: .bookmarks).isEmpty)
            #expect(!source.instructions(for: .history).isEmpty)
            #expect(!source.instructions(for: .tabs).isEmpty)
        }
    }
}
