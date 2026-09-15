import Foundation

/// Which buttons the bar above the page shows, and in what order.
///
/// Buttons are named by their labels, which are also their accessibility
/// labels, so a layout written by one build still applies to the next: a
/// label this build does not know is ignored, and a button the layout does
/// not mention takes its default place at the end.
struct ToolbarLayout: Codable, Equatable, Sendable {
    /// Labels in the order they appear. Empty means the default order.
    var order: [String] = []
    /// Labels not shown.
    var hidden: Set<String> = []

    static let `default` = ToolbarLayout()

    /// Every button the bar can hold, in default order, with its symbol, so
    /// Settings can list them without a window.
    static let catalog: [(label: String, symbolName: String)] = [
        ("Shield", "checkmark.shield.fill"),
        ("Translate Page", "translate"),
        ("Reader Mode", "doc.plaintext"),
        ("Reading List", "eyeglasses"),
        ("Site Settings", "gearshape.fill"),
        ("Share", "square.and.arrow.up"),
        ("Find in Page", "magnifyingglass"),
        ("Add Bookmark", "bookmark"),
        ("Page Menu", "macwindow"),
        ("Extensions", "puzzlepiece.extension")
    ]

    var isDefault: Bool { order.isEmpty && hidden.isEmpty }

    /// Applies the layout to the bar's actions: the saved order first, then
    /// anything new in its default place, minus the hidden ones.
    func arrange<T>(_ actions: [T], label: (T) -> String) -> [T] {
        var remaining = actions
        var arranged: [T] = []
        for name in order {
            guard let index = remaining.firstIndex(where: { label($0) == name }) else { continue }
            arranged.append(remaining.remove(at: index))
        }
        arranged.append(contentsOf: remaining)
        return arranged.filter { !hidden.contains(label($0)) }
    }

    /// The labels as the editor lists them: saved order, then the rest.
    var editorOrder: [String] {
        arrange(Self.catalog.map(\.label), label: { $0 }) + Self.catalog.map(\.label).filter { hidden.contains($0) && !order.contains($0) }
    }

    mutating func move(_ name: String, by delta: Int) {
        var names = fullOrder()
        guard let index = names.firstIndex(of: name) else { return }
        let target = index + delta
        guard names.indices.contains(target) else { return }
        names.swapAt(index, target)
        order = names
    }

    mutating func setHidden(_ name: String, _ isHidden: Bool) {
        if isHidden { hidden.insert(name) } else { hidden.remove(name) }
    }

    /// Every catalog label in current order, hidden ones included.
    func fullOrder() -> [String] {
        var remaining = Self.catalog.map(\.label)
        var names: [String] = []
        for name in order {
            guard let index = remaining.firstIndex(of: name) else { continue }
            names.append(remaining.remove(at: index))
        }
        return names + remaining
    }
}

extension Notification.Name {
    static let toolbarLayoutDidChange = Notification.Name("toolbarLayoutDidChange")
}
