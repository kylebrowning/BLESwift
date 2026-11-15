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
public protocol VirtualL2CAPAccepting: VirtualDeviceHandler {

    /// Receives the device's end of a channel that `central` opened to `psm`. The handler owns
    /// the channel from now on. If it cannot use the channel, it must close it.
    ///
    /// - Parameters:
    ///   - channel: The device's end of the new channel.
    ///   - psm: The published PSM that the central opened.
    ///   - central: The remote central that opened the channel.
    func acceptL2CAPChannel(_ channel: any L2CAPChannelRemote, psm: L2CAPPSM, from central: Subscriber) async
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
    /// - Returns: `false` if the handle is stale or `psm` is not published.
    package func unpublishL2CAP(device: UUID, generation: UInt64, psm: L2CAPPSM) -> Bool {
        guard isCurrent(device, generation: generation, operation: "unpublishL2CAP") else { return false }
        guard publishedL2CAP[device]?.remove(psm) != nil else { return false }
        if publishedL2CAP[device]?.isEmpty == true {
            publishedL2CAP.removeValue(forKey: device)
        }
        return true
    }

    /// Opens an L2CAP channel from `session` to `psm` on `device`.
    ///
    /// The radio records the channel before it gives the device's end to the handler. Thus a
    /// disconnect during the handler's call still fails the channel.
    ///
    /// - Returns: The central end of the new channel. If the session is not connected to the
    ///   device, ``peripheralDisconnectedError``. If the device did not publish `psm`, or its
    ///   handler is not ``VirtualL2CAPAccepting``, code 12.
    package func openL2CAP(session: UUID, device: UUID, psm: L2CAPPSM) async -> Result<VirtualL2CAPChannel, NSError> {
        guard isConnected(session: session, device: device), let state = devices[device] else {
            return .failure(Self.peripheralDisconnectedError)
        }
        guard publishedL2CAP[device]?.contains(psm) == true,
              let accepting = state.handler as? any VirtualL2CAPAccepting else {
            return .failure(Self.l2capNotPublishedError(psm))
        }
        let (central, host) = VirtualL2CAPChannel.pair(psm: psm)
        // Drop the records of closed channels first, so a long connection does not collect them.
        var records = (l2capChannels[device] ?? []).filter { !$0.channel.isClosed }
        records.append(ChannelRecord(session: session, channel: central))
        l2capChannels[device] = records
        await accepting.acceptL2CAPChannel(host, psm: psm, from: subscriber(session, device: device))
        return .success(central)
    }

    /// Fails the open L2CAP channels of `device` with ``peripheralDisconnectedError`` and drops
    /// their records. If `sessions` is `nil`, it fails every channel of the device. Otherwise it
    /// fails only the channels of those sessions.
    func failL2CAPChannels(device: UUID, sessions: Set<UUID>?) {
        guard let records = l2capChannels[device] else { return }
        var kept: [ChannelRecord] = []
        for record in records {
            if let sessions, !sessions.contains(record.session) {
                kept.append(record)
            } else {
                record.channel.fail(Self.peripheralDisconnectedError)
            }
        }
        l2capChannels[device] = kept.isEmpty ? nil : kept
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
    /// - Returns: `false` if `psm` is not published, or if the device is gone.
    package func unpublishL2CAP(_ psm: L2CAPPSM) async -> Bool {
        await radio?.unpublishL2CAP(device: identifier, generation: generation, psm: psm) ?? false
    }
}
