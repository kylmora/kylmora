import AppKit

/// The handful of colours a site's icon is actually made of.
///
/// Used to ring a pinned tile in the site's own brand rather than in a single
/// accent, which is what makes a strip of shortcuts readable at a glance: you
/// recognise Slack's four colours before you have read anything.
///
/// The extraction is deliberately crude. A tile ring is 2 points wide and the
/// source is a 16-point favicon, so a perceptual clustering algorithm would be
/// a great deal of work to produce a result nobody could tell apart from this.
enum BrandPalette {
    /// Ignore near-white, near-black and near-grey pixels: almost every icon
    /// has a background, and a ring made of it is a ring made of nothing.
    static func isChromatic(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        // Saturation alone rules out white and grey; a brightness floor rules
        // out black. There is deliberately no brightness ceiling -- pure red
        // and yellow are at the top of it, and excluding them threw away the
        // brand colours of half the sites this exists for.
        return rgb.saturationComponent > 0.25 && rgb.brightnessComponent > 0.2
    }

    /// Colours found in the image, most common first, with near-duplicates
    /// merged so a four-colour logo does not return four shades of one of them.
    static func colors(in image: NSImage, limit: Int = 4) -> [NSColor] {
        guard let bitmap = bitmap(from: image) else { return [] }

        var buckets: [Int: (color: NSColor, count: Int)] = [:]
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let pixel = bitmap.colorAt(x: x, y: y),
                      let rgb = pixel.usingColorSpace(.sRGB),
                      rgb.alphaComponent > 0.5,
                      isChromatic(rgb) else { continue }

                // Hue buckets rather than RGB ones: two shades of the same
                // brand colour should count as that colour, not as two.
                //
                // Rounded, not truncated, so the buckets are centred on their
                // hues instead of starting at them. Red sits at hue 0, where
                // truncating splits it in two — 0.998 and 0.004 are the same
                // red to the eye but fall either side of the wrap, and a
                // red logo comes back as two colours instead of one.
                let bucket = Int((rgb.hueComponent * 12).rounded()) % 12
                if let existing = buckets[bucket] {
                    buckets[bucket] = (existing.color, existing.count + 1)
                } else {
                    buckets[bucket] = (rgb, 1)
                }
            }
        }

        return buckets.values
            .sorted { $0.count > $1.count }
            .prefix(limit)
            .map(\.color)
    }

    /// What the ring is drawn with: at least two stops, and a closed loop so a
    /// conic sweep does not show a seam where it wraps.
    ///
    /// A monochrome icon yields no chromatic colours at all, and gets a neutral
    /// ring rather than an invented one.
    static func ringColors(for image: NSImage?) -> [NSColor] {
        let found = image.map { colors(in: $0) } ?? []
        guard let first = found.first else {
            return [
                NSColor.tertiaryLabelColor, NSColor.quaternaryLabelColor,
                NSColor.tertiaryLabelColor
            ]
        }
        let stops = found.count == 1 ? [first, first.blended(withFraction: 0.4, of: .white) ?? first]
            : found
        return stops + [first]
    }

    private static func bitmap(from image: NSImage) -> NSBitmapImageRep? {
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            return rep
        }
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }
}
