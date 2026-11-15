//
//  VirtualRadio+L2CAP.swift
//  BLESwiftVirtualRadio
//

import BLESwiftCore
import Foundation

// L2CAP channels on the virtual radio. A device publishes PSMs, and a connected central opens
// a channel to a published PSM. Each channel is a ``VirtualL2CAPChannel`` pair. The radio
// records the central end and fails it when the connection ends.

/// A ``VirtualDeviceHandler`` that accepts L2CAP channels. The radio opens a channel to a device
/// only if its handler conforms to this protocol and the device published the PSM.
///
/// Publish a PSM with ``VirtualDeviceHandle/publishL2CAPChannel(psm:)``. Then each channel that
/// a central opens to that PSM arrives in ``acceptL2CAPChannel(_:psm:from:)``:
///
/// ```swift
/// actor EchoHandler: VirtualL2CAPAccepting {
///     func acceptL2CAPChannel(_ channel: any L2CAPChannelRemote, psm: L2CAPPSM, from central: Subscriber) async {
///         Task {
///             for try await chunk in channel.inbound() {
///                 try await channel.write(chunk)
///             }
///         }
///     }
///     // The GATT requirements of `VirtualDeviceHandler` go here.
/// }
///
/// let handle = await radio.register(VirtualDevice(descriptor: descriptor, handler: EchoHandler()))
/// let psm = try await handle.publishL2CAPChannel()
/// ```
public protocol VirtualL2CAPAccepting: VirtualDeviceHandler {

    /// Receives the device's end of a channel that `central` opened to `psm`. The handler owns
    /// the channel from now on. If it cannot use the channel, it must close it. Return promptly,
    /// and read the channel from a task.
    ///
    /// - Parameters:
    ///   - channel: The device's end of the new channel.
    ///   - psm: The published PSM that the central opened.
    ///   - central: The remote central that opened the channel.
    func acceptL2CAPChannel(_ channel: any L2CAPChannelRemote, psm: L2CAPPSM, from central: Subscriber) async
}

/// What an unpublish on the radio did.
package enum L2CAPUnpublishOutcome: Sendable, Equatable {
    /// The radio removed the PSM.
    case unpublished
    /// The device did not publish the PSM.
    case notPublished
    /// The device is gone, or the handle belongs to an earlier registration.
    case removed
}

extension VirtualRadio {

    /// The first PSM that the radio gives out. It is the start of the LE dynamic PSM range.
    static let firstDynamicPSM: UInt16 = 0x0080

    /// The last PSM that the radio gives out.
    static let lastDynamicPSM: UInt16 = 0x00FF

    /// The error for an L2CAP open to a PSM that the device did not publish, or to a device that
    /// accepts no channels. It is also the error for an unpublish of a PSM that is not published
    /// (code 12).
    package static func l2capNotPublishedError(_ psm: L2CAPPSM) -> NSError {
        NSError(
            domain: "BLESwiftProvider",
            code: 12,
            userInfo: [NSLocalizedDescriptionKey: "No L2CAP channel is published on PSM \(psm.rawValue)"]
        )
    }

    /// The error for a publish that cannot get its PSM (code 13).
    package static func l2capPSMUnavailableError(_ description: String) -> NSError {
        NSError(
            domain: "BLESwiftProvider",
            code: 13,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    /// Publishes an L2CAP PSM for `device`.
    ///
    /// - Parameters:
    ///   - device: The identifier of the device.
    ///   - generation: The generation of the caller's handle.
    ///   - psm: The PSM to publish. If it is `nil`, the radio gives the lowest free PSM in
    ///     `0x0080...0x00FF` for this device.
    /// - Returns: The published PSM. For a stale handle or an unknown device, the error of a
    ///   removed hosted device (code 5). If no PSM is free, or `psm` is already published, code
    ///   13.
    package func publishL2CAP(device: UUID, generation: UInt64, psm: L2CAPPSM?) -> Result<L2CAPPSM, NSError> {
        guard isCurrent(device, generation: generation, operation: "publishL2CAP") else {
            return .failure(VirtualPeripheralManagerBackend.removedError)
        }
        let published = publishedL2CAP[device] ?? []
        let chosen: L2CAPPSM
        if let psm {
            guard !published.contains(psm) else {
                return .failure(Self.l2capPSMUnavailableError("PSM already published"))
            }
            chosen = psm
        } else {
            guard let free = (Self.firstDynamicPSM...Self.lastDynamicPSM).first(where: { !published.contains(L2CAPPSM($0)) }) else {
                return .failure(Self.l2capPSMUnavailableError("No free L2CAP PSM"))
            }
            chosen = L2CAPPSM(free)
        }
        publishedL2CAP[device, default: []].insert(chosen)
        return .success(chosen)
    }

    /// Unpublishes `psm` for `device`. Channels that are already open stay open, as in
    /// CoreBluetooth.
    ///
    /// - Returns: ``L2CAPUnpublishOutcome/removed`` for a stale handle or an unknown device,
    ///   ``L2CAPUnpublishOutcome/notPublished`` if the device did not publish `psm`, and
    ///   ``L2CAPUnpublishOutcome/unpublished`` otherwise.
    package func unpublishL2CAP(device: UUID, generation: UInt64, psm: L2CAPPSM) -> L2CAPUnpublishOutcome {
        guard isCurrent(device, generation: generation, operation: "unpublishL2CAP") else { return .removed }
        guard publishedL2CAP[device]?.remove(psm) != nil else { return .notPublished }
        if publishedL2CAP[device]?.isEmpty == true {
            publishedL2CAP.removeValue(forKey: device)
        }
        return .unpublished
    }

    /// Opens an L2CAP channel from `session` to `psm` on `device`.
    ///
    /// The radio records the channel before it gives the device's end to the handler. Thus a
    /// disconnect during the handler's call still fails the channel. When the pair closes, its
    /// close handler drops the record.
    ///
    /// - Returns: The central end of the new channel. If the session is not connected to the
    ///   device, ``peripheralDisconnectedError``. If the device did not publish `psm`, or its
    ///   handler is not ``VirtualL2CAPAccepting``, code 12.
    package func openL2CAP(session: UUID, device: UUID, psm: L2CAPPSM) async -> Result<VirtualL2CAPChannel, NSError> {
        guard isConnected(session: session, to: device), let state = devices[device] else {
            return .failure(Self.peripheralDisconnectedError)
        }
        guard publishedL2CAP[device]?.contains(psm) == true,
              let accepting = state.handler as? any VirtualL2CAPAccepting else {
            return .failure(Self.l2capNotPublishedError(psm))
        }
        let (central, host) = VirtualL2CAPChannel.pair(psm: psm)
        l2capChannels[device, default: []].append(ChannelRecord(session: session, channel: central))
        let identity = ObjectIdentifier(central)
        // The pair closes on any thread, outside this actor, so the handler hops in with a task.
        // The radio has no queue of its own to hop onto. The handler holds the radio weakly and
        // holds no end of the pair, because the pair's shared state holds the handler.
        central.onPairClosed { [weak self] in
            guard let self else { return }
            Task { await self.dropL2CAPRecord(device: device, channel: identity) }
        }
        await accepting.acceptL2CAPChannel(host, psm: psm, from: subscriber(session, device: device))
        return .success(central)
    }

    /// Drops the record of the channel whose central end is `channel`, after its pair closed.
    /// It does nothing if a teardown already dropped the record.
    func dropL2CAPRecord(device: UUID, channel: ObjectIdentifier) {
        guard var records = l2capChannels[device] else { return }
        records.removeAll { ObjectIdentifier($0.channel) == channel }
        l2capChannels[device] = records.isEmpty ? nil : records
    }

    /// Fails the open L2CAP channels of `device` with ``peripheralDisconnectedError`` and drops
    /// their records. If `sessions` is `nil`, it fails every channel of the device. Otherwise it
    /// fails only the channels of those sessions.
    func failL2CAPChannels(device: UUID, sessions: Set<UUID>?) {
        guard let records = l2capChannels[device] else { return }
        var kept: [ChannelRecord] = []
        var doomed: [ChannelRecord] = []
        for record in records {
            if let sessions, !sessions.contains(record.session) {
                kept.append(record)
            } else {
                doomed.append(record)
            }
        }
        l2capChannels[device] = kept.isEmpty ? nil : kept
        for record in doomed {
            record.channel.fail(Self.peripheralDisconnectedError)
        }
    }
}

extension VirtualDeviceHandle {

    /// Publishes an L2CAP PSM for this device. If `psm` is `nil`, the radio gives the lowest free
    /// PSM. See `VirtualRadio.publishL2CAP(device:generation:psm:)`.
    package func publishL2CAP(psm: L2CAPPSM?) async -> Result<L2CAPPSM, NSError> {
        guard let radio else { return .failure(VirtualPeripheralManagerBackend.removedError) }
        return await radio.publishL2CAP(device: identifier, generation: generation, psm: psm)
    }

    /// Unpublishes `psm` for this device.
    ///
    /// - Returns: What the radio did. A handle whose radio is gone gets
    ///   ``L2CAPUnpublishOutcome/removed``.
    package func unpublishL2CAP(_ psm: L2CAPPSM) async -> L2CAPUnpublishOutcome {
        await radio?.unpublishL2CAP(device: identifier, generation: generation, psm: psm) ?? .removed
    }

    /// Publishes an L2CAP channel for this device, so a connected central can open it. Each
    /// channel that a central opens reaches the device's handler, if the handler conforms to
    /// ``VirtualL2CAPAccepting``. The radio has no link encryption, so a channel needs none.
    ///
    /// - Parameter psm: The PSM to publish. If it is `nil`, the radio gives the lowest free PSM
    ///   from `0x0080`. The default is `nil`.
    /// - Returns: The published PSM.
    /// - Throws: An `NSError` in the `BLESwiftProvider` domain. Code 5 if the device is removed
    ///   or registered again. Code 13 if no PSM is free or `psm` is already published.
    public func publishL2CAPChannel(psm: L2CAPPSM? = nil) async throws -> L2CAPPSM {
        try await publishL2CAP(psm: psm).get()
    }

    /// Removes the L2CAP channel that this device published on `psm`. Channels that are already
    /// open stay open, as in CoreBluetooth.
    ///
    /// - Parameter psm: The PSM to unpublish.
    /// - Throws: An `NSError` in the `BLESwiftProvider` domain. Code 12 if the device did not
    ///   publish `psm`. Code 5 if the device is removed or registered again.
    public func unpublishL2CAPChannel(_ psm: L2CAPPSM) async throws {
        switch await unpublishL2CAP(psm) {
        case .unpublished:
            return
        case .notPublished:
            throw VirtualRadio.l2capNotPublishedError(psm)
        case .removed:
            throw VirtualPeripheralManagerBackend.removedError
        }
    }
}
