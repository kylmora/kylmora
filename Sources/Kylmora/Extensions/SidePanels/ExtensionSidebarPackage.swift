import Foundation

/// Puts the side panel shim inside an extension that wants one.
///
/// A background worker cannot be reached from outside: WebKit starts it,
/// WebKit owns its world, and nothing the app does can add an API to it after
/// the fact. The only place to add one is the package itself, before the
/// engine loads it -- so Kylmora writes one file into its own copy of the
/// extension and points the manifest's background entry at it, and that file
/// loads the shim and then the extension's own code, untouched.
///
/// This is done to Kylmora's copy in its own folder, never to anything the
/// user supplied, and only for an extension whose manifest asks for a side
/// panel. Everything else is left byte for byte as it arrived.
enum ExtensionSidebarPackage {
    /// What preparing an extension did, for the log and for the pane.
    struct Outcome: Equatable, Sendable {
        let definition: ExtensionSidebarDefinition?
        /// Whether the background entry now loads the shim.
        let wrappedBackground: Bool
        /// Why it does not, when it does not.
        let note: String?

        static let notWanted = Outcome(definition: nil, wrappedBackground: false, note: nil)
    }

    enum Failure: Error, Equatable {
        case noManifest
        case unreadableManifest
        case couldNotWrite(String)
    }

    /// The manifest key Kylmora leaves behind so it can tell its own work from
    /// the extension's, and so a second pass does not wrap the wrapper.
    static let markerKey = "kylmora_side_panel"

    @discardableResult
    static func prepare(folder: URL) throws -> Outcome {
        let manifestURL = folder.appending(path: "manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw Failure.noManifest }
        guard var manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.unreadableManifest
        }
        guard ExtensionSidebarDefinition.wantsSidebarAPI(manifest) else { return .notWanted }

        let definition = ExtensionSidebarDefinition.read(from: manifest)
        // Written every time, not only the first: the shim travels with
        // Kylmora, and an extension installed against an older one should be
        // brought up to date rather than left on it.
        try write(ExtensionSidebarShim.worker, to: folder.appending(path: ExtensionSidebarShim.workerFileName))

        if let marker = manifest[markerKey] as? [String: Any], marker["kind"] != nil {
            // Already wrapped. The shim file has just been refreshed, which is
            // all an existing install needs.
            let wrapped = (marker["kind"] as? String) != "none"
            return Outcome(definition: definition, wrappedBackground: wrapped, note: marker["note"] as? String)
        }

        var marker: [String: Any] = ["version": 1]
        var wrapped = false
        var note: String?

        if var background = manifest["background"] as? [String: Any] {
            if let worker = background["service_worker"] as? String, !worker.isEmpty {
                let isModule = (background["type"] as? String) == "module"
                try write(entryPoint(loading: worker, asModule: isModule),
                          to: folder.appending(path: ExtensionSidebarShim.workerEntryFileName))
                background["service_worker"] = ExtensionSidebarShim.workerEntryFileName
                manifest["background"] = background
                marker["kind"] = "service_worker"
                marker["original"] = worker
                wrapped = true
            } else if let scripts = background["scripts"] as? [String], !scripts.isEmpty {
                background["scripts"] = [ExtensionSidebarShim.workerFileName] + scripts
                manifest["background"] = background
                marker["kind"] = "scripts"
                marker["original"] = scripts
                wrapped = true
            } else {
                marker["kind"] = "none"
                note = "This extension's background page is an HTML file, so the side panel API is available in its "
                    + "panel but not in its background code."
            }
        } else {
            marker["kind"] = "none"
            note = "This extension has no background code, so its panel is all there is to set up."
        }

        if wrapped {
            // `connectNative` is the shim's way back to Kylmora. It reaches
            // Kylmora itself, not any program on the Mac: the name it uses is
            // reserved and answered in process.
            var permissions = (manifest["permissions"] as? [String]) ?? []
            if !permissions.contains("nativeMessaging") {
                permissions.append("nativeMessaging")
                manifest["permissions"] = permissions
            }
        }
        if let note { marker["note"] = note }
        manifest[markerKey] = marker

        let encoded: Data
        do {
            encoded = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw Failure.couldNotWrite(error.localizedDescription)
        }
        do {
            try encoded.write(to: manifestURL, options: .atomic)
        } catch {
            throw Failure.couldNotWrite(error.localizedDescription)
        }
        return Outcome(definition: definition, wrappedBackground: wrapped, note: note)
    }

    /// The file that becomes the extension's background entry: the shim, then
    /// the extension's own code, in that order so the API exists before the
    /// first line that might use it runs.
    static func entryPoint(loading original: String, asModule: Bool) -> String {
        let originalPath = original.hasPrefix("./") ? original : "./" + original
        if asModule {
            return """
            // Written by Kylmora. The extension's own worker is below, loaded
            // unchanged; the line above it is the side panel API this engine
            // does not provide.
            import './\(ExtensionSidebarShim.workerFileName)';
            import '\(originalPath)';
            """
        }
        return """
        // Written by Kylmora. The extension's own worker is loaded second and
        // unchanged; the first line is the side panel API this engine does not
        // provide.
        importScripts('\(ExtensionSidebarShim.workerFileName)');
        importScripts('\(original)');
        """
    }

    private static func write(_ contents: String, to url: URL) throws {
        do {
            try Data(contents.utf8).write(to: url, options: .atomic)
        } catch {
            throw Failure.couldNotWrite(error.localizedDescription)
        }
    }
}
