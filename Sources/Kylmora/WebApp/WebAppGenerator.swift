import AppKit
import Foundation

/// Generates lightweight, standalone macOS `.app` bundles for installed web applications.
enum WebAppGenerator {
    static var defaultApplicationsDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let appsDir = home.appending(path: "Applications/Kylmora Apps", directoryHint: .isDirectory)
        return appsDir
    }

    /// Generates a macOS application bundle for the given web application.
    @discardableResult
    static func createAppBundle(
        app: InstalledWebApp,
        icon: NSImage? = nil,
        destinationDirectory: URL? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        let baseDir = destinationDirectory ?? defaultApplicationsDirectory

        try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let safeName = sanitizeFilename(app.name)
        let bundleURL = baseDir.appending(path: "\(safeName).app", directoryHint: .isDirectory)

        // If an old bundle exists, remove it cleanly first
        if fileManager.fileExists(atPath: bundleURL.path(percentEncoded: false)) {
            try? fileManager.removeItem(at: bundleURL)
        }

        let contentsURL = bundleURL.appending(path: "Contents", directoryHint: .isDirectory)
        let macosURL = contentsURL.appending(path: "MacOS", directoryHint: .isDirectory)
        let resourcesURL = contentsURL.appending(path: "Resources", directoryHint: .isDirectory)

        try fileManager.createDirectory(at: macosURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        // 1. Info.plist
        let bundleID = "com.kylmora.webapp.\(safeBundleID(from: app.name))-\(app.id.uuidString.prefix(8).lowercased())"
        let plistContent = generateInfoPlist(app: app, bundleID: bundleID)
        let plistURL = contentsURL.appending(path: "Info.plist")
        try plistContent.write(to: plistURL, atomically: true, encoding: .utf8)

        // 2. Launcher executable script
        let launcherScript = generateLauncherScript(app: app)
        let launcherURL = macosURL.appending(path: "launcher")
        try launcherScript.write(to: launcherURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherURL.path(percentEncoded: false))

        // 3. App Icon
        let iconImage = generateIcon(name: app.name, sourceImage: icon)
        if let pngData = pngData(for: iconImage) {
            let iconURL = resourcesURL.appending(path: "AppIcon.icns")
            try? pngData.write(to: iconURL)
            let iconPngURL = resourcesURL.appending(path: "AppIcon.png")
            try? pngData.write(to: iconPngURL)

            // Cache in Kylmora App Support
            let cacheDir = AppPaths.supportDirectory.appending(path: "WebApps", directoryHint: .isDirectory)
            try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let cachedIconURL = cacheDir.appending(path: "\(app.id.uuidString).png")
            try? pngData.write(to: cachedIconURL)
        }

        return bundleURL
    }

    // MARK: - Helpers

    static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Web App" : cleaned
    }

    static func safeBundleID(from name: String) -> String {
        let valid = CharacterSet.alphanumerics
        let chars = name.unicodeScalars.filter { valid.contains($0) }
        let id = String(String.UnicodeScalarView(chars)).lowercased()
        return id.isEmpty ? "app" : id
    }

    private static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func generateInfoPlist(app: InstalledWebApp, bundleID: String) -> String {
        let escapedName = xmlEscape(app.name)
        let escapedURL = xmlEscape(app.url.absoluteString)
        let spaceID = app.spaceID?.uuidString ?? ""

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>CFBundleInfoDictionaryVersion</key>
            <string>6.0</string>
            <key>CFBundleExecutable</key>
            <string>launcher</string>
            <key>CFBundleIdentifier</key>
            <string>\(bundleID)</string>
            <key>CFBundleName</key>
            <string>\(escapedName)</string>
            <key>CFBundleDisplayName</key>
            <string>\(escapedName)</string>
            <key>CFBundleIconFile</key>
            <string>AppIcon</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>CFBundleVersion</key>
            <string>1</string>
            <key>LSMinimumSystemVersion</key>
            <string>14.0</string>
            <key>NSHighResolutionCapable</key>
            <true/>
            <key>KylmoraWebAppURL</key>
            <string>\(escapedURL)</string>
            <key>KylmoraWebAppID</key>
            <string>\(app.id.uuidString)</string>
            <key>KylmoraWebAppSpaceID</key>
            <string>\(spaceID)</string>
        </dict>
        </plist>
        """
    }

    private static func generateLauncherScript(app: InstalledWebApp) -> String {
        let rawURL = app.url.absoluteString
        let rawName = app.name
        let appID = app.id.uuidString
        let spaceID = app.spaceID?.uuidString ?? ""

        return """
        #!/bin/bash
        URL="\(rawURL)"
        NAME="\(rawName)"
        APP_ID="\(appID)"
        SPACE_ID="\(spaceID)"

        # URL encode URL and Name
        if command -v python3 >/dev/null 2>&1; then
            ENCODED_URL=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$URL" 2>/dev/null || echo "$URL")
            ENCODED_NAME=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$NAME" 2>/dev/null || echo "$NAME")
        else
            ENCODED_URL="$URL"
            ENCODED_NAME="$NAME"
        fi

        # 1. Open via Kylmora URL scheme
        if ! open -g "kylmora-webapp://open?url=${ENCODED_URL}&name=${ENCODED_NAME}&id=${APP_ID}&spaceID=${SPACE_ID}" 2>/dev/null; then
            # 2. Fallback to opening Kylmora directly with CLI arguments
            open -a Kylmora --args --web-app-url "$URL" --web-app-name "$NAME" --web-app-id "$APP_ID" --web-app-space "$SPACE_ID"
        fi
        """
    }

    /// Renders a macOS app icon canvas with a squircle shape, gradient backdrop,
    /// and either the source image or the first letter of the app.
    static func generateIcon(name: String, sourceImage: NSImage?) -> NSImage {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size)

        image.lockFocus()

        // 1. Draw rounded squircle
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 24, dy: 24)
        let path = NSBezierPath(roundedRect: rect, xRadius: 104, yRadius: 104)

        // Gradient background
        let gradient = NSGradient(
            starting: NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.28, alpha: 1.0),
            ending: NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.15, alpha: 1.0)
        )
        gradient?.draw(in: path, angle: -45)

        // Border stroke
        NSColor(calibratedWhite: 1.0, alpha: 0.12).setStroke()
        path.lineWidth = 4
        path.stroke()

        if let sourceImage {
            let iconRect = NSRect(x: 106, y: 106, width: 300, height: 300)
            sourceImage.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        } else {
            let initial = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
            let font = NSFont.systemFont(ofSize: 220, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white
            ]
            let attrStr = NSAttributedString(string: initial.isEmpty ? "W" : initial, attributes: attributes)
            let strSize = attrStr.size()
            let strRect = NSRect(
                x: (size.width - strSize.width) / 2,
                y: (size.height - strSize.height) / 2 - 10,
                width: strSize.width,
                height: strSize.height
            )
            attrStr.draw(in: strRect)
        }

        image.unlockFocus()
        return image
    }

    static func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
