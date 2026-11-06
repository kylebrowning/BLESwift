//
//  L2CAPChannelRemote.swift
//  BLESwiftCore
//

import Foundation

/// The backend seam for a single open L2CAP channel. It is the transport half of BLESwift's L2CAP
/// support, and the L2CAP counterpart of ``PeripheralRemote`` for GATT.
///
/// A conformer owns the byte pump completely.
/// - The conformer delivers inbound bytes on the stream that ``inbound()`` returns.
/// - ``write(_:)`` sends bytes outbound.
/// - ``close(error:)`` closes the transport.
///
/// - Important: You can call all three methods from any isolation domain. A conformer keeps its
///   mutable state in its own pump queue or thread, and never uses the owning `Central`'s
///   executor.
public protocol L2CAPChannelRemote: Sendable {

    /// The PSM that this channel was opened against.
    var psm: L2CAPPSM { get }

    /// The inbound byte stream. It yields each inbound packet that the transport reads. It
    /// finishes cleanly on a graceful close, and throws on an error or a disconnect. The stream has
    /// a single consumer: call this function once and iterate the stream that it returns.
    func inbound() -> AsyncThrowingStream<Data, Error>

    /// Sends `data` outbound. It suspends until the transport has fully written the data, and it
    /// respects the channel's back-pressure. It throws if the channel is closed or the write
    /// fails.
    func write(_ data: Data) async throws

    /// Closes the transport, finishes ``inbound()`` (with `error` if it is not `nil`), and fails
    /// each pending ``write(_:)``. It is idempotent.
    func close(error: Error?)
}
