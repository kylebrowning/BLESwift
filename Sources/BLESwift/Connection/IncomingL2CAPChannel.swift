//
//  IncomingL2CAPChannel.swift
//  BLESwift
//

import BLESwiftCore
import Foundation

/// A `Sendable` handle to an L2CAP channel that a remote central opened to a PSM that this
/// peripheral published. ``PeripheralHost/incomingL2CAPChannels()`` delivers it. The channel is
/// a bidirectional byte pipe for transfers that are too large for GATT.
///
/// The host does not track the channel. The radio closes it when the central disconnects, when
/// Bluetooth turns off, or when either side calls close.
///
/// - ``incomingData`` is a **single-consumer** `AsyncThrowingStream<Data, Error>`. It finishes
///   cleanly if the central closes the channel. It throws if the channel closes on an error.
/// - ``write(_:)`` suspends until all the bytes are written.
/// - ``close()`` closes the channel.
public struct IncomingL2CAPChannel: Sendable {

    /// The published PSM that the central opened.
    public let psm: L2CAPPSM

    /// The identifier of the central that opened this channel. It is the same value as
    /// ``Subscriber/id`` for that central.
    public let central: UUID

    /// The backing transport: a CoreBluetooth stream pump, a virtual radio channel, or an
    /// in-memory fake in tests.
    private let remote: any L2CAPChannelRemote

    /// Creates a channel handle over `remote`. Only `PeripheralHost` creates it, when a central
    /// opens a channel.
    init(remote: any L2CAPChannelRemote, central: UUID) {
        self.remote = remote
        self.central = central
        self.psm = remote.psm
    }

    /// The inbound byte stream. It yields every packet that the central sends, in order. It is
    /// single-consumer.
    public var incomingData: AsyncThrowingStream<Data, Error> {
        remote.inbound()
    }

    /// Sends `data` to the central. It suspends until all the bytes are written and respects
    /// back-pressure.
    ///
    /// - Parameter data: The bytes to send.
    /// - Throws: ``BLESwiftError/l2capChannelClosed`` if the channel is closed. It throws the
    ///   underlying transport error if the write fails.
    public func write(_ data: Data) async throws {
        try await remote.write(data)
    }

    /// Closes this channel. It tears down the transport and finishes ``incomingData`` cleanly.
    /// This call is idempotent. It never throws.
    public func close() {
        remote.close(error: nil)
    }
}
