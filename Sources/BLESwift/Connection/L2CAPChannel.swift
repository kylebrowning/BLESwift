//
//  L2CAPChannel.swift
//  BLESwift
//

import BLESwiftCore
import Foundation

/// A `Sendable` handle to an open L2CAP channel, returned by
/// ``Peripheral/openL2CAPChannel(psm:timeout:)``.
///
/// An L2CAP connection-oriented channel is a bidirectional byte pipe — the high-throughput
/// path CoreBluetooth exposes for transfers that outgrow GATT (firmware images, file sync,
/// streaming). BLESwift surfaces it as async byte I/O:
///
/// - ``incomingData`` is an `AsyncThrowingStream<Data, Error>` of inbound packets. Iterate
///   it to receive. It finishes by **throwing** when the channel closes on error or the
///   peripheral disconnects (with the disconnect error), or cleanly when the peer ends the
///   stream. **Single-consumer** — iterate the one stream; don't read ``incomingData`` from
///   multiple tasks.
/// - ``write(_:)`` sends bytes outbound, suspending until they are fully written (it honors
///   the channel's back-pressure rather than dropping data).
/// - ``close()`` tears the channel down explicitly. A disconnect (or `Central` being
///   stopped) also tears every open channel down automatically, finishing ``incomingData``
///   with the disconnect error.
///
/// ```swift
/// let channel = try await peripheral.openL2CAPChannel(psm: psm)
///
/// // Receive.
/// Task {
///     do {
///         for try await packet in channel.incomingData {
///             handle(packet)
///         }
///     } catch {
///         // Channel closed / peripheral disconnected.
///     }
/// }
///
/// // Send.
/// try await channel.write(payload)
///
/// // Done.
/// await channel.close()
/// ```
public struct L2CAPChannel: Sendable {

    /// The PSM this channel was opened against.
    public let psm: L2CAPPSM

    /// The peripheral this channel belongs to.
    public let peripheral: PeripheralIdentifier

    /// The backing transport — a CoreBluetooth stream pump in production, an in-memory fake
    /// in tests. `Sendable`, and owns its own off-actor pump.
    private let remote: any L2CAPChannelRemote

    /// This channel's registration token in the owning session, used to deregister it on
    /// ``close()``.
    private let token: UUID

    /// A weak handle to the owning ``Central`` — so ``close()`` can deregister this channel
    /// without keeping the actor alive (see ``WeakCentralBox``).
    private let centralBox: WeakCentralBox

    /// Creates a channel handle over `remote`, registered under `token` in `central`'s
    /// session for `peripheral`. Created only by `Central` on a successful open.
    init(remote: any L2CAPChannelRemote, token: UUID, peripheral: PeripheralIdentifier, central: Central) {
        self.remote = remote
        self.token = token
        self.peripheral = peripheral
        self.psm = remote.psm
        self.centralBox = WeakCentralBox(central)
    }

    /// The inbound byte stream: every packet the peripheral sends, in order.
    ///
    /// Finishes by **throwing** when the channel closes on error or the peripheral
    /// disconnects (with the disconnect error), or cleanly when the peer ends the stream.
    /// Single-consumer — iterate the one returned stream.
    public var incomingData: AsyncThrowingStream<Data, Error> {
        remote.inbound()
    }

    /// Sends `data` outbound, suspending until it has been fully written.
    ///
    /// Honors the channel's back-pressure: rather than dropping bytes the peer can't yet
    /// accept, this waits until they have all been handed to the transport.
    ///
    /// - Parameter data: The bytes to send.
    /// - Throws: ``BLESwiftError/l2capChannelClosed`` if the channel has been closed (by
    ///   ``close()`` or a disconnect), or the underlying transport error if the write fails.
    public func write(_ data: Data) async throws {
        try await remote.write(data)
    }

    /// Closes this channel: tears down the transport and finishes ``incomingData`` cleanly.
    ///
    /// Idempotent, and best-effort — never throws. A disconnect (or ``Central`` being
    /// stopped) closes every open channel automatically, so calling this is only necessary
    /// to end a channel while the peripheral stays connected.
    public func close() async {
        if let central = centralBox.central {
            await central.closeL2CAPChannel(peripheral: peripheral, token: token)
        } else {
            // The owning `Central` is already gone; just tear the transport down directly.
            remote.close(error: nil)
        }
    }
}
