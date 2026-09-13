import AppKit

/// Renders a provider's declarative options into an `NSMenu`.
///
/// One renderer for every provider, so a checkbox in the GitHub menu and a
/// checkbox in the RSS menu are the same checkbox. The target is a small object
/// owned by the menu itself rather than the view controller, because a folder's
/// context menu outlives the click that built it and an `NSMenuItem` target is
/// unowned.
@MainActor
enum LiveFolderOptionsMenu {
    static func menu(
        for options: [LiveFolderOption],
        title: String = "",
        handler: @escaping (LiveFolderOptionChange) -> Void
    ) -> NSMenu {
        let menu = NSMenu(title: title)
        let target = OptionTarget(handler: handler)
        // The target has to be kept alive by something; the menu is the only
        // object here with the right lifetime.
        menu.delegate = target
        fill(menu, with: options, target: target)
        return menu
    }

    private static func fill(_ menu: NSMenu, with options: [LiveFolderOption], target: OptionTarget) {
        for option in options {
            switch option {
            case .separator:
                menu.addItem(.separator())

            case .action(let key, let title):
                let item = NSMenuItem(title: title, action: #selector(OptionTarget.trigger(_:)), keyEquivalent: "")
                item.target = target
                item.representedObject = LiveFolderOptionChange(key: key, value: .triggered)
                menu.addItem(item)

            case .toggle(let key, let title, let isOn):
                let item = NSMenuItem(title: title, action: #selector(OptionTarget.trigger(_:)), keyEquivalent: "")
                item.target = target
                item.state = isOn ? .on : .off
                item.representedObject = LiveFolderOptionChange(key: key, value: .bool(!isOn))
                menu.addItem(item)

            case .choice(let key, let title, let values, let selected):
                let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: title)
                for value in values {
                    let item = NSMenuItem(
                        title: value.title,
                        action: #selector(OptionTarget.trigger(_:)),
                        keyEquivalent: ""
                    )
                    item.target = target
                    item.state = value.value == selected ? .on : .off
                    item.representedObject = LiveFolderOptionChange(key: key, value: .string(value.value))
                    submenu.addItem(item)
                }
                parent.submenu = submenu
                menu.addItem(parent)

            case .submenu(let title, let items):
                let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: title)
                fill(submenu, with: items, target: target)
                parent.submenu = submenu
                menu.addItem(parent)
            }
        }
    }
}

/// Holds the handler and converts a click back into a typed change.
@MainActor
private final class OptionTarget: NSObject, NSMenuDelegate {
    private let handler: (LiveFolderOptionChange) -> Void

    init(handler: @escaping (LiveFolderOptionChange) -> Void) {
        self.handler = handler
    }

    @objc func trigger(_ sender: NSMenuItem) {
        guard let change = sender.representedObject as? LiveFolderOptionChange else { return }
        handler(change)
    }
}
