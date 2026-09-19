import Foundation

/// The hosts installed on this Mac.
///
/// Scanning is cheap -- a handful of folders holding a few small files -- but
/// it is file work, so it happens off the main actor and the answer is kept
/// until something asks for a fresh one. A host installed while Kylmora is
/// running is found the next time the list is refreshed, which Settings does
/// when it appears and every connection attempt does on a miss.
actor NativeMessagingHostRegistry {
    /// A manifest that would not load, kept so Settings can say why.
    struct Rejection: Equatable, Sendable {
        let manifestURL: URL
        let directory: NativeMessagingDirectory
        let reason: String
    }

    struct Scan: Equatable, Sendable {
        var hosts: [NativeMessagingHost] = []
        var rejections: [Rejection] = []
    }

    private let directories: [NativeMessagingDirectory]
    private var cached: Scan?

    init(directories: [NativeMessagingDirectory] = NativeMessagingDirectory.standard()) {
        self.directories = directories
    }

    /// Every host found, Kylmora's own folders first.
    func scan(includingOtherBrowsers: Bool = true, refreshing: Bool = false) -> Scan {
        if !refreshing, let cached { return filtered(cached, includingOtherBrowsers: includingOtherBrowsers) }
        var found = Scan()
        var seen: Set<String> = []
        for directory in directories {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory.url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for file in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where file.pathExtension.lowercased() == "json" {
                do {
                    let host = try NativeMessagingHost.read(file, in: directory)
                    // First folder wins: Kylmora's own before anyone else's.
                    guard seen.insert(host.name).inserted else { continue }
                    found.hosts.append(host)
                } catch {
                    found.rejections.append(Rejection(
                        manifestURL: file,
                        directory: directory,
                        reason: Self.describe(error)
                    ))
                }
            }
        }
        cached = found
        return filtered(found, includingOtherBrowsers: includingOtherBrowsers)
    }

    /// The host by that name, rescanning once if it is not in the cache: an
    /// app installed after launch should work without restarting Kylmora.
    func host(named name: String, includingOtherBrowsers: Bool = true) -> NativeMessagingHost? {
        let lowered = name.lowercased()
        if let host = scan(includingOtherBrowsers: includingOtherBrowsers).hosts.first(where: { $0.name == lowered }) {
            return host
        }
        return scan(includingOtherBrowsers: includingOtherBrowsers, refreshing: true).hosts.first { $0.name == lowered }
    }

    func invalidate() { cached = nil }

    private func filtered(_ scan: Scan, includingOtherBrowsers: Bool) -> Scan {
        guard !includingOtherBrowsers else { return scan }
        return Scan(
            hosts: scan.hosts.filter { $0.directory.isOwn },
            rejections: scan.rejections.filter { $0.directory.isOwn }
        )
    }

    /// Plain English, because these lines are shown in Settings.
    static func describe(_ error: Error) -> String {
        guard let failure = error as? NativeMessagingHost.Failure else { return error.localizedDescription }
        switch failure {
        case .unreadable:
            return "The file could not be read."
        case .malformed:
            return "The file is not a native messaging manifest."
        case .nameMismatch(let claimed, let file):
            return "The manifest calls itself \(claimed) but the file is named \(file).json."
        case .unsupportedType(let type):
            return "Kylmora speaks the stdio protocol; this host asks for \(type)."
        case .executableMissing(let path):
            return "Nothing to run at \(path)."
        case .executableNotRunnable(let path):
            return "\(path) is not executable."
        case .executableWorldWritable(let path):
            return "\(path) can be changed by anyone on this Mac, so Kylmora will not run it."
        case .invalidName(let name):
            return "\(name) is not a valid host name."
        }
    }
}
