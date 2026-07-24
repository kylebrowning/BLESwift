//
//  Peripheral+L2CAP.swift
//  BLESwift
//

import BLESwiftCore

/// L2CAP connection-oriented channels — the high-throughput byte-pipe path beyond GATT.
extension Peripheral {

    /// Opens an L2CAP channel to `psm` and returns a handle exposing it as async byte I/O.
    /// The channel's lifetime is tied to this connection: if the peripheral disconnects,
    /// the channel is torn down automatically and its inbound stream throws the disconnect
    /// error.
    ///
    /// - Parameters:
    ///   - psm: The PSM to open the channel against.
    ///   - timeout: How long to wait before throwing ``BLESwiftError/timedOut``. Defaults
    ///     to `nil` (wait indefinitely). Cancelling the calling `Task` aborts the open,
    ///     leaving the connection healthy.
    /// - Returns: An open ``L2CAPChannel``.
    /// - Throws: ``BLESwiftError/notConnected``, ``BLESwiftError/timedOut``,
    ///   ``BLESwiftError/operationCancelled``, ``BLESwiftError/l2capOpenFailed``, or
    ///   whatever error CoreBluetooth reports for a failed open.
    public func openL2CAPChannel(psm: L2CAPPSM, timeout: Duration? = nil) async throws -> L2CAPChannel {
        let central = try resolveCentral()
        return try await central.performOpenL2CAPChannel(peripheral: id, psm: psm, timeout: timeout)
    }
}
