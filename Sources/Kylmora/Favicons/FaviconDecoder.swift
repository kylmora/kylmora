import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns downloaded favicon bytes into one small, known-good PNG.
///
/// Everything a favicon arrives as is hostile input from a site, so this is the
/// only place that touches it and it is deliberately narrow: a byte cap before
/// anything is parsed, a format allow-list, a pixel cap read from the file's
/// metadata *before* a single pixel is decoded, and a re-encode that drops
/// every ancillary chunk the original carried.
///
/// It uses ImageIO rather than `NSImage` for three reasons: it has no AppKit
/// dependency so decoding can happen off the main actor, it exposes the
/// individual images inside a multi-size `.ico` so the right one can be
/// chosen rather than whichever `NSImage` puts first, and it can report an
/// image's dimensions without decoding it, which is what makes the pixel cap a
/// real defence rather than a check that runs after the damage.
enum FaviconDecoder {
    /// Two device pixels per point at the sidebar's 16-point icon slot.
    static let outputPixelSize = 32

    /// A favicon larger than this is either a mistake or a decompression bomb.
    /// Nothing legitimate needs more, since the result is drawn at 16 points.
    static let maximumSourcePixelSize = 1024

    /// Enough for a generous multi-size `.ico`; small enough that a site cannot
    /// spend our memory. Enforced before the bytes reach a parser.
    static let maximumByteCount = 256 * 1024

    enum Failure: Error, Equatable {
        case tooLarge
        case unsupportedFormat
        case noUsableImage
        case couldNotEncode
    }

    /// Raster formats only.
    ///
    /// SVG is excluded on purpose even though `NSImage` will in fact decode it
    /// (verified: it produces an `_NSSVGImageRep`). An SVG is an XML document
    /// with its own reference and styling model, so accepting one would mean
    /// handing an untrusted, unbounded document to a parser in the browser's
    /// own process for the sake of a 16-point picture. ImageIO refuses SVG,
    /// which makes the narrow path also the default one.
    static let supportedTypes: Set<String> = [
        UTType.png.identifier,
        UTType.jpeg.identifier,
        UTType.gif.identifier,
        UTType.ico.identifier,
        UTType.bmp.identifier,
        UTType.tiff.identifier,
        UTType.webP.identifier
    ]

    /// Validates, picks the best image inside the file, and re-encodes it as a
    /// PNG of at most `outputPixelSize` on its longest side.
    ///
    /// The result is the only form the rest of the subsystem ever handles: it
    /// is what goes in the memory cache, what is written to disk, and what
    /// crosses back to the main actor. `Data` is `Sendable`; `NSImage` and
    /// `CGImage` are not, which is also why the boundary is drawn here.
    static func normalize(_ data: Data) throws -> Data {
        guard data.count <= maximumByteCount else { throw Failure.tooLarge }
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              supportedTypes.contains(type) else {
            throw Failure.unsupportedFormat
        }

        guard let index = bestImageIndex(in: source) else { throw Failure.noUsableImage }

        // `ThumbnailMaxPixelSize` is a ceiling, not a target, so a 16-pixel
        // icon stays 16 pixels rather than being blown up into a blurry 32.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: outputPixelSize,
            kCGImageSourceShouldCache: false
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw Failure.noUsableImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw Failure.couldNotEncode
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.couldNotEncode }
        return output as Data
    }

    /// Which image inside the file to use.
    ///
    /// A `.ico` is a container: measured, `github.com/favicon.ico` holds 32 and
    /// 16 pixel images and `wikipedia.org/favicon.ico` holds 48, 32 and 16.
    /// Taking the first would be arbitrary and taking the largest would mean
    /// downscaling 256 pixels into 32 for no gain.
    private static func bestImageIndex(in source: CGImageSource) -> Int? {
        var best: (index: Int, side: Int)?
        for index in 0..<CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0,
                  width <= maximumSourcePixelSize, height <= maximumSourcePixelSize else {
                continue
            }
            let side = max(width, height)
            if best == nil || isBetter(side, than: best!.side) { best = (index, side) }
        }
        return best?.index
    }

    /// Closest size at or above the target wins; failing that, the largest one
    /// below it, because upscaling a small icon beats downscaling to nothing.
    static func isBetter(_ candidate: Int, than current: Int) -> Bool {
        switch (candidate >= outputPixelSize, current >= outputPixelSize) {
        case (true, true): candidate < current
        case (true, false): true
        case (false, true): false
        case (false, false): candidate > current
        }
    }
}
