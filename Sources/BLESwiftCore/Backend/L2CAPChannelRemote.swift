//
//  L2CAPChannelRemote.swift
//  BLESwiftCore
//

import Foundation

/// The backend seam for a single **open** L2CAP channel — the transport half of BLESwift's
/// L2CAP support, analogous to ``PeripheralRemote`` for GATT.
///
/// BLESwift ships two conformances: a CoreBluetooth one (`CBL2CAPChannelTransport` in the
/// `BLESwift` module, which wraps a `CBL2CAPChannel`'s Foundation `InputStream`/`OutputStream`
/// and pumps them on a dedicated queue) and an in-memory fake (`FakeL2CAPChannel` in
/// `BLESwiftTestSupport`, backed by simple queue-confined pipes — no CoreBluetooth streams).
/// Conforming your own is possible but unsupported.
///
/// A conformer owns the byte pump entirely. Inbound bytes are delivered on the stream
/// returned by ``inbound()``; ``write(_:)`` sends bytes outbound (honoring back-pressure);
/// and ``close(error:)`` tears the transport down — finishing the inbound stream (throwing
/// `error`, or cleanly when `nil`) and failing any in-flight ``write(_:)``.
///
/// - Important: All three methods are safe to call from any isolation domain — a conformer
///   confines its own mutable state to whatever dedicated queue/thread it pumps on, never
///   the owning `Central`'s executor. This is the contract that keeps stream pumping off
///   the actor.
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

    /// Tears the channel down: closes the underlying transport, finishes ``inbound()`` —
    /// throwing `error` if non-`nil`, else cleanly — and fails any pending ``write(_:)``.
    /// Idempotent; a second call is a no-op.
    func close(error: Error?)
}
