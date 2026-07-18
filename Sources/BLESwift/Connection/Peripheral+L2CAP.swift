//
//  Peripheral+L2CAP.swift
//  BLESwift
//

import BLESwiftCore

/// L2CAP connection-oriented channels — the high-throughput byte-pipe path beyond GATT.
extension Peripheral {

    /// Opens an L2CAP channel to `psm` and returns a handle exposing it as async byte I/O.
    ///
    /// L2CAP channels are the CoreBluetooth path for high-throughput transfers (firmware
    /// images, file sync, audio) that outgrow GATT characteristics. A peripheral typically
    /// advertises the dynamic PSM to connect on via a GATT characteristic — read it, wrap it
    /// in an ``L2CAPPSM``, and pass it here.
    ///
    /// The returned ``L2CAPChannel`` exposes an inbound `AsyncThrowingStream<Data, Error>`
    /// (``L2CAPChannel/incomingData``) and an `async throws` ``L2CAPChannel/write(_:)``. The
    /// channel's lifetime is tied to this connection: if the peripheral disconnects, the
    /// channel is torn down automatically and its inbound stream finishes by throwing the
    /// disconnect error.
    ///
    /// - Parameters:
    ///   - psm: The PSM to open the channel against.
    ///   - timeout: How long to wait for the open to complete before throwing
    ///     ``BLESwiftError/timedOut``. Defaults to `nil` (wait indefinitely). Cancelling the
    ///     calling `Task` also aborts the open, leaving the connection healthy.
    /// - Returns: An open ``L2CAPChannel``.
    /// - Throws: ``BLESwiftError/notConnected`` if this peripheral is not (or no longer)
    ///   connected; ``BLESwiftError/timedOut`` on timeout;
    ///   ``BLESwiftError/operationCancelled`` if the calling `Task` is cancelled;
    ///   ``BLESwiftError/l2capOpenFailed`` if CoreBluetooth reports neither a channel nor an
    ///   error; or whatever error CoreBluetooth reports for a failed open.
    public func openL2CAPChannel(psm: L2CAPPSM, timeout: Duration? = nil) async throws -> L2CAPChannel {
        let central = try resolveCentral()
        return try await central.performOpenL2CAPChannel(peripheral: id, psm: psm, timeout: timeout)
    }
}
