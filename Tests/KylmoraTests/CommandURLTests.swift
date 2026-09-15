import AppKit
import Foundation
import Testing
@testable import Kylmora

@Suite("The kylmora:// command scheme and its tool")
@MainActor
struct CommandURLTests {
    @Test("Addresses parse, and round-trip through the address the tool prints")
    func parsing() {
        let tab = CommandURL(url: URL(string: "kylmora://tab?url=https://a.example/x?y%3D1&space=Work&background=1")!)
        #expect(tab == .tab(URL(string: "https://a.example/x?y=1")!, space: "Work", background: true))
        #expect(CommandURL(url: URL(string: "kylmora://tab?url=notaurl")!) == nil)
        #expect(CommandURL(url: URL(string: "kylmora://space?name=Personal")!) == .space("Personal"))
        #expect(CommandURL(url: URL(string: "kylmora://command?id=print-page")!) == .command("print-page"))
        #expect(CommandURL(url: URL(string: "kylmora://new-tab")!) == .newTab)
        #expect(CommandURL(url: URL(string: "kylmora://open?url=https://a.example")!) == nil, "open belongs to the iPhone link")
        #expect(CommandURL(url: URL(string: "https://kylmora.com")!) == nil)

        for command in [CommandURL.tab(URL(string: "https://a.example/p q")!, space: "Work Space", background: false), .space("Work"), .command("print-page"), .newTab] {
            #expect(CommandURL(url: command.url) == command, "\(command.url)")
        }
    }

    @Test("The tool prints the same addresses the app understands")
    func tool() throws {
        let tool = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Tools/kylmora")
        func run(_ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let printed = try run(["url", "open", "https://a.example/p q", "--space", "Work", "--background"])
        #expect(CommandURL(url: URL(string: printed)!) == .tab(URL(string: "https://a.example/p%20q")!, space: "Work", background: true))
        #expect(CommandURL(url: URL(string: try run(["url", "space", "Personal"]))!) == .space("Personal"))
        #expect(CommandURL(url: URL(string: try run(["url", "command", "print-page"]))!) == .command("print-page"))
        #expect(CommandURL(url: URL(string: try run(["url", "new-tab"]))!) == .newTab)
    }

    @Test("Commands act on the session: a tab in a named Space, a Space switch, a miss")
    func performing() {
        let (session, _) = TestSession.make()
        let home = session.activeSpace
        let work = session.addSpace(named: "Work")
        session.selectSpace(home)
        #expect(home !== work)

        #expect(CommandURL.tab(URL(string: "https://a.example/")!, space: "work", background: true).perform(in: session, window: nil))
        #expect(work.tabs.contains { $0.url.host() == "a.example" }, "opened in the named Space, case-insensitively")
        #expect(session.activeSpace === work)

        #expect(CommandURL.space(home.name).perform(in: session, window: nil))
        #expect(session.activeSpace === home)
        #expect(!CommandURL.space("Nope").perform(in: session, window: nil))
        #expect(!CommandURL.command("print-page").perform(in: session, window: nil), "no window, nothing to run in")

        let before = home.tabs.count
        #expect(CommandURL.newTab.perform(in: session, window: nil))
        #expect(home.tabs.count == before + 1)
    }

    @Test("Duplicate tabs are marked, both copies")
    func duplicates() {
        let (session, _) = TestSession.make()
        let space = session.activeSpace
        let a1 = session.newTab(url: URL(string: "https://a.example/")!)
        _ = session.newTab(url: URL(string: "https://b.example/")!)
        let a2 = session.newTab(url: URL(string: "https://a.example/")!)
        let marked = session.duplicateTabIDs(in: space)
        #expect(marked == [a1.id, a2.id])
    }
}
