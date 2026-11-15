//
//  CentralSession+L2CAP.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwiftCore
import BLESwiftLink
import Dispatch
import Foundation

/// The L2CAP half of a central-role session. It pairs each `openL2CAPChannel` request with the
/// backend's completion, and gives each open channel to the session's ``L2CAPChannelRelay``.
/// The relay owns the credit, the pump, and the write chain. See ``L2CAPChannelRelay`` for the
/// flow-control rules.
extension CentralSession {

    /// The largest `l2capData` payload that either end puts on the wire. See
    /// ``L2CAPChannelRelay/maximumChunk``.
    static var maximumChunk: Int { L2CAPChannelRelay.maximumChunk }

    /// The number of client-written bytes that one channel can have unwritten before this
    /// session stops believing the client. See ``L2CAPChannelRelay/maximumOutstandingWrites``.
    static var maximumOutstandingWrites: Int { L2CAPChannelRelay.maximumOutstandingWrites }

    /// The central-role event for one relay frame on `channel`.
    static func event(for frame: L2CAPChannelRelay.Frame, channel: UInt32) -> CentralWireEvent {
        switch frame {
        case .data(let data): return .l2capData(channel: channel, data: data)
        case .credit(let bytes): return .l2capCredit(channel: channel, bytes: bytes)
        case .closed(let error): return .l2capClosed(channel: channel, error: error)
        }
    }

    // MARK: - Open

    /// Completes one `openL2CAPChannel` request. It matches the request to the client's channel id,
    /// registers the bridge, answers the client, and starts the inbound pump. Call it on
    /// ``CentralSession/queue``.
    ///
    /// `didOpenL2CAPChannel` names no open. So a FIFO for each peripheral pairs completions by
    /// arrival order. A completion for an open that was outstanding at disconnect can pair
    /// wrongly. Before the reconnect, it finds an empty FIFO and the session closes its channel.
    /// After the client opens again, it answers the new open with the old transport. The provider
    /// cannot detect this. It is a known limit of passthrough L2CAP on real hardware.
    func bridgeOpenedChannel(_ channel: (any L2CAPChannelRemote)?, error: NSError?, from peripheral: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        var queued = pendingOpens[peripheral] ?? []
        let pending = queued.isEmpty ? nil : queued.removeFirst()
        pendingOpens[peripheral] = queued

        guard let pending else {
            // Nothing asked for this channel. It is an open that this session never issued, or
            // an open whose connection the session already discarded. Close it so it does not
            // leak.
            log?("no pending L2CAP open for peripheral \(peripheral); closing the channel")
            channel?.close(error: nil)
            return
        }

        guard let channel, error == nil else {
            channel?.close(error: nil)
            send(.didOpenL2CAPChannel(
                peripheral: peripheral,
                channel: pending.channel,
                psm: pending.psm,
                error: WireError(error ?? CentralSession.l2capOpenFailed)
            ))
            return
        }

        // The channel id is the *client's* id. The session takes it unchanged from the request,
        // so two opens can name the same id. An overwrite would orphan the first bridge: every
        // close path iterates ``channels``, so nothing could reach it again. Its pump would keep
        // interleaving frames under an id that now belongs to another channel, and its
        // transport, task, and parked continuation would live for the rest of the session. The
        // session refuses the duplicate and does not touch the channel that is already open
        // under that id.
        guard channels[pending.channel] == nil else {
            log?("L2CAP channel \(pending.channel) is already open; refusing the duplicate open")
            channel.close(error: nil)
            send(.didOpenL2CAPChannel(
                peripheral: peripheral,
                channel: pending.channel,
                psm: pending.psm,
                error: WireError(CentralSession.l2capDuplicateChannel)
            ))
            return
        }
        let open = relay.insert(channel, as: pending.channel, owner: peripheral)
        send(.didOpenL2CAPChannel(
            peripheral: peripheral,
            channel: pending.channel,
            psm: channel.psm.rawValue,
            error: nil
        ))
        relay.startPump(for: pending.channel, open: open)
    }

    /// The error with which the session refuses a second open that names a channel id that is
    /// already in use.
    static var l2capDuplicateChannel: NSError {
        NSError(
            domain: "BLESwiftProvider",
            code: 10,
            userInfo: [NSLocalizedDescriptionKey: "That L2CAP channel identifier is already open"]
        )
    }

    // MARK: - Requests

    /// Writes `data` to the transport of `channel` through the relay. A frame that the relay
    /// refuses drops the link. See ``L2CAPChannelRelay/write(_:to:)``. Call it on
    /// ``CentralSession/queue``.
    func write(_ data: Data, to channel: UInt32) {
        dispatchPrecondition(condition: .onQueue(queue))
        do {
            try relay.write(data, to: channel)
        } catch {
            switch error {
            case .frameTooLarge(let channel, let bytes):
                failProtocol(ProtocolViolation.l2capFrameTooLarge(channel: channel, bytes: bytes))
            case .writeWindowExceeded(let channel):
                failProtocol(ProtocolViolation.l2capWriteWindowExceeded(channel: channel))
            }
        }
    }

    /// Grants `bytes` of credit to `channel`. See ``L2CAPChannelRelay/grantCredit(_:to:)``. Call
    /// it on ``CentralSession/queue``.
    func grantCredit(_ bytes: Int, to channel: UInt32) {
        relay.grantCredit(bytes, to: channel)
    }

    /// Closes `channel` at the client's request. See ``L2CAPChannelRelay/closeChannel(_:)``. Call
    /// it on ``CentralSession/queue``.
    func closeChannel(_ channel: UInt32) {
        relay.closeChannel(channel)
    }

    /// Closes and drops every channel that `predicate` selects, after a disconnect or at the end
    /// of the session. Call it on ``CentralSession/queue``.
    func closeChannels(matching predicate: (OpenChannel) -> Bool) {
        relay.closeChannels(matching: predicate)
    }
}
#endif
