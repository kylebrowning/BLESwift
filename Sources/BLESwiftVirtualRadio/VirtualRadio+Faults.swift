//
//  VirtualRadio+Faults.swift
//  BLESwiftVirtualRadio
//

import BLESwiftCore
import Foundation

// Fault injection. This file has the failures that a real peripheral produces and a handler cannot
// produce: a refused link, a dropped link, and an ATT answer for a handle that the radio would
// otherwise serve. The code arms them through the device's handle. They live in the radio's
// `DeviceState` and go away with the registration.

extension VirtualDeviceHandle {

    /// Fails connection attempts to this device with `error`.
    ///
    /// `times: nil` fails every attempt until ``clearConnectionFailures()``. Otherwise the next
    /// `times` attempts fail and the one after succeeds. `times` must be greater than zero. A new
    /// call replaces the previous setting, including the count.
    ///
    /// The error reaches the `Central` unchanged. Pass the `NSError` that CoreBluetooth would give,
    /// such as a `"CBErrorDomain"` `peerRemovedPairingInformation`, so the code under test sees
    /// what it sees on hardware. A failed attempt never reaches the device's handler.
    ///
    /// **The radio counts attempts for each device, across every central on the radio.** It does
    /// not count for each central. If two backends connect to the same device, the first uses up
    /// the count and the other succeeds. ``disconnect(_:error:)`` targets individual centrals.
    ///
    /// - Parameters:
    ///   - error: The error that is reported for each failed attempt.
    ///   - times: How many attempts to fail, or `nil` for every attempt. The default is `1`.
    public func failConnections(with error: NSError, times: Int? = 1) async {
        if let times {
            precondition(times > 0, "failConnections(with:times:) needs times > 0 or nil; got \(times)")
        }
        await radio?.failConnections(with: error, times: times, device: identifier, generation: generation)
    }

    /// Stops the failures that ``failConnections(with:times:)`` armed. It does nothing when nothing
    /// is armed.
    public func clearConnectionFailures() async {
        await radio?.clearConnectionFailures(device: identifier, generation: generation)
    }

    /// Drops the connection of `centrals`, or of every connected central when `nil`, as a
    /// peripheral-initiated disconnect or link loss. A named central that is not connected is left
    /// alone.
    ///
    /// Each affected `Central` sees `didDisconnect` with `error`. The radio drops the central's
    /// subscriptions on this device and reports them to the handler as unsubscribes. The remote is
    /// `.disconnected` and can reconnect.
    ///
    /// - The radio delivers `didDisconnect` only after every report in flight for this device.
    ///   Until then, the central has no connection but has not heard `didDisconnect`. See
    ///   <doc:InProcessMocking#Forced-disconnects>.
    /// - If you call this method from inside a subscription report, it returns before the radio
    ///   delivers the reports. See <doc:InProcessMocking#Report-order-and-reentrancy>.
    ///
    /// - Parameters:
    ///   - centrals: The centrals to disconnect, as the handler sees them. `nil` means all.
    ///   - error: The error that the disconnect is reported with. The default is
    ///     ``VirtualRadio/peripheralDisconnectedError``, the `CBError.peripheralDisconnected` of
    ///     CoreBluetooth.
    public func disconnect(
        _ centrals: [Subscriber]? = nil,
        error: NSError = VirtualRadio.peripheralDisconnectedError
    ) async {
        await radio?.disconnect(
            centrals: centrals.map { $0.map(\.id) },
            error: error,
            device: identifier,
            generation: generation
        )
    }

    /// Fails `operations` on `characteristic` with `error`, as the peripheral's ATT answer. `nil`
    /// clears them.
    ///
    /// - The injected answer has priority over the permission check, a static value, and the
    ///   handler.
    /// - Operations that the call does not name stay as they were.
    /// - A `.withoutResponse` write is never affected, because it has no ATT response.
    /// - The fault survives ``setServices(_:)``, because the radio keys faults by characteristic
    ///   identifier. It goes away only with `nil` here, or with the registration.
    /// - A `.subscribe` fault also refuses the disable of an existing subscription. The
    ///   subscription stands until the central disconnects.
    /// - The radio answers `.insufficientEncryption` and `.insufficientAuthentication` on the first
    ///   attempt. On iOS, CoreBluetooth pairs and retries first. A test that asserts one of them
    ///   tests the pairing-failed path.
    ///
    /// - Parameters:
    ///   - error: The error to answer with, or `nil` to serve `operations` normally again.
    ///   - characteristic: The characteristic to answer for.
    ///   - operations: Which operations the answer applies to. The default is
    ///     ``VirtualGATTOperations/all``.
    public func setATTError(
        _ error: ATTError?,
        for characteristic: CharacteristicIdentifier,
        operations: VirtualGATTOperations = .all
    ) async {
        await radio?.setATTError(error, for: characteristic, operations: operations, device: identifier, generation: generation)
    }
}

extension VirtualRadio {

    /// The `CBError.peripheralDisconnected` of CoreBluetooth: domain `"CBErrorDomain"`, code 7. On
    /// hardware, it is the error for a link that the peripheral dropped. It is the default error of
    /// ``VirtualDeviceHandle/disconnect(_:error:)``.
    ///
    /// The code builds it by hand and not from `CBError`, so it is the same on a platform without
    /// CoreBluetooth.
    public static var peripheralDisconnectedError: NSError {
        NSError(
            domain: "CBErrorDomain",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "The specified device has disconnected from us."]
        )
    }

    /// Arms a connection failure on a registered device. See
    /// ``VirtualDeviceHandle/failConnections(with:times:)``.
    func failConnections(with error: NSError, times: Int?, device: UUID, generation: UInt64) {
        // Checked here and at the handle. ``connect(session:device:sink:)`` counts down from this
        // value and disarms at exactly 1, so the invariant stays with the code that depends on it.
        precondition(times.map { $0 > 0 } ?? true, "failConnections needs times > 0 or nil; got \(times.map(String.init) ?? "nil")")
        guard isCurrent(device, generation: generation, operation: "failConnections") else { return }
        devices[device]?.connectionFailure = (error, times)
    }

    /// Disarms a device's connection failure. See
    /// ``VirtualDeviceHandle/clearConnectionFailures()``.
    func clearConnectionFailures(device: UUID, generation: UInt64) {
        guard isCurrent(device, generation: generation, operation: "clearConnectionFailures") else { return }
        devices[device]?.connectionFailure = nil
    }

    /// Drops `device`'s connection to each session in `centrals`, or to every connected session
    /// when `nil`. See ``VirtualDeviceHandle/disconnect(_:error:)``.
    ///
    /// The code settles every table before the first `await`, as ``remove(device:generation:)`` and
    /// ``detach(session:)`` do. A handler that calls back into the radio then never sees a
    /// half-dropped connection.
    ///
    /// The `didDisconnect` events go out last, as a step on the device's report chain behind the
    /// unsubscribes. The actor is reentrant across the unsubscribe awaits. An earlier
    /// `didDisconnect` lets a reconnecting `Central` subscribe before the handler hears the old
    /// unsubscribe. With nothing in flight, the events go out in this turn. See
    /// ``deliverDisconnects(_:device:after:_:)`` and ``isReporting``.
    func disconnect(centrals: [UUID]?, error: NSError, device: UUID, generation: UInt64) async {
        guard isCurrent(device, generation: generation, operation: "disconnect") else { return }
        guard let state = devices[device] else { return }
        let identifier = PeripheralIdentifier(uuid: device, name: state.descriptor.name)
        let targets = centrals ?? Array(sessions.keys)
        var dropped: [(central: Subscriber, characteristics: [CharacteristicIdentifier])] = []
        var sinks: [@Sendable (CentralEvent) -> Void] = []
        for sessionID in targets {
            guard let session = sessions[sessionID], session.connections.contains(device) else { continue }
            sessions[sessionID]?.connections.remove(device)
            sessions[sessionID]?.peripheralSinks.removeValue(forKey: device)
            dropped.append((subscriber(sessionID, device: device), dropSubscriptions(session: sessionID, device: device)))
            sinks.append(session.centralSink)
        }
        // Take `state.handler` and each subscriber before enqueuing anything. A removal or a
        // re-registration can land between the reports and must not redirect the rest to a handler
        // that never saw these subscribers.
        var tail: Task<Void, Never>?
        for entry in dropped {
            tail = reportUnsubscribed(entry.characteristics, on: device, handler: state.handler, central: entry.central) ?? tail
        }
        tail = deliverDisconnects(sinks, device: device, after: tail) {
            .didDisconnect(identifier, error: error)
        }
        await settle(tail)
    }

    /// Sets or clears the injected ATT answer for `operations` on `characteristic`. See
    /// ``VirtualDeviceHandle/setATTError(_:for:operations:)``.
    ///
    /// Only the named slots change. The code removes an empty entry, so a device with every fault
    /// cleared holds no fault state.
    func setATTError(
        _ error: ATTError?,
        for characteristic: CharacteristicIdentifier,
        operations: VirtualGATTOperations,
        device: UUID,
        generation: UInt64
    ) {
        guard isCurrent(device, generation: generation, operation: "setATTError") else { return }
        var injected = devices[device]?.attErrors[characteristic] ?? InjectedATTErrors()
        if operations.contains(.read) { injected.read = error }
        if operations.contains(.write) { injected.write = error }
        if operations.contains(.subscribe) { injected.subscribe = error }
        devices[device]?.attErrors[characteristic] = injected.isEmpty ? nil : injected
    }
}
