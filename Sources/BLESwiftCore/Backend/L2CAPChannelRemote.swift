//
//  L2CAPChannelRemote.swift
//  BLESwiftCore
//

import Foundation

/// The backend seam for a single open L2CAP channel — the transport half of BLESwift's
/// L2CAP support, analogous to ``PeripheralRemote`` for GATT.
///
/// A conformer owns the byte pump entirely. Inbound bytes are delivered on the stream
/// returned by ``inbound()``; ``write(_:)`` sends bytes outbound; ``close(error:)`` tears
/// the transport down.
///
/// - Important: All three methods are safe to call from any isolation domain — a conformer
///   confines its own mutable state to its own pump queue/thread, never the owning
///   `Central`'s executor.
public protocol L2CAPChannelRemote: Sendable {

    /// The PSM this channel was opened against.
    var psm: L2CAPPSM { get }

    /// The inbound byte stream. Every inbound packet the transport reads is `yield`ed here;
    /// the stream finishes — throwing on error/disconnect, or cleanly on a graceful close —
    /// when the channel ends. Single-consumer: call once and iterate the returned stream.
    func inbound() -> AsyncThrowingStream<Data, Error>

    /// Sends `data` outbound, suspending until it has been fully written (honoring the
    /// channel's back-pressure). Throws if the channel is already closed or the write fails.
    func write(_ data: Data) async throws

    /// Tears the channel down: closes the transport, finishes ``inbound()`` (throwing
    /// `error` if non-`nil`), and fails any pending ``write(_:)``. Idempotent.
    func close(error: Error?)
}
