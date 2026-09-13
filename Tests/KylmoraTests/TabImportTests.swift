import Foundation
import Testing
@testable import Kylmora

/// Builds test fixtures: an all-literal LZ4 block (no back-references), wrapped
/// in the mozLz4 container, so a round trip can be checked without a compressor.
private enum Fixture {
    static func lz4LiteralBlock(_ bytes: [UInt8]) -> [UInt8] {
        var block: [UInt8] = []
        let literals = bytes.count
        if literals < 15 {
            block.append(UInt8(literals << 4))
        } else {
            block.append(0xF0)
            var remaining = literals - 15
            while remaining >= 255 { block.append(255); remaining -= 255 }
            block.append(UInt8(remaining))
        }
        block.append(contentsOf: bytes)
        return block
    }

    static func mozLz4(_ data: Data) -> Data {
        wrap(lz4LiteralBlock([UInt8](data)), declaredSize: UInt32(data.count))
    }

    /// A mozLz4 container around a raw block with a chosen size header, so a
    /// header that lies about the decompressed size can be built for the
    /// hardening tests.
    static func wrap(_ block: [UInt8], declaredSize: UInt32) -> Data {
        var out = Data(MozLz4.magic)
        var size = declaredSize.littleEndian
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        out.append(contentsOf: block)
        return out
    }
}

@Suite("LZ4 and mozLz4 decoding")
struct LZ4Tests {
    @Test("An all-literal block round-trips through mozLz4")
    func literalRoundTrip() throws {
        let payload = Data("The quick brown fox jumps over the lazy dog, twice over.".utf8)
        let decoded = try MozLz4.decompress(Fixture.mozLz4(payload))
        #expect(decoded == payload)
    }

    @Test("A back-reference expands a run, overlapping copies included")
    func backReference() throws {
        // token 0x32: 3 literals, match length 2+4=6; literals "abc"; offset 3.
        let block: [UInt8] = [0x32, 0x61, 0x62, 0x63, 0x03, 0x00]
        let decoded = try LZ4.decompressBlock(block, decompressedSize: 9)
        #expect(String(decoding: decoded, as: UTF8.self) == "abcabcabc")
    }

    @Test("A long literal length spilling past 15 is read")
    func longLiterals() throws {
        let payload = Data(String(repeating: "x", count: 300).utf8)
        let decoded = try MozLz4.decompress(Fixture.mozLz4(payload))
        #expect(decoded == payload)
    }

    @Test("A file without the magic is rejected")
    func badMagic() {
        #expect(throws: MozLz4.Failure.badMagic) {
            try MozLz4.decompress(Data("not a mozLz4 file".utf8))
        }
    }

    @Test("A size header claiming gigabytes is refused, not allocated")
    func oversizedSizeHeaderIsRejected() {
        // The header claims ~4 GB from a two-byte block. Before the cap this
        // reserved gigabytes up front and took the app down; now it is refused.
        let file = Fixture.wrap([0x00, 0x00], declaredSize: .max)
        #expect(throws: MozLz4.Failure.corrupt) {
            try MozLz4.decompress(file)
        }
    }

    @Test("The size ceiling is enforced at the block decoder")
    func decoderRefusesSizeOverCeiling() {
        #expect(throws: LZ4.Failure.corrupt) {
            _ = try LZ4.decompressBlock([0x00], decompressedSize: LZ4.maxDecompressedSize + 1)
        }
    }

    @Test("A block that produces more than it declared stops instead of overrunning")
    func overproducingBlockIsRejected() {
        // 5 literals "abcde", but the header says the output is only 3 bytes.
        let block = Fixture.lz4LiteralBlock(Array("abcde".utf8))
        #expect(throws: LZ4.Failure.corrupt) {
            _ = try LZ4.decompressBlock(block, decompressedSize: 3)
        }
    }

    @Test("A back-reference pointing before the start is rejected")
    func matchOffsetPastStartIsRejected() {
        // token 0x02: no literals, match length 6; offset 3 with an empty
        // output so far, so the copy would read from before position zero.
        let block: [UInt8] = [0x02, 0x03, 0x00]
        #expect(throws: LZ4.Failure.corrupt) {
            _ = try LZ4.decompressBlock(block, decompressedSize: 6)
        }
    }

    @Test("A literal run running off the end of the input is rejected")
    func truncatedLiteralsRejected() {
        // token 0x50 promises 5 literal bytes but only 2 follow.
        let block: [UInt8] = [0x50, 0x61, 0x62]
        #expect(throws: LZ4.Failure.corrupt) {
            _ = try LZ4.decompressBlock(block, decompressedSize: 5)
        }
    }

    @Test("A truncated size header is rejected")
    func shortHeaderRejected() {
        #expect(throws: MozLz4.Failure.badMagic) {
            // Magic present but fewer than the 12 header bytes.
            try MozLz4.decompress(Data(MozLz4.magic) + Data([0x01, 0x02]))
        }
    }
}

@Suite("Importing open tabs from Firefox")
struct TabSessionImporterTests {
    private let sessionJSON = ##"""
    {"windows":[{"tabs":[
      {"index":2,"entries":[
        {"url":"https://old.example/","title":"Old"},
        {"url":"https://current.example/","title":"Current"}
      ]},
      {"entries":[{"url":"https://only.example/","title":"Only"}]},
      {"entries":[{"url":"about:blank","title":"Blank"}]}
    ]}]}
    """##

    @Test("A tab's index points at the current entry; non-web tabs are skipped")
    func parsesPlainJSON() throws {
        let tabs = try TabSessionImporter.firefoxTabs(in: Data(sessionJSON.utf8))
        #expect(tabs.map { $0.url.absoluteString } == ["https://current.example/", "https://only.example/"])
        #expect(tabs.first?.title == "Current")
    }

    @Test("The same session compressed as mozLz4 reads identically")
    func parsesCompressed() throws {
        let compressed = Fixture.mozLz4(Data(sessionJSON.utf8))
        let tabs = try TabSessionImporter.firefoxTabs(in: compressed)
        #expect(tabs.count == 2)
        #expect(tabs.last?.url.host() == "only.example")
    }

    @Test("A file that is not a session is not recognised")
    func rejectsNonSession() {
        #expect(throws: TabSessionImporter.Failure.unrecognised) {
            try TabSessionImporter.firefoxTabs(in: Data(##"{"bookmarks":[]}"##.utf8))
        }
    }
}
