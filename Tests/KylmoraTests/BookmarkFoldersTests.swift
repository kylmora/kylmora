import Foundation
import Testing
@testable import Kylmora

@Suite("Importing bookmarks with folders")
struct BookmarkFolderImportTests {
    private func entry(_ entries: [BookmarkImporter.Entry], _ host: String) -> BookmarkImporter.Entry? {
        entries.first { $0.url.host() == host }
    }

    @Test("Chrome JSON keeps the folder path, bar contents staying top level")
    func chromeFolders() throws {
        let json = ##"""
        {
          "roots": {
            "bookmark_bar": { "type": "folder", "name": "Bookmarks Bar", "children": [
              { "type": "url", "name": "Top", "url": "https://top.example" },
              { "type": "folder", "name": "News", "children": [
                { "type": "url", "name": "BBC", "url": "https://bbc.example" },
                { "type": "folder", "name": "Tech", "children": [
                  { "type": "url", "name": "Ars", "url": "https://ars.example" }
                ]}
              ]}
            ]},
            "other": { "type": "folder", "name": "Other Bookmarks", "children": [
              { "type": "url", "name": "Loose", "url": "https://loose.example" }
            ]}
          }
        }
        """##
        let entries = try BookmarkImporter.entries(in: Data(json.utf8))
        #expect(entry(entries, "top.example")?.folderPath == [])
        #expect(entry(entries, "bbc.example")?.folderPath == ["News"])
        #expect(entry(entries, "ars.example")?.folderPath == ["News", "Tech"])
        #expect(entry(entries, "loose.example")?.folderPath == ["Other Bookmarks"])
    }

    @Test("Netscape HTML nesting is read back as folder paths")
    func htmlFolders() throws {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><p>
            <DT><A HREF="https://top.example">Top</A>
            <DT><H3>News</H3>
            <DL><p>
                <DT><A HREF="https://bbc.example">BBC</A>
                <DT><H3>Tech</H3>
                <DL><p>
                    <DT><A HREF="https://ars.example">Ars &amp; Co</A>
                </DL><p>
            </DL><p>
        </DL><p>
        """
        let entries = try BookmarkImporter.entries(in: Data(html.utf8))
        #expect(entry(entries, "top.example")?.folderPath == [])
        #expect(entry(entries, "bbc.example")?.folderPath == ["News"])
        #expect(entry(entries, "ars.example")?.folderPath == ["News", "Tech"])
        // Entities in a leaf's text are still decoded.
        #expect(entry(entries, "ars.example")?.title == "Ars & Co")
    }

    @Test("A flat HTML export leaves every bookmark at the top level")
    func flatHTMLStaysFlat() throws {
        let html = """
        <DL><p>
            <DT><A HREF="https://a.example">A</A>
            <DT><A HREF="https://b.example">B</A>
        </DL>
        """
        let entries = try BookmarkImporter.entries(in: Data(html.utf8))
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.folderPath.isEmpty })
    }
}

@Suite("Building the bookmark tree")
struct BookmarkTreeTests {
    private func mark(_ n: Int, folder: String) -> Bookmark {
        Bookmark(id: Int64(n), url: URL(string: "https://site\(n).example")!, title: "n\(n)", created: .now, folder: folder)
    }

    @Test("Bookmarks group into nested folders, leaves and folders in order")
    func nests() {
        let tree = BookmarkTree.build(from: [
            mark(0, folder: ""),
            mark(1, folder: "News"),
            mark(2, folder: "News/Tech"),
            mark(3, folder: "Other")
        ])
        #expect(tree.count == 3)

        guard case .bookmark(let first) = tree[0] else { Issue.record("first is not a bookmark"); return }
        #expect(first.id == 0)

        guard case .folder(let newsName, let news) = tree[1] else { Issue.record("second is not a folder"); return }
        #expect(newsName == "News")
        #expect(news.count == 2)
        guard case .bookmark(let bbc) = news[0] else { Issue.record("News[0] not a bookmark"); return }
        #expect(bbc.id == 1)
        guard case .folder(let techName, let tech) = news[1] else { Issue.record("News[1] not a folder"); return }
        #expect(techName == "Tech")
        #expect(tech.count == 1)

        guard case .folder(let otherName, _) = tree[2] else { Issue.record("third is not a folder"); return }
        #expect(otherName == "Other")
    }

    @Test("An empty folder path yields a flat list of bookmarks")
    func flat() {
        let tree = BookmarkTree.build(from: [mark(0, folder: ""), mark(1, folder: "")])
        #expect(tree.count == 2)
        #expect(tree.allSatisfy { if case .bookmark = $0 { return true } else { return false } })
    }

    @Test("A folder appears once even when many bookmarks share it")
    func sharedFolderIsOneNode() {
        let tree = BookmarkTree.build(from: [
            mark(0, folder: "Work"),
            mark(1, folder: "Work"),
            mark(2, folder: "Work")
        ])
        #expect(tree.count == 1)
        guard case .folder(_, let items) = tree[0] else { Issue.record("not a folder"); return }
        #expect(items.count == 3)
    }
}
