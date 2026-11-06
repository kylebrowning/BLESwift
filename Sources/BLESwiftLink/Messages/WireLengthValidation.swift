//
//  WireLengthValidation.swift
//  BLESwiftLink
//

import Foundation

/// The rule at the wire boundary for a payload length that a peer reports.
///
/// A negotiated maximum is arithmetic, not only data, because callers divide by it. The maximum is
/// `CBPeripheral.maximumWriteValueLength(for:)` on the central side and
/// `CBCentral.maximumUpdateValueLength` on the host side.
///
/// `Peripheral.writeChunked(_:for:)` slices its payload into chunks of that size. Two bad values
/// cause a failure:
///
/// - If a peer reports `0`, the loop never ends.
/// - If a peer reports a negative length, the stride precondition fails and the process stops.
///
/// CoreBluetooth cannot produce either value. The code rejects both at the boundary as a
/// protocol violation.
///
/// The code clamps the upper end and does not reject it. A length larger than any ATT payload
/// is nonsense, but a caller can survive it: the result is one oversized chunk, and the peer
/// answers it with an error. Without clamping, a provider whose stack reports an implausible
/// maximum would be unreachable.
public enum WireLengthValidation {

    /// The largest payload length that a peer can report. The code clamps a larger length to this
    /// value.
    ///
    /// The value is 65535. An ATT MTU is in a 16-bit field, so no real stack negotiates a larger
    /// value.
    public static let maximumLength = 65535

    /// Returns `length` clamped to ``maximumLength``, after it checks that the length is usable.
    ///
    /// - Parameter length: The maximum payload length, as it arrived on the wire.
    /// - Returns: `length`, or ``maximumLength`` if `length` is larger.
    /// - Throws: ``WireDecodingError/invalidMaximumLength(_:)`` if `length` is zero or
    ///   negative.
    public static func validated(_ length: Int) throws -> Int {
        guard length > 0 else { throw WireDecodingError.invalidMaximumLength(length) }
        return min(length, maximumLength)
    }

    /// The largest attribute offset that a peer can report. The code clamps a larger offset to
    /// this value.
    ///
    /// The value is 65535. An ATT attribute value is at most that long, so no real stack reports
    /// a larger offset into one.
    public static let maximumOffset = 65535

    /// Returns `offset` clamped to ``maximumOffset``, after it checks that the offset is usable.
    ///
    /// A handler slices its value at the offset, for example `value[offset...]`. A negative offset
    /// traps the process that took the request. CoreBluetooth cannot produce one, so the code
    /// refuses it at the boundary. The code clamps the upper end for the reason that the type's
    /// overview gives.
    ///
    /// - Parameter offset: The attribute offset, as it arrived on the wire.
    /// - Returns: `offset`, or ``maximumOffset`` if `offset` is larger.
    /// - Throws: ``WireDecodingError/invalidOffset(_:)`` if `offset` is negative.
    public static func validatedOffset(_ offset: Int) throws -> Int {
        guard offset >= 0 else { throw WireDecodingError.invalidOffset(offset) }
        return min(offset, maximumOffset)
    }
}
