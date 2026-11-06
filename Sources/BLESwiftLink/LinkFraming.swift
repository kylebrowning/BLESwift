//
//  LinkFraming.swift
//  BLESwiftLink
//

import Foundation

/// Errors from ``LinkFraming/decodeFrames(from:)`` and ``LinkFraming/encodeFrame(codec:payload:)``.
/// After either error, close the connection.
public enum LinkFramingError: Error, Equatable {
    /// The codec byte at the start of a frame did not match any ``LinkCodec`` case.
    case unknownCodec(UInt8)
    /// A payload length was larger than ``LinkFraming/maximumPayloadLength``. An inbound frame's
    /// header declared the length, or this end tried to encode an outbound payload of that length.
    /// The error carries the length as a `UInt32`, because converting a large length to `Int`
    /// traps where `Int` has 32 bits (arm64_32 on watchOS). The encoder clamps an outbound length
    /// into a `UInt32` for the same reason.
    case payloadTooLarge(UInt32)
}

/// Length-prefixed framing: `[codec: UInt8][length: UInt32 big-endian][payload]`.
public enum LinkFraming {

    /// The codec byte plus the 4-byte length.
    public static let headerLength = 5

    /// The largest payload that the decoder accepts. A larger payload is a protocol error.
    ///
    /// The limit is one mebibyte. No valid frame is near this size. The largest frame in this
    /// protocol is an L2CAP chunk, and both ends cap it at 64 KiB. Every GATT value,
    /// advertisement, and fixture database on the wire is smaller than that chunk. The limit
    /// protects against a hostile stream and leaves room for encoding overhead.
    ///
    /// **The limit also bounds the memory that a peer can make a reader use.** The reader buffers
    /// a frame until the frame is complete, so one half-delivered frame costs up to this much
    /// memory. The provider keeps one such buffer for each connection that has not yet completed
    /// the handshake. Its ceiling before the handshake is this limit multiplied by
    /// `ProviderConfiguration.maximumPendingConnections`. The default is 64, so the ceiling is
    /// 64 MiB. This ceiling is in addition to the 1 MiB of *decoded* messages that each entry can
    /// queue behind its hello (`PendingConnections.maximumQueuedBytes`).
    public static let maximumPayloadLength = 1024 * 1024

    /// Builds one frame.
    ///
    /// - Throws: ``LinkFramingError/payloadTooLarge(_:)`` if the payload is larger than
    ///   ``maximumPayloadLength``. The peer would close the stream as corrupt on such a frame.
    ///   The check also stops `UInt32(payload.count)` from trapping on a payload over 4 GiB.
    public static func encodeFrame(codec: LinkCodec, payload: Data) throws -> Data {
        guard payload.count <= maximumPayloadLength else {
            throw LinkFramingError.payloadTooLarge(UInt32(clamping: payload.count))
        }
        var frame = Data(capacity: headerLength + payload.count)
        frame.append(codec.rawValue)
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    /// Removes every complete frame at the start of `buffer` and returns the frames. A partial
    /// frame at the end stays in `buffer` for the next call.
    ///
    /// The function compacts the buffer once at the end, not once for each frame. A removal for
    /// each frame would make a full read quadratic in the number of frames, and one 64 KiB read can
    /// hold thousands of small frames.
    public static func decodeFrames(from buffer: inout Data) throws -> [(codec: LinkCodec, payload: Data)] {
        var frames: [(codec: LinkCodec, payload: Data)] = []
        var cursor = buffer.startIndex
        while buffer.endIndex - cursor >= headerLength {
            let start = cursor
            let codecByte = buffer[start]
            guard let codec = LinkCodec(rawValue: codecByte) else { throw LinkFramingError.unknownCodec(codecByte) }
            let lengthBytes = buffer[start + 1 ..< start + 5]
            // Compare the length as a `UInt32`. `Int(_:)` traps on a length above `Int.max`, which
            // is any length from 2 GiB up where `Int` has 32 bits (watchOS).
            // A corrupt or hostile stream can declare such a length.
            let declared = lengthBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard declared <= UInt32(maximumPayloadLength) else {
                throw LinkFramingError.payloadTooLarge(declared)
            }
            let length = Int(declared)
            guard buffer.endIndex - start >= headerLength + length else { break }
            let payload = Data(buffer[start + headerLength ..< start + headerLength + length])
            frames.append((codec, payload))
            cursor = start + headerLength + length
        }
        // A throw above leaves `buffer` unchanged. The tests read the bytes back to prove that the
        // function consumed nothing.
        if cursor > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex ..< cursor)
        }
        return frames
    }
}
