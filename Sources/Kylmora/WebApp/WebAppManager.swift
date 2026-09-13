import AppKit
import Foundation

/// Central coordinator for standalone Web Applications (SSBs).
/// Manages open windows, installs, command line arguments, and URL schemes.
@MainActor
final class WebAppManager {
    static let shared = WebAppManager()

    let store: WebAppStore
    weak var session: BrowserSession?
    var onOpenInBrowser: ((URL) -> Void)?

    private(set) var activeWindows: [UUID: WebAppWindowController] = [:]

    init(store: WebAppStore = .shared) {
        self.store = store
    }

    /// Resolves the browsing identity associated with the space ID.
    func resolveIdentity(for spaceID: UUID?) -> Space.Identity {
        guard let spaceID, let session else { return .standard }
        return session.spaces.first { $0.id == spaceID }?.identity ?? .standard
    }

    /// Opens an installed web app in its standalone window.
    @discardableResult
    func open(app: InstalledWebApp, showIfAlreadyOpen: Bool = true) -> WebAppWindowController {
        if let existing = activeWindows[app.id] {
            if showIfAlreadyOpen {
                existing.show()
            }
            return existing
        }

        let identity = resolveIdentity(for: app.spaceID)
        let controller = WebAppWindowController(app: app, identity: identity)

        controller.onOpenInBrowser = { [weak self] url in
            self?.onOpenInBrowser?(url)
        }
        controller.onClose = { [weak self] closedController in
            self?.activeWindows.removeValue(forKey: closedController.app.id)
        }

        activeWindows[app.id] = controller
        controller.show()
        return controller
    }

    /// Opens a standalone chromeless window for any URL immediately.
    @discardableResult
    func openStandalone(url: URL, title: String? = nil, spaceID: UUID? = nil) -> WebAppWindowController {
        let appName = title ?? url.host ?? "Web App"
        let tempApp = InstalledWebApp(
            name: appName,
            url: url,
            spaceID: spaceID
        )
        return open(app: tempApp)
    }

    /// Installs a website as a macOS application and registers it in Kylmora.
    @discardableResult
    func install(
        name: String,
        url: URL,
        spaceID: UUID?,
        icon: NSImage? = nil,
        destinationDirectory: URL? = nil
    ) throws -> InstalledWebApp {
        var app = InstalledWebApp(
            name: name,
            url: url,
            spaceID: spaceID
        )

        let bundleURL = try WebAppGenerator.createAppBundle(
            app: app,
            icon: icon,
            destinationDirectory: destinationDirectory
        )

        app.appBundlePath = bundleURL.path(percentEncoded: false)
        let cachedIcon = AppPaths.supportDirectory.appending(path: "WebApps/\(app.id.uuidString).png")
        if FileManager.default.fileExists(atPath: cachedIcon.path(percentEncoded: false)) {
            app.iconPath = cachedIcon.path(percentEncoded: false)
        }

        store.add(app)
        return app
    }

    /// Uninstalls an installed application.
    func uninstall(id: UUID) {
        if let window = activeWindows[id] {
            window.close()
        }
        store.remove(id: id)
    }

    // MARK: - URL Scheme & CLI Dispatch

    /// Handles incoming custom URL schemes (`kylmora-webapp://open?...` or `kylmora://webapp?...`).
    func handleURLScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "kylmora-webapp" || (scheme == "kylmora" && url.host == "webapp") else {
            return false
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }

        let items = components.queryItems ?? []
        let urlParam = items.first(where: { $0.name == "url" })?.value
        let nameParam = items.first(where: { $0.name == "name" })?.value
        let idParam = items.first(where: { $0.name == "id" })?.value.flatMap(UUID.init)
        let spaceIDParam = items.first(where: { $0.name == "spaceID" })?.value.flatMap(UUID.init)

        if let idParam, let existing = store.app(for: idParam) {
            open(app: existing)
            return true
        }

        if let targetURLString = urlParam, let targetURL = URL(string: targetURLString) {
            let appName = nameParam ?? targetURL.host ?? "Web App"
            let app = InstalledWebApp(
                id: idParam ?? UUID(),
                name: appName,
                url: targetURL,
                spaceID: spaceIDParam
            )
            open(app: app)
            return true
        }

        return false
    }

    /// Handles CLI launch arguments (`--web-app-url <url>`).
    func handleCommandLineArguments(_ args: [String]) -> Bool {
        guard let urlIndex = args.firstIndex(of: "--web-app-url"), urlIndex + 1 < args.count else {
            return false
        }

        let urlString = args[urlIndex + 1]
        guard let url = URL(string: urlString) else { return false }

        var name: String?
        if let nameIndex = args.firstIndex(of: "--web-app-name"), nameIndex + 1 < args.count {
            name = args[nameIndex + 1]
        }

        var id: UUID?
        if let idIndex = args.firstIndex(of: "--web-app-id"), idIndex + 1 < args.count {
            id = UUID(uuidString: args[idIndex + 1])
        }

        var spaceID: UUID?
        if let spaceIndex = args.firstIndex(of: "--web-app-space"), spaceIndex + 1 < args.count {
            spaceID = UUID(uuidString: args[spaceIndex + 1])
        }

        if let id, let existing = store.app(for: id) {
            open(app: existing)
            return true
        }

        let app = InstalledWebApp(
            id: id ?? UUID(),
            name: name ?? url.host ?? "Web App",
            url: url,
            spaceID: spaceID
        )
        open(app: app)
        return true
    }
}
