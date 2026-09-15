import AppKit
import Foundation
import WebKit

/// The scope of a webpage screenshot capture.
public enum ScreenshotScope: String, Sendable, CaseIterable {
    /// Captures the visible area (viewport) of the web page.
    case visible
    /// Captures the entire scrollable height and width of the web page.
    case fullPage
}

/// The destination for a captured screenshot.
public enum ScreenshotDestination: Sendable {
    /// Saves the screenshot as a PNG file to the Downloads folder (or custom directory).
    case saveToDownloads(customDirectory: URL? = nil)
    /// Copies the screenshot as an image and PNG data to the system clipboard.
    case copyToClipboard
}

/// Coordinates capturing, rendering, saving, and copying screenshots of web pages.
@MainActor
public enum ScreenshotService {
    /// JavaScript snippet to calculate the complete scrollable dimensions of the page.
    private static let pageDimensionScript = """
    (function() {
        var b = document.body;
        var d = document.documentElement;
        var w = Math.max(
            b ? b.scrollWidth : 0,
            b ? b.offsetWidth : 0,
            d ? d.clientWidth : 0,
            d ? d.scrollWidth : 0,
            d ? d.offsetWidth : 0
        );
        var h = Math.max(
            b ? b.scrollHeight : 0,
            b ? b.offsetHeight : 0,
            d ? d.clientHeight : 0,
            d ? d.scrollHeight : 0,
            d ? d.offsetHeight : 0
        );
        return { width: w, height: h };
    })()
    """

    /// Maximum height for full-page screenshots to prevent memory exhaustion on infinite-scroll pages.
    public static let maxFullPageHeight: Double = 24000.0

    /// Captures a screenshot of the specified `WKWebView`.
    ///
    /// - Parameters:
    ///   - webView: The web view to capture.
    ///   - scope: Whether to capture visible viewport or full scrollable page.
    /// - Returns: Rendered `NSImage`.
    public static func capture(webView: WKWebView, scope: ScreenshotScope) async throws -> NSImage {
        switch scope {
        case .visible:
            return try await webView.takeSnapshot(configuration: nil)

        case .fullPage:
            var fullWidth = Double(webView.bounds.width)
            var fullHeight = Double(webView.bounds.height)

            if let result = try? await webView.evaluateJavaScript(pageDimensionScript) as? [String: Any] {
                if let w = (result["width"] as? NSNumber)?.doubleValue, w > 0 {
                    fullWidth = max(fullWidth, w)
                }
                if let h = (result["height"] as? NSNumber)?.doubleValue, h > 0 {
                    fullHeight = max(fullHeight, h)
                }
            }

            let boundedHeight = min(fullHeight, maxFullPageHeight)
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: fullWidth, height: boundedHeight)
            return try await webView.takeSnapshot(configuration: config)
        }
    }

    /// Converts an `NSImage` to PNG `Data`.
    public static func pngData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Copies an `NSImage` to `NSPasteboard.general`.
    public static func copyImageToClipboard(image: NSImage) {
        let pboard = NSPasteboard.general
        pboard.clearContents()
        pboard.writeObjects([image])
        if let png = pngData(from: image) {
            pboard.setData(png, forType: .png)
        }
    }

    /// Saves an `NSImage` to disk in the user's Downloads directory (or specified directory).
    ///
    /// - Parameters:
    ///   - image: The captured image.
    ///   - tabTitle: Page title used to name the file.
    ///   - url: URL used as fallback name.
    ///   - customDirectory: Optional directory override.
    /// - Returns: URL of the written file.
    public static func saveImageToDownloads(
        image: NSImage,
        tabTitle: String?,
        url: URL?,
        customDirectory: URL? = nil
    ) throws -> URL {
        let dir = customDirectory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        let initialFilename = generateFilename(title: tabTitle ?? url?.host() ?? "Page")
        var targetURL = dir.appendingPathComponent(initialFilename)

        if FileManager.default.fileExists(atPath: targetURL.path) {
            let baseName = (initialFilename as NSString).deletingPathExtension
            let ext = (initialFilename as NSString).pathExtension
            var counter = 1
            repeat {
                let candidate = "\(baseName) (\(counter)).\(ext)"
                targetURL = dir.appendingPathComponent(candidate)
                counter += 1
            } while FileManager.default.fileExists(atPath: targetURL.path)
        }

        guard let data = pngData(from: image) else {
            throw NSError(domain: "Kylmora.Screenshot", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to convert screenshot to PNG format."
            ])
        }

        try data.write(to: targetURL, options: .atomic)
        return targetURL
    }

    /// Formats a clean, readable filename for screenshots.
    public static func generateFilename(title: String?, timestamp: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let dateStr = formatter.string(from: timestamp)

        let sanitized = sanitizeFilename(title ?? "")
        if sanitized.isEmpty {
            return "Screenshot \(dateStr).png"
        } else {
            let truncated = String(sanitized.prefix(50))
            return "\(truncated) - Screenshot \(dateStr).png"
        }
    }

    /// Sanitizes arbitrary page titles into filesystem-safe filename components.
    public static func sanitizeFilename(_ string: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|#%&{}[]$!'@+`=")
        let cleaned = string.components(separatedBy: invalidCharacters).joined(separator: " ")
        let collapsed = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Displays a momentary visual shutter flash over the web view.
    public static func flashFeedback(in view: NSView) {
        let overlay = NSView(frame: view.bounds)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.45).cgColor
        overlay.autoresizingMask = [.width, .height]
        view.addSubview(overlay)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            overlay.animator().alphaValue = 0
        }, completionHandler: {
            overlay.removeFromSuperview()
        })
    }

    /// Plays a subtle shutter sound feedback.
    public static func playShutterSound() {
        if let sound = NSSound(named: NSSound.Name("Tink")) {
            sound.play()
        }
    }
}
