import Foundation

/// Persists the list of installed web applications.
@MainActor
final class WebAppStore {
    static let shared = WebAppStore()

    private let fileURL: URL
    private(set) var apps: [InstalledWebApp] = []
    var onChange: (() -> Void)?

    init(fileURL: URL = AppPaths.supportDirectory.appending(path: "webapps.json")) {
        self.fileURL = fileURL
        load()
    }

    func load() {
        guard let loaded = JSONFile<[InstalledWebApp]>(fileURL).load() else {
            return
        }
        self.apps = loaded
    }

    func save() {
        try? JSONFile<[InstalledWebApp]>(fileURL).save(apps)
        onChange?()
    }

    func add(_ app: InstalledWebApp) {
        if let idx = apps.firstIndex(where: { $0.id == app.id }) {
            apps[idx] = app
        } else {
            apps.append(app)
        }
        save()
    }

    func remove(id: UUID) {
        if let app = app(for: id), let bundlePath = app.appBundlePath {
            try? FileManager.default.removeItem(atPath: bundlePath)
        }
        if let app = app(for: id), let iconPath = app.iconPath {
            try? FileManager.default.removeItem(atPath: iconPath)
        }
        apps.removeAll { $0.id == id }
        save()
    }

    func app(for id: UUID) -> InstalledWebApp? {
        apps.first { $0.id == id }
    }

    func app(for url: URL) -> InstalledWebApp? {
        guard let host = url.host?.lowercased() else { return nil }
        return apps.first { $0.url.host?.lowercased() == host }
    }
}
