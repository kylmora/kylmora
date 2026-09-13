import Foundation

/// Decodes a raw LZ4 block -- the compression inside Firefox's session files.
///
/// LZ4 is a byte stream of sequences: a token, some literal bytes copied out
/// verbatim, then a back-reference (offset + length) copied from what has
/// already been produced. Lengths of 15 in the token spill into extra 0xFF
/// bytes. The final sequence is literals with no back-reference. This is the
/// "safe" decoder: it copies the match a byte at a time, so overlapping copies
/// (how LZ4 encodes runs) are correct, and it never reads past its input.
enum LZ4 {
    enum Failure: Error, Equatable { case corrupt }

    /// The most a block is allowed to expand to. `decompressedSize` is read
    /// straight from the file, so a corrupt or hostile one can claim up to 4 GB
    /// and make the reserve below try to allocate it before a single byte is
    /// decoded. A Firefox `sessionstore` is a few megabytes; anything claiming
    /// hundreds is not one. The cap bounds both the up-front reserve and the
    /// running output, so neither a bad size field nor a block that keeps
    /// producing bytes can exhaust memory.
    static let maxDecompressedSize = 256 * 1024 * 1024

    static func decompressBlock(_ input: [UInt8], decompressedSize: Int) throws -> [UInt8] {
        guard decompressedSize >= 0, decompressedSize <= maxDecompressedSize else {
            throw Failure.corrupt
        }
        var out = [UInt8]()
        out.reserveCapacity(decompressedSize)
        var ip = 0
        let end = input.count

        func extendedLength(_ start: Int) throws -> Int {
            var length = start
            guard start == 15 else { return length }
            while true {
                guard ip < end else { throw Failure.corrupt }
                let byte = Int(input[ip]); ip += 1
                length += byte
                if byte != 0xFF { return length }
            }
        }

        while ip < end {
            let token = Int(input[ip]); ip += 1

            let literalLength = try extendedLength(token >> 4)
            guard ip + literalLength <= end else { throw Failure.corrupt }
            // A block must never produce more than it declared: the guard caps
            // running output at the (already capped) size, so an amplifying
            // block cannot outgrow the buffer reserved for it.
            guard out.count + literalLength <= decompressedSize else { throw Failure.corrupt }
            out.append(contentsOf: input[ip..<ip + literalLength])
            ip += literalLength

            // The last sequence is literals only; the input ends right here.
            if ip >= end { break }

            guard ip + 2 <= end else { throw Failure.corrupt }
            let offset = Int(input[ip]) | (Int(input[ip + 1]) << 8)
            ip += 2
            guard offset > 0, offset <= out.count else { throw Failure.corrupt }

            let matchLength = try extendedLength(token & 0xF) + 4
            guard out.count + matchLength <= decompressedSize else { throw Failure.corrupt }
            var source = out.count - offset
            for _ in 0..<matchLength {
                out.append(out[source])
                source += 1
            }
        }
        guard out.count == decompressedSize else { throw Failure.corrupt }
        return out
    }
}

/// Unwraps Mozilla's `mozLz4` container, which is what Firefox stores its
/// `sessionstore` JSON in: an 8-byte magic, a little-endian `UInt32` of the
/// decompressed size, then a raw LZ4 block.
enum MozLz4 {
    enum Failure: Error, Equatable { case badMagic, corrupt }

    /// "mozLz40\0".
    static let magic: [UInt8] = [0x6D, 0x6F, 0x7A, 0x4C, 0x7A, 0x34, 0x30, 0x00]

    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, Array(bytes.prefix(8)) == magic else { throw Failure.badMagic }
        let size = Int(UInt32(bytes[8]) | (UInt32(bytes[9]) << 8) | (UInt32(bytes[10]) << 16) | (UInt32(bytes[11]) << 24))
        do {
            return Data(try LZ4.decompressBlock(Array(bytes[12...]), decompressedSize: size))
        } catch {
            throw Failure.corrupt
        }
    }
}
