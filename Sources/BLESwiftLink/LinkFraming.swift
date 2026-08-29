//
//  LinkFraming.swift
//  BLESwiftLink
//

import Foundation

/// Errors from ``LinkFraming/decodeFrames(from:)``. Either one means the stream is corrupt;
/// the connection must be closed.
public enum LinkFramingError: Error, Equatable {
    /// The codec byte at the front of a frame did not match any ``LinkCodec`` case.
    case unknownCodec(UInt8)
    /// The frame's declared payload length exceeded ``LinkFraming/maximumPayloadLength``.
    /// Carried as the `UInt32` read off the wire: a declared length is compared — and
    /// reported — before any conversion to `Int`, which would trap on a 32-bit `Int`
    /// platform such as watchOS's arm64_32.
    case payloadTooLarge(UInt32)
}

/// Length-prefixed framing: `[codec: UInt8][length: UInt32 big-endian][payload]`.
public enum LinkFraming {

    /// Codec byte plus 4-byte length.
    public static let headerLength = 5

    /// The largest payload accepted; anything larger is a protocol error.
    public static let maximumPayloadLength = 16 * 1024 * 1024

    /// Builds one frame.
    public static func encodeFrame(codec: LinkCodec, payload: Data) -> Data {
        var frame = Data(capacity: headerLength + payload.count)
        frame.append(codec.rawValue)
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    /// Removes and returns every complete frame at the front of `buffer`; a trailing
    /// partial frame stays in `buffer` for the next call.
    ///
    /// **One compaction, not one per frame.** The frames are read through a cursor and the
    /// bytes they consumed are dropped once, at the end. Removing each frame as it was
    /// decoded made a full read quadratic in the number of frames it carried: every removal
    /// shifts the whole remainder of the buffer down, and one 64 KiB read off a busy link can
    /// hold thousands of small frames.
    public static func decodeFrames(from buffer: inout Data) throws -> [(codec: LinkCodec, payload: Data)] {
        var frames: [(codec: LinkCodec, payload: Data)] = []
        var cursor = buffer.startIndex
        while buffer.endIndex - cursor >= headerLength {
            let start = cursor
            let codecByte = buffer[start]
            guard let codec = LinkCodec(rawValue: codecByte) else { throw LinkFramingError.unknownCodec(codecByte) }
            let lengthBytes = buffer[start + 1 ..< start + 5]
            // Compared as the `UInt32` it was read as: `Int(_:)` traps on a length above
            // `Int.max`, which on watchOS's 32-bit `Int` is any length from 2 GiB up — and a
            // corrupt or hostile stream can declare one.
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
        // A throw above leaves `buffer` untouched, which the length checks rely on: the stream
        // is corrupt and the connection is about to close, and the caller's own tests read the
        // bytes back to prove nothing was consumed.
        if cursor > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex ..< cursor)
        }
        return frames
    }
}
