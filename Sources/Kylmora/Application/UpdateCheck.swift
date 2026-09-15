import Foundation

/// The running app's identity, read from the bundle.
enum AppInfo {
    static let name = "Kylmora"
    static let website = URL(string: "https://kylmora.com")!

    /// `CFBundleShortVersionString`, the version people see.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// `CFBundleVersion`, the build number.
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}

/// A dotted version, compared numerically: 0.10.0 is newer than 0.9.1, and
/// 1.0 equals 1.0.0. Anything after a hyphen or plus (a prerelease tag or
/// build metadata) is ignored, so 1.0.0-beta compares as 1.0.0.
struct AppVersion: Comparable, Equatable, CustomStringConvertible {
    let parts: [Int]
    let text: String

    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let numeric = trimmed.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? ""
        parts = numeric.split(separator: ".").map { Int($0) ?? 0 }
        self.text = trimmed
    }

    var description: String { text }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// Asks kylmora.com which version is current, and says whether this is it.
///
/// The site publishes one small JSON document, which is all the check needs:
///
///     { "version": "0.2.0",
///       "url": "https://kylmora.com/download",
///       "notes": "What changed, in a sentence." }
///
/// Nothing about this machine is sent: the request carries no cookies, no
/// cache and no identifier, and it happens only when the user clicks the
/// button. There is no background polling and no automatic download; the
/// answer is a sentence and, when there is a newer version, a link.
enum UpdateCheck {
    static let feedURL = URL(string: "https://kylmora.com/releases/latest.json")!

    struct Release: Decodable, Equatable {
        let version: String
        let url: URL?
        let notes: String?
        let downloadUrl: URL?

        init(version: String, url: URL? = nil, notes: String? = nil, downloadUrl: URL? = nil) {
            self.version = version
            self.url = url
            self.notes = notes
            self.downloadUrl = downloadUrl
        }

        var updatePackageURL: URL? {
            downloadUrl ?? url
        }
    }

    enum Outcome: Equatable {
        /// This is the newest version the site knows about.
        case upToDate(current: String)
        /// The site has a newer one.
        case available(version: String, url: URL?, notes: String?)
        /// No answer, or one that could not be read. The text says why.
        case unreachable(String)

        var release: Release? {
            if case .available(let version, let url, let notes) = self {
                return Release(version: version, url: url, notes: notes)
            }
            return nil
        }
    }

    static func decode(_ data: Data) throws -> Release {
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.version.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "empty version"))
        }
        return release
    }

    /// Pure: compares what the site said with what is running.
    static func outcome(current: String, release: Release) -> Outcome {
        if AppVersion(release.version) > AppVersion(current) {
            return .available(version: release.version, url: release.url, notes: release.notes)
        }
        return .upToDate(current: current)
    }

    static func run(current: String = AppInfo.version, feed: URL = feedURL) async -> Outcome {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(from: feed)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable("kylmora.com did not answer.")
            }
            guard http.statusCode == 200 else {
                return .unreachable("kylmora.com answered \(http.statusCode).")
            }
            let release: Release
            do {
                release = try decode(data)
            } catch {
                return .unreachable("kylmora.com answered with something that is not a release.")
            }
            return outcome(current: current, release: release)
        } catch {
            return .unreachable("Could not reach kylmora.com. Check your connection and try again.")
        }
    }
}
