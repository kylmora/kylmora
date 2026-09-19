import Foundation

/// Where a host manifest was found.
///
/// Kylmora reads its own folders first and then, unless the user says
/// otherwise, the folders other browsers use. Almost no vendor ships a
/// Kylmora-specific manifest -- 1Password, Bitwarden and iCloud Passwords all
/// write Chrome's -- so borrowing is the difference between those extensions
/// working and not. The manifest's own allow-list still decides who may talk
/// to the host, so borrowing widens which hosts we can see, never who may
/// reach them.
struct NativeMessagingDirectory: Equatable, Sendable {
    /// Shown in Settings: "Kylmora", "Google Chrome", "Firefox".
    let label: String
    let url: URL
    /// False for another browser's folder.
    let isOwn: Bool
    /// Firefox writes `allowed_extensions` instead of `allowed_origins`.
    let usesGeckoIdentifiers: Bool

    init(label: String, url: URL, isOwn: Bool = false, usesGeckoIdentifiers: Bool = false) {
        self.label = label
        self.url = url
        self.isOwn = isOwn
        self.usesGeckoIdentifiers = usesGeckoIdentifiers
    }

    /// The folders searched, in the order they are searched. The first
    /// manifest with a given name wins, so Kylmora's own folders can override
    /// a host another browser installed.
    static func standard(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
                         root: URL = URL(fileURLWithPath: "/", isDirectory: true)) -> [NativeMessagingDirectory] {
        let userSupport = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        let systemSupport = root.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        func hosts(_ base: URL, _ path: String) -> URL {
            base.appending(path: path, directoryHint: .isDirectory).appending(path: "NativeMessagingHosts", directoryHint: .isDirectory)
        }
        return [
            NativeMessagingDirectory(label: "Kylmora", url: hosts(userSupport, "Kylmora"), isOwn: true),
            // Kylmora's own support folder is named after the bundle, as every
            // other folder the app writes is. An app that finds that one first
            // should work too, so both are read.
            NativeMessagingDirectory(label: "Kylmora", url: hosts(userSupport, "com.kylmora.Kylmora"), isOwn: true),
            NativeMessagingDirectory(label: "Kylmora (all users)", url: hosts(systemSupport, "Kylmora"), isOwn: true),
            NativeMessagingDirectory(label: "Kylmora (all users)", url: hosts(systemSupport, "com.kylmora.Kylmora"), isOwn: true),
            NativeMessagingDirectory(label: "Google Chrome", url: hosts(userSupport, "Google/Chrome")),
            NativeMessagingDirectory(label: "Google Chrome (all users)", url: root.appending(path: "Library/Google/Chrome/NativeMessagingHosts", directoryHint: .isDirectory)),
            NativeMessagingDirectory(label: "Chromium", url: hosts(userSupport, "Chromium")),
            NativeMessagingDirectory(label: "Microsoft Edge", url: hosts(userSupport, "Microsoft Edge")),
            NativeMessagingDirectory(label: "Microsoft Edge (all users)", url: root.appending(path: "Library/Microsoft/Edge/NativeMessagingHosts", directoryHint: .isDirectory)),
            NativeMessagingDirectory(label: "Brave", url: hosts(userSupport, "BraveSoftware/Brave-Browser")),
            NativeMessagingDirectory(label: "Vivaldi", url: hosts(userSupport, "Vivaldi")),
            NativeMessagingDirectory(label: "Opera", url: hosts(userSupport, "com.operasoftware.Opera")),
            NativeMessagingDirectory(label: "Arc", url: hosts(userSupport, "Arc/User Data")),
            NativeMessagingDirectory(label: "Firefox", url: hosts(userSupport, "Mozilla"), usesGeckoIdentifiers: true),
            NativeMessagingDirectory(label: "Firefox (all users)", url: hosts(systemSupport, "Mozilla"), usesGeckoIdentifiers: true),
        ]
    }
}

/// One native messaging host, as its manifest describes it.
///
/// The manifest is a small JSON file naming a program and the extensions
/// allowed to talk to it. Kylmora never writes one: the app that wants to be
/// reachable installs it, which is why installing 1Password or Bitwarden is
/// all the setup there is.
struct NativeMessagingHost: Equatable, Sendable, Identifiable {
    let name: String
    let summary: String
    /// The program to run. Resolved, so a relative path in the manifest is
    /// already absolute here.
    let executable: URL
    /// `chrome-extension://<id>/` strings, as Chrome's manifests write them.
    let allowedOrigins: Set<String>
    /// Firefox's `allowed_extensions`: `name@vendor.example` identifiers.
    let allowedExtensionIDs: Set<String>
    let manifestURL: URL
    let directory: NativeMessagingDirectory

    var id: String { name }

    enum Failure: Error, Equatable {
        case unreadable
        case malformed
        /// The `name` inside does not match the file it is in, so the file is
        /// claiming to be a host it is not.
        case nameMismatch(claimed: String, file: String)
        case unsupportedType(String)
        /// Nothing at `path`, or it is a folder.
        case executableMissing(String)
        /// There, but the file mode says nobody may run it.
        case executableNotRunnable(String)
        /// Writable by anyone on the Mac, which makes it a place to plant a
        /// program that Kylmora would then run. Refused.
        case executableWorldWritable(String)
        /// A name with a slash or a `..` in it, which could point the lookup
        /// out of the folder it belongs to.
        case invalidName(String)
    }

    /// Reads and checks one manifest.
    ///
    /// Every check here is a reason to refuse to launch a program, so each one
    /// is its own error: Settings shows the user exactly which one a host
    /// failed, rather than hiding a broken install behind "not found".
    static func read(_ url: URL, in directory: NativeMessagingDirectory,
                     fileManager: FileManager = .default) throws -> NativeMessagingHost {
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.malformed
        }
        guard let name = json["name"] as? String, isValidName(name) else {
            throw Failure.malformed
        }
        let fileName = url.deletingPathExtension().lastPathComponent
        guard name.caseInsensitiveCompare(fileName) == .orderedSame else {
            throw Failure.nameMismatch(claimed: name, file: fileName)
        }
        let type = (json["type"] as? String) ?? "stdio"
        guard type == "stdio" else { throw Failure.unsupportedType(type) }
        guard let path = json["path"] as? String, !path.isEmpty else { throw Failure.malformed }

        // Chrome allows a path relative to the manifest, which is how an app
        // that ships its host beside its manifest writes it.
        let executable = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : url.deletingLastPathComponent().appending(path: path)
        let resolved = executable.resolvingSymlinksInPath().standardizedFileURL
        try checkRunnable(resolved, fileManager: fileManager)

        let origins = Set((json["allowed_origins"] as? [String] ?? []).map { $0.lowercased() })
        let geckoIDs = Set((json["allowed_extensions"] as? [String] ?? []).map { $0.lowercased() })
        return NativeMessagingHost(
            name: name.lowercased(),
            summary: (json["description"] as? String) ?? "",
            executable: resolved,
            allowedOrigins: origins,
            allowedExtensionIDs: geckoIDs,
            manifestURL: url,
            directory: directory
        )
    }

    /// Chrome's rule, and a good one: lowercase letters, digits, underscores,
    /// dots between them. It is also what keeps a name from being a path.
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255, !name.hasPrefix("."), !name.hasSuffix(".") else { return false }
        guard !name.contains("..") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func checkRunnable(_ url: URL, fileManager: FileManager) throws {
        let path = url.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw Failure.executableMissing(path)
        }
        guard fileManager.isExecutableFile(atPath: path) else {
            throw Failure.executableNotRunnable(path)
        }
        let attributes = try? fileManager.attributesOfItem(atPath: path)
        if let permissions = attributes?[.posixPermissions] as? NSNumber,
           permissions.uint16Value & 0o002 != 0 {
            throw Failure.executableWorldWritable(path)
        }
    }

    /// Whether this host's manifest lets `identity` talk to it.
    ///
    /// The manifest is the authority. An extension Kylmora installed from the
    /// Chrome Web Store keeps its store ID, so a host that lists that ID
    /// recognises it here exactly as Chrome would.
    func allows(_ identity: NativeMessagingExtensionIdentity) -> Bool {
        if directory.usesGeckoIdentifiers || !allowedExtensionIDs.isEmpty {
            if !allowedExtensionIDs.isDisjoint(with: identity.geckoIdentifiers) { return true }
        }
        return !allowedOrigins.isDisjoint(with: identity.origins)
    }
}
