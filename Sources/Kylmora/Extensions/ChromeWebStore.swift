import Foundation

/// Installing straight from the Chrome Web Store.
///
/// Google publishes no API for other browsers, but the store serves every
/// extension's package from the same update endpoint Chrome polls, keyed by
/// the extension's ID -- the 32-letter string at the end of every store link.
/// That is what other non-Chrome browsers use, and what this uses. It is
/// undocumented and outside the store's terms for other browsers, so it can
/// change or be refused without notice; the package upload path in the pane is
/// the fallback that cannot.
enum ChromeWebStore {
    enum Failure: Error, Equatable {
        case notAStoreLink
        case notFound
        case transport(String)
        case notAPackage
    }

    /// The ID from a store link in either of its forms, or a bare ID.
    ///
    /// IDs are 32 letters from `a` to `p`: a hexadecimal hash written with
    /// letters instead of digits, which is why nothing else looks like one.
    static func extensionID(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isID(text) { return text.lowercased() }
        guard let url = URL(string: text), let host = url.host()?.lowercased() else { return nil }
        guard host == "chromewebstore.google.com" || host == "chrome.google.com" else { return nil }
        // .../detail/<name>/<id> or .../detail/<id>; the ID is the last
        // component that is one, so a trailing slash or query does not matter.
        for component in url.pathComponents.reversed() where isID(component) {
            return component.lowercased()
        }
        return nil
    }

    static func isID(_ text: String) -> Bool {
        text.count == 32 && text.lowercased().allSatisfy { ("a"..."p").contains($0) }
    }

    /// Where the package is fetched from. The version is what Chrome would
    /// send; the endpoint refuses versions too old to run the package.
    static func downloadURL(for id: String) -> URL {
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        components.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: "131.0.0.0"),
            URLQueryItem(name: "acceptformat", value: "crx2,crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&uc")
        ]
        return components.url!
    }

    /// The store's page for the extension, for a link in the pane.
    static func pageURL(for id: String) -> URL {
        URL(string: "https://chromewebstore.google.com/detail/\(id)")!
    }

    /// Downloads the package to a temporary `.crx`. Anonymous: no cookies, no
    /// cache, nothing that could tie the request to a signed-in account.
    static func download(_ id: String) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let (file, response) = try await session.download(from: downloadURL(for: id))
        guard let http = response as? HTTPURLResponse else { throw Failure.transport("No response.") }
        switch http.statusCode {
        case 200: break
        case 204, 404: throw Failure.notFound
        default: throw Failure.transport("The store answered \(http.statusCode).")
        }
        // The endpoint answers 200 with an empty body for an ID it does not
        // know, so the package itself is the test.
        guard let head = FileHandle(forReadingAtPath: file.path(percentEncoded: false))?.readData(ofLength: 4),
              head == Data("Cr24".utf8) else {
            throw Failure.notAPackage
        }
        let destination = FileManager.default.temporaryDirectory.appending(path: "\(id).crx")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }
}
