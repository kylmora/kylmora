import AppKit
import UniformTypeIdentifiers

/// Where a picture a user chose for a space lives.
///
/// Copied into Application Support rather than referenced where it was found.
/// A space icon is browser chrome: it is drawn on every window, in every menu
/// and on every launch, and a file the user later moved, renamed, or picked
/// out of a disk image that is no longer mounted would leave the browser
/// showing a hole. Copying is also what keeps the session file portable --
/// it names a file this store owns, not a path into somebody's home folder.
@MainActor
final class SpaceIconStore {
    /// The one every icon draws from.
    ///
    /// A `var` so a test can point it at a directory of its own: the paths
    /// worth testing here are the ones that *delete* files -- replacing an
    /// icon, deleting the space or folder wearing it -- and a test that could
    /// only prove those against the real Application Support folder would be a
    /// test nobody dares run.
    static var shared = SpaceIconStore()

    /// What a file has to be to become a space icon.
    ///
    /// SVG is in the list because it is what a logo usually arrives as, and
    /// AppKit has drawn SVG since Big Sur; PDF for the same reason. The raster
    /// types are the ones a screenshot or an export actually produces.
    nonisolated static let allowedTypes: [UTType] = [.png, .svg, .jpeg, .tiff, .heic, .gif, .pdf]

    /// The biggest file that may become an icon.
    ///
    /// This is drawn at ten to twenty-eight points. Eight megabytes is already
    /// far past anything that can tell at that size, and the cap is really
    /// about what gets copied into Application Support and decoded on every
    /// launch: a 200MB TIFF dragged in by accident would make the browser slow
    /// to start and never say why.
    nonisolated static let maximumFileSize = 8 * 1024 * 1024

    enum Failure: LocalizedError {
        case unsupportedType
        case tooLarge
        case unreadable

        var errorDescription: String? {
            switch self {
            case .unsupportedType:
                return "That kind of file cannot be used as an icon."
            case .tooLarge:
                return "That image is too large to use as an icon."
            case .unreadable:
                return "That image could not be read."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .unsupportedType:
                return "Choose a PNG, SVG, JPEG, TIFF, HEIC, GIF or PDF."
            case .tooLarge:
                let megabytes = SpaceIconStore.maximumFileSize / 1024 / 1024
                return "Icons are drawn at a few points across. Choose a file under \(megabytes)MB."
            case .unreadable:
                return "The file may be damaged, or it may not be the kind of image its name says it is."
            }
        }
    }

    /// Decoded pictures, by file name.
    ///
    /// Held because `image(named:)` is called from every menu build and every
    /// sidebar rebuild -- several times per space switch -- and decoding a PNG
    /// each time is real work where filling an oval was not. Small by
    /// construction: one entry per space that has a picture.
    private var cache: [String: NSImage] = [:]

    private let directory: URL
    private let fileManager: FileManager

    /// The default store writes into Application Support. Tests pass a
    /// directory of their own rather than writing into the user's.
    init(directory: URL = AppPaths.supportDirectory.appending(path: "SpaceIcons", directoryHint: .isDirectory),
         fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Copies `url` in and returns the name the icon is stored under.
    ///
    /// The name is fresh every time rather than the file's own: two spaces
    /// given `logo.png` from different folders must not end up sharing one
    /// file, and replacing a space's icon with a different `logo.png` must not
    /// leave the old picture cached under the same name.
    @discardableResult
    func importIcon(from url: URL) throws -> String {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        guard let type, Self.allowedTypes.contains(where: { type.conforms(to: $0) }) else {
            throw Failure.unsupportedType
        }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maximumFileSize else { throw Failure.tooLarge }

        // Decoded before it is kept, not after. A file that AppKit cannot draw
        // is refused while the user is still looking at a file picker and can
        // choose another one -- rather than accepted, written to disk, and
        // discovered to be a hole the next time a menu opens.
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
            throw Failure.unreadable
        }

        let name = "\(UUID().uuidString).\(url.pathExtension.lowercased())"
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.copyItem(at: url, to: directory.appending(path: name))
        cache[name] = image
        return name
    }

    /// The picture, or nil if the file has gone. Callers draw the dot instead.
    func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let image = NSImage(contentsOf: directory.appending(path: name)) else { return nil }
        cache[name] = image
        return image
    }

    /// Drops one picture. Called when an icon is replaced and when the space
    /// holding it is deleted -- nothing else refers to these files, so a name
    /// no space carries is a file nothing will ever draw again.
    func remove(named name: String) {
        cache[name] = nil
        try? fileManager.removeItem(at: directory.appending(path: name))
    }

    /// Deletes every stored picture that no space claims.
    ///
    /// Belt and braces for the ways a name can be dropped without this store
    /// hearing about it: a session file restored from a backup, a space
    /// removed by a sync merge, a crash between writing the file and saving
    /// the session that named it.
    func removeEveryIconExcept(_ kept: Set<String>) {
        let contents = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in contents where !kept.contains(name) {
            remove(named: name)
        }
    }
}
