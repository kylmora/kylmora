import Foundation

/// The wire format a native messaging host speaks.
///
/// Chrome defined it and every host built since follows it: each message is a
/// 32-bit unsigned length in the machine's byte order, then that many bytes of
/// UTF-8 JSON. Native byte order means little-endian on every Mac Kylmora
/// runs on, and hosts compiled for the Mac assume exactly that, so the length
/// is written little-endian rather than in network order.
///
/// Nothing here interprets the JSON. A host's reply is handed to the engine as
/// it arrived, so a message this side cannot parse is the host's problem to
/// answer for, not ours to guess at.
enum NativeMessagingFraming {
    /// The largest single message either side may send.
    ///
    /// Chrome caps a host's reply at 64 MB and the browser's request at 4 GB.
    /// One cap for both directions is simpler to explain and the difference
    /// never matters: a request that large is a bug, and refusing it here
    /// beats letting a host allocate it.
    static let maximumMessageBytes = 64 * 1024 * 1024

    enum Failure: Error, Equatable {
        /// The frame on the wire claims a length past what we will carry.
        case messageTooLarge(Int)
        /// A message that `JSONSerialization` will not write.
        case notSerializable
    }

    /// The four length bytes followed by the payload.
    static func frame(_ payload: Data) throws -> Data {
        guard payload.count <= maximumMessageBytes else {
            throw Failure.messageTooLarge(payload.count)
        }
        var length = UInt32(payload.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        return frame
    }

    /// Reassembles whole messages out of however the pipe hands them over.
    ///
    /// A pipe read returns whatever bytes have arrived: half a length prefix,
    /// three messages at once, a message split down the middle. The reader
    /// keeps the remainder and hands back only messages that are complete.
    struct Reader {
        private var buffer = Data()
        private let limit: Int

        init(limit: Int = NativeMessagingFraming.maximumMessageBytes) {
            self.limit = limit
        }

        /// What is held back waiting for the rest of its message.
        var pendingByteCount: Int { buffer.count }

        /// Appends what the pipe gave us and returns every message now whole.
        ///
        /// Throws once a frame announces more than the limit; the caller kills
        /// the connection, because a length that large means the stream is no
        /// longer aligned and nothing after it can be trusted.
        mutating func append(_ data: Data) throws -> [Data] {
            buffer.append(data)
            var messages: [Data] = []
            while buffer.count >= 4 {
                let length = buffer.withUnsafeBytes { raw -> Int in
                    var value: UInt32 = 0
                    withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: UnsafeRawBufferPointer(rebasing: raw[0..<4])) }
                    return Int(UInt32(littleEndian: value))
                }
                guard length <= limit else {
                    buffer.removeAll(keepingCapacity: false)
                    throw Failure.messageTooLarge(length)
                }
                guard buffer.count >= 4 + length else { break }
                messages.append(buffer.subdata(in: 4..<(4 + length)))
                buffer.removeSubrange(0..<(4 + length))
            }
            return messages
        }
    }

    /// JSON bytes for a message the engine handed us.
    ///
    /// Chrome's API takes any JSON value, including a bare string or number,
    /// so fragments are allowed. Sorted keys make a host's log readable and
    /// two identical messages identical on the wire.
    static func data(from message: Any?) throws -> Data {
        let value = message ?? NSNull()
        guard JSONSerialization.isValidJSONObject(value) || isFragment(value) else {
            throw Failure.notSerializable
        }
        do {
            return try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        } catch {
            throw Failure.notSerializable
        }
    }

    /// The message a host sent, as the engine wants it.
    static func message(from data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private static func isFragment(_ value: Any) -> Bool {
        value is String || value is NSNumber || value is NSNull
    }
}
