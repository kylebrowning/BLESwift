//
//  L2CAPChannel.swift
//  BLESwift
//

import BLESwiftCore
import Foundation

/// A `Sendable` handle to an open L2CAP channel.
/// ``Peripheral/openL2CAPChannel(psm:timeout:)`` returns it. The channel is a bidirectional
/// byte pipe for transfers that are too large for GATT.
///
/// - ``incomingData`` is a **single-consumer** `AsyncThrowingStream<Data, Error>`. It
///   finishes with an error if the channel closes on an error or the peripheral disconnects.
///   It finishes cleanly if the peer ends the stream.
/// - ``write(_:)`` suspends until all the bytes are written.
/// - ``close()`` closes the channel. A disconnect or a stopped `Central` also closes each
///   open channel.
public struct L2CAPChannel: Sendable {

    /// The PSM of this channel.
    public let psm: L2CAPPSM

    /// The peripheral this channel belongs to.
    public let peripheral: PeripheralIdentifier

    /// The backing transport: a CoreBluetooth stream pump, or an in-memory fake in tests.
    private let remote: any L2CAPChannelRemote

    /// The token that registers this channel in the owning session. ``close()`` uses it to
    /// deregister the channel.
    private let token: UUID

    /// A weak handle to the owning ``Central``, so ``close()`` can deregister this channel
    /// without keeping the actor alive.
    private let centralBox: WeakCentralBox

    /// Creates a channel handle over `remote`, registered under `token` in `central`'s session
    /// for `peripheral`. Only `Central` creates it, after a successful open.
    init(remote: any L2CAPChannelRemote, token: UUID, peripheral: PeripheralIdentifier, central: Central) {
        self.remote = remote
        self.token = token
        self.peripheral = peripheral
        self.psm = remote.psm
        self.centralBox = WeakCentralBox(central)
    }

    /// The inbound byte stream. It yields every packet that the peripheral sends, in order. It
    /// is single-consumer.
    public var incomingData: AsyncThrowingStream<Data, Error> {
        remote.inbound()
    }

    /// Sends `data`. It suspends until all the bytes are written and respects back-pressure.
    ///
    /// - Parameter data: The bytes to send.
    /// - Throws: ``BLESwiftError/l2capChannelClosed`` if ``close()`` or a disconnect closed
    ///   the channel. It throws the underlying transport error if the write fails.
    public func write(_ data: Data) async throws {
        try await remote.write(data)
    }

    /// Closes this channel. It tears down the transport and finishes ``incomingData`` cleanly.
    ///
    /// This call is idempotent and best-effort. It never throws. A disconnect or a stopped
    /// ``Central`` closes each open channel, so call this method only to end a channel while
    /// the peripheral stays connected.
    public func close() async {
        if let central = centralBox.central {
            await central.closeL2CAPChannel(peripheral: peripheral, token: token)
        } else {
            // The owning `Central` is already gone. Tear down the transport directly.
            remote.close(error: nil)
        }
    }
}
