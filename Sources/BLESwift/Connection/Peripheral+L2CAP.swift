//
//  Peripheral+L2CAP.swift
//  BLESwift
//

import BLESwiftCore

/// L2CAP connection-oriented channels. This is the high-throughput byte-pipe path beyond GATT.
extension Peripheral {

    /// Opens an L2CAP channel to `psm` and returns a handle for async byte I/O. If the
    /// peripheral disconnects, the channel closes and its inbound stream throws the disconnect
    /// error.
    ///
    /// - Parameters:
    ///   - psm: The PSM of the channel.
    ///   - timeout: How long to wait before the method throws ``BLESwiftError/timedOut``. The
    ///     default `nil` waits without a limit. If you cancel the calling `Task`, the open
    ///     stops and the connection stays up.
    /// - Returns: An open ``L2CAPChannel``.
    /// - Throws: One of these errors:
    ///   - ``BLESwiftError/notConnected``.
    ///   - ``BLESwiftError/timedOut``.
    ///   - ``BLESwiftError/operationCancelled``.
    ///   - ``BLESwiftError/l2capOpenFailed``.
    ///   - The error that CoreBluetooth reports for a failed open.
    public func openL2CAPChannel(psm: L2CAPPSM, timeout: Duration? = nil) async throws -> L2CAPChannel {
        let central = try resolveCentral()
        return try await central.performOpenL2CAPChannel(peripheral: id, psm: psm, timeout: timeout)
    }
}
