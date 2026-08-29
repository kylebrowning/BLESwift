//
//  WireLengthValidation.swift
//  BLESwiftLink
//

import Foundation

/// The wire boundary's rule for a payload length a peer reports.
///
/// A negotiated maximum — `CBPeripheral.maximumWriteValueLength(for:)` on the central side,
/// `CBCentral.maximumUpdateValueLength` on the host side — is arithmetic, not merely data:
/// callers divide by it. `Peripheral.writeChunked(_:for:)` slices its payload into chunks of
/// that size, so a peer that reports `0` spins that loop forever, and one that reports a
/// negative length trips the stride precondition and takes the process down. Neither is a
/// value CoreBluetooth can produce, so both are treated the way every other unrepresentable
/// field is: rejected at the boundary as a protocol violation.
///
/// The upper end is clamped rather than rejected. A length larger than an ATT payload could
/// ever be is nonsense too, but it is nonsense a caller survives — one oversized chunk that
/// the peer answers with an error — and clamping keeps a provider whose stack reports an
/// implausible maximum usable instead of unreachable.
public enum WireLengthValidation {

    /// The largest payload length a peer may report, past which lengths are clamped.
    ///
    /// 65535: an ATT MTU is carried in a 16-bit field, so no real stack negotiates more.
    public static let maximumLength = 65535

    /// Returns `length` clamped to ``maximumLength`` once it is known to be usable.
    ///
    /// - Parameter length: The maximum payload length, as it arrived on the wire.
    /// - Returns: `length`, or ``maximumLength`` if it exceeds it.
    /// - Throws: ``WireDecodingError/invalidMaximumLength(_:)`` if `length` is zero or
    ///   negative.
    public static func validated(_ length: Int) throws -> Int {
        guard length > 0 else { throw WireDecodingError.invalidMaximumLength(length) }
        return min(length, maximumLength)
    }
}
