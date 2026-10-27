//
//  VirtualRadio+Faults.swift
//  BLESwiftVirtualRadio
//

import BLESwiftCore
import Foundation

// Fault injection: the failures a real peripheral produces and a handler cannot — a refused
// link, a dropped one, and an ATT answer for a handle the radio would otherwise serve. All
// of it is armed through the device's handle, lives in the radio's `DeviceState`, and goes
// with the registration.

extension VirtualDeviceHandle {

    /// Fails connection attempts to this device with `error`.
    ///
    /// `times: nil` fails every attempt until ``clearConnectionFailures()``; otherwise the
    /// next `times` attempts fail and the one after succeeds (precondition: `times > 0`).
    /// Calling again replaces the previous setting, count and all. The error reaches the
    /// `Central` unchanged, so pass the `NSError` CoreBluetooth would — a `"CBErrorDomain"`
    /// code such as `peerRemovedPairingInformation` — and the code under test sees exactly
    /// what it would see on hardware.
    ///
    /// A failed attempt never reaches the device's handler: a peripheral that refuses the
    /// link never learns who asked.
    ///
    /// **Attempts are counted per device, across every central on the radio**, not per
    /// central: with two backends connecting to the same device, whichever connects first
    /// uses up the count, and the other succeeds. ``disconnect(_:error:)`` below is the one
    /// that targets individual centrals.
    ///
    /// - Parameters:
    ///   - error: The error each failed attempt is reported with.
    ///   - times: How many attempts to fail, or `nil` for every attempt. Defaults to `1`.
    public func failConnections(with error: NSError, times: Int? = 1) async {
        if let times {
            precondition(times > 0, "failConnections(with:times:) needs times > 0 or nil; got \(times)")
        }
        await radio?.failConnections(with: error, times: times, device: identifier, generation: generation)
    }

    /// Stops failing connection attempts to this device, whatever ``failConnections(with:times:)``
    /// armed. A no-op when nothing is armed.
    public func clearConnectionFailures() async {
        await radio?.clearConnectionFailures(device: identifier, generation: generation)
    }

    /// Drops the connection of `centrals` — every connected central when `nil` — as a
    /// peripheral-initiated disconnect or link loss.
    ///
    /// Each affected `Central` sees `didDisconnect` carrying `error`, its subscriptions on
    /// this device are dropped and reported to the handler as unsubscribes, and the remote is
    /// left `.disconnected` and free to reconnect: the same cleanup a device removal runs,
    /// minus the removal. A central named here that is not connected is left alone.
    ///
    /// The radio drops the connection first and delivers `didDisconnect` only once the
    /// handler has been told about every dropped subscription. While a handler is slow to
    /// return from those unsubscribes, the central has no connection on the radio but has not
    /// heard so yet: a read or write it sends in that window fails with
    /// `ATTError.invalidHandle`, and a `setNotifyValue(true)` answers not-notifying. A
    /// `cancelPeripheralConnection` in that window removes nothing, so a `Central.disconnect()`
    /// still returns normally, but the `.disconnected` connection event it produces carries
    /// the forced error (code 7 by default) instead of `nil`; a connect in it fails with
    /// ``VirtualCentralBackend/connectWhileDisconnectingError`` (code 11). A handler that
    /// returns promptly leaves no such window.
    ///
    /// A subscribe whose own handler report is still in flight when the drop lands can be
    /// overtaken by the drop's unsubscribe report: the radio records the subscription before
    /// awaiting `subscriptionChanged(isSubscribed: true)`, and the unsubscribe is reported
    /// concurrently, so a handler that awaits inside that report may finish the unsubscribe
    /// before the subscribe. The shipped handlers do not await inside it, so they never see
    /// the two out of order.
    ///
    /// - Parameters:
    ///   - centrals: The centrals to disconnect, as the handler sees them; `nil` for all.
    ///   - error: The error the disconnect is reported with. Defaults to
    ///     ``VirtualRadio/peripheralDisconnectedError``, CoreBluetooth's
    ///     `CBError.peripheralDisconnected`.
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

    /// Fails `operations` on `characteristic` with `error`, as the peripheral's ATT answer;
    /// `nil` clears them.
    ///
    /// The injected answer takes priority over everything the radio would otherwise do for a
    /// valid handle — the permission check, a static value, the handler — so a read of a
    /// static-value characteristic fails under it too. Operations not named are left as they
    /// were, so a second call can add or clear one without disturbing the rest. A
    /// `.withoutResponse` write is never affected: it has no ATT response to carry an error.
    ///
    /// Faults are keyed by characteristic identifier, not by the database entry, so they
    /// survive ``setServices(_:)``: a characteristic removed and added back keeps its fault.
    /// One goes away only with `nil` here, or with the registration.
    ///
    /// A `.subscribe` fault armed while a central is subscribed refuses its disable too, and
    /// a refused disable changes nothing: the subscription, and the subscriber the handler
    /// was given, stand until the central disconnects.
    ///
    /// On iOS, CoreBluetooth answers `.insufficientEncryption` and
    /// `.insufficientAuthentication` by starting pairing and retrying the request, so an app
    /// sees either error only once pairing has failed. The radio answers with it on the first
    /// attempt — there is no pairing to attempt — so a test asserting on one of these is
    /// testing the pairing-failed path.
    ///
    /// - Parameters:
    ///   - error: The error to answer with, or `nil` to serve `operations` normally again.
    ///   - characteristic: The characteristic to answer for.
    ///   - operations: Which operations the answer applies to. Defaults to
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

    /// CoreBluetooth's `CBError.peripheralDisconnected`: domain `"CBErrorDomain"`, code 7 —
    /// what a link that dropped from the peripheral's side is reported with on hardware, and
    /// the default ``VirtualDeviceHandle/disconnect(_:error:)`` reports.
    ///
    /// Built by hand rather than from `CBError`, so a disconnect injected on a platform
    /// without CoreBluetooth carries the same domain and code as one on a platform with it.
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
        // Checked here as well as at the handle: ``connect(session:device:sink:)`` counts down
        // from this value and disarms at exactly 1, so the invariant lives with the code that
        // depends on it.
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

    /// Drops `device`'s connection to each session in `centrals` — every connected session
    /// when `nil` — reporting `error`. See ``VirtualDeviceHandle/disconnect(_:error:)``.
    ///
    /// ``remove(device:generation:)``'s per-session path, minus the removal: the connection
    /// and its sink go, the subscriptions are dropped, and the central hears `didDisconnect`
    /// on its own sink — the backend settles the remote to `.disconnected` on the way past.
    /// Every table is settled before the first `await`, as there and in ``detach(session:)``,
    /// so a handler that calls back into the radio cannot observe a half-dropped connection.
    ///
    /// **The `didDisconnect`s go out last, after every unsubscribe has been reported** — the
    /// order a cancel has, where the backend sends its `didDisconnect` only once
    /// ``disconnect(session:device:)`` has returned. The actor is reentrant across the
    /// `reportUnsubscribed` awaits, so a `didDisconnect` sent from inside the loop let a
    /// `Central` with a reconnect policy and a surviving notification stream reconnect and
    /// re-subscribe while the handler was still being told about the old subscription: the
    /// handler finished the unsubscribe *after* the re-subscribe, and a hosted
    /// `PeripheralHost` took a live subscriber for one that had left. A removal and a
    /// re-registration keep the same order, through ``VirtualRadio/report(_:)``.
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
        // `state.handler` and each subscriber were taken before the first `await`: a removal
        // or re-registration landing between the reports must not redirect the rest to a
        // handler that never saw these subscribers.
        for entry in dropped {
            await reportUnsubscribed(entry.characteristics, handler: state.handler, central: entry.central)
        }
        for sink in sinks {
            sink(.didDisconnect(identifier, error: error))
        }
    }

    /// Sets or clears the injected ATT answer for `operations` on `characteristic`. See
    /// ``VirtualDeviceHandle/setATTError(_:for:operations:)``.
    ///
    /// Only the named slots change; an entry left with nothing in it is removed, so a device
    /// with every fault cleared holds no fault state at all.
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
