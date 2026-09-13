import Foundation

/// Installing from Mozilla's add-on site.
///
/// Unlike Google's store, Mozilla publishes an API for this: the add-on's
/// record names the current version's package, an `.xpi`, which is a zip
/// with a WebExtension manifest inside. WebKit reads the same manifest
/// format, so most add-ons load as they are; one that leans on an API
/// Safari lacks reports its errors in the pane.
enum FirefoxAddons {
    enum Failure: Error, Equatable {
        case notAnAddonLink
        case notFound
        case transport(String)
        case noPackage
    }

    /// The add-on's slug from an addons.mozilla.org link, or a bare slug.
    ///
    /// Links look like `https://addons.mozilla.org/en-US/firefox/addon/<slug>/`;
    /// the language and product segments vary and the slug follows `addon`.
    static func slug(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let host = url.host()?.lowercased() {
            guard host == "addons.mozilla.org" else { return nil }
            let parts = url.pathComponents
            guard let index = parts.firstIndex(of: "addon"), parts.indices.contains(index + 1) else { return nil }
            let slug = parts[index + 1]
            return isSlug(slug) ? slug : nil
        }
        return isSlug(text) ? text : nil
    }

    static func isSlug(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 100 && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." || $0 == "@" || $0 == "{" || $0 == "}" }
    }

    static func recordURL(for slug: String) -> URL {
        URL(string: "https://addons.mozilla.org/api/v5/addons/addon/\(slug)/")!
    }

    static func pageURL(for slug: String) -> URL {
        URL(string: "https://addons.mozilla.org/firefox/addon/\(slug)/")!
    }

    /// The package's address, read from the add-on's record.
    static func packageURL(fromRecord data: Data) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["current_version"] as? [String: Any] else { return nil }
        // The API has carried the file as `file` and, earlier, as `files`.
        let file = version["file"] as? [String: Any] ?? (version["files"] as? [[String: Any]])?.first
        return (file?["url"] as? String).flatMap { URL(string: $0) }
    }

    /// Downloads the current package to a temporary `.xpi`. Anonymous.
    static func download(_ slug: String) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let (record, response) = try await session.data(from: recordURL(for: slug))
        guard let http = response as? HTTPURLResponse else { throw Failure.transport("No response.") }
        switch http.statusCode {
        case 200: break
        case 404: throw Failure.notFound
        default: throw Failure.transport("The add-on site answered \(http.statusCode).")
        }
        guard let packageURL = packageURL(fromRecord: record) else { throw Failure.noPackage }

        let (file, packageResponse) = try await session.download(from: packageURL)
        guard (packageResponse as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.noPackage }
        let destination = FileManager.default.temporaryDirectory.appending(path: "\(slug).xpi")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }
}
