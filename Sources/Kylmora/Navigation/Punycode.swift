import Foundation

/// RFC 3492 decoding, for showing an internationalised domain as its
/// letters rather than as `xn--` and a code.
///
/// Decoding only: Kylmora never produces these, it only reads what a URL
/// already carries. Written here because Foundation exposes no public
/// decoder, and the algorithm is forty lines.
enum Punycode {
    private static let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
    private static let initialBias = 72, initialN = 128

    /// One label without its `xn--` prefix, or nil if it is not valid.
    static func decode(_ input: String) -> String? {
        var output: [Unicode.Scalar] = []
        var text = Substring(input)
        if let delimiter = text.lastIndex(of: "-") {
            for scalar in text[..<delimiter].unicodeScalars {
                guard scalar.isASCII else { return nil }
                output.append(scalar)
            }
            text = text[text.index(after: delimiter)...]
        }
        var n = initialN, bias = initialBias, i = 0
        var digits = text.unicodeScalars.makeIterator()
        while true {
            guard let first = digits.next() else { break }
            var scalar: Unicode.Scalar? = first
            let oldI = i
            var w = 1
            var k = base
            while true {
                guard let current = scalar, let digit = digitValue(current) else { return nil }
                let (product, overflow) = digit.multipliedReportingOverflow(by: w)
                guard !overflow else { return nil }
                i += product
                let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                if digit < t { break }
                let (next, overflow2) = w.multipliedReportingOverflow(by: base - t)
                guard !overflow2 else { return nil }
                w = next
                k += base
                scalar = digits.next()
            }
            bias = adapt(delta: i - oldI, numPoints: output.count + 1, firstTime: oldI == 0)
            n += i / (output.count + 1)
            i %= output.count + 1
            guard let decoded = Unicode.Scalar(UInt32(n)) else { return nil }
            output.insert(decoded, at: i)
            i += 1
        }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: output)
        return String(result)
    }

    /// A whole host: each `xn--` label decoded, the rest left alone. Nil when
    /// nothing needed decoding.
    static func decodeHost(_ host: String) -> String? {
        var changed = false
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map { label -> String in
            let text = String(label)
            guard text.lowercased().hasPrefix("xn--"), let decoded = decode(String(text.dropFirst(4))) else { return text }
            changed = true
            return decoded
        }
        return changed ? labels.joined(separator: ".") : nil
    }

    private static func digitValue(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar.value {
        case 48...57: return Int(scalar.value) - 22
        case 65...90: return Int(scalar.value) - 65
        case 97...122: return Int(scalar.value) - 97
        default: return nil
        }
    }

    private static func adapt(delta: Int, numPoints: Int, firstTime: Bool) -> Int {
        var delta = firstTime ? delta / damp : delta / 2
        delta += delta / numPoints
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + (base - tMin + 1) * delta / (delta + skew)
    }
}
