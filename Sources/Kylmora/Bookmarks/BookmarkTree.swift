import Foundation

/// A bookmark, or a folder of bookmarks and sub-folders.
///
/// The database hands back a flat `[Bookmark]`, each carrying its `/`-joined
/// folder path. This rebuilds the tree from that flat list so the
/// Bookmarks menu and the bookmarks bar can both show the folders the user
/// imported instead of one long list.
enum BookmarkTree: Equatable {
    case bookmark(Bookmark)
    case folder(name: String, items: [BookmarkTree])

    /// Groups bookmarks into a tree by their folder path, keeping the order
    /// they arrive in: a folder takes the place of its first child, and leaves
    /// stay in list order. An empty path is a top-level bookmark; "News/Tech"
    /// nests a Tech folder inside a News folder.
    static func build(from bookmarks: [Bookmark]) -> [BookmarkTree] {
        let root = Node()
        for bookmark in bookmarks {
            let path = bookmark.folder.split(separator: "/").map(String.init)
            root.insert(bookmark, path: path[...])
        }
        return root.tree()
    }

    /// A mutable builder: enums are awkward to grow in place, so the tree is
    /// assembled here and frozen into `BookmarkTree` at the end.
    private final class Node {
        private enum Slot { case leaf(Bookmark); case folder(String) }
        private var slots: [Slot] = []
        private var children: [String: Node] = [:]

        func insert(_ bookmark: Bookmark, path: ArraySlice<String>) {
            guard let name = path.first else {
                slots.append(.leaf(bookmark))
                return
            }
            if children[name] == nil {
                children[name] = Node()
                slots.append(.folder(name))
            }
            children[name]?.insert(bookmark, path: path.dropFirst())
        }

        func tree() -> [BookmarkTree] {
            slots.map { slot in
                switch slot {
                case .leaf(let bookmark): return .bookmark(bookmark)
                case .folder(let name): return .folder(name: name, items: children[name]?.tree() ?? [])
                }
            }
        }
    }
}
