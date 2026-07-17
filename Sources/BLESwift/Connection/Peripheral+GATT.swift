//
//  Peripheral+GATT.swift
//  BLESwift
//

import BLESwiftCore
import Foundation

/// GATT operations — read, write, RSSI, and service-change notifications — all routed
/// through the owning ``Central`` actor.
///
/// Every method here lazily discovers the service/characteristic it needs first (cache
/// short-circuited by the CoreBluetooth shim's own `isDiscovered(_:)` — BLESwift keeps no
/// separate discovery cache; see `Central.ensureDiscovered(_:on:identifier:)`), and
/// `serviceChanges()` provides a multicast stream for observing service invalidation.
extension Peripheral {

    /// Reads `characteristic`'s current value and decodes it as `Value`.
    ///
    /// Concurrent operations on the *same* characteristic are serialized in the order
    /// they're called (a per-characteristic FIFO — different characteristics interleave
    /// freely). The owning service and characteristic are discovered first if needed.
    ///
    /// - Parameters:
    ///   - characteristic: The characteristic to read from.
    ///   - timeout: How long to wait before giving up with ``BLESwiftError/timedOut``. `nil`
    ///     (the default) waits indefinitely.
    /// - Returns: The characteristic's value, decoded as `Value`.
    /// - Throws: ``BLESwiftError/notConnected`` if this peripheral is no longer connected;
    ///   ``BLESwiftError/readConflictsWithNotification`` if `characteristic` currently has
    ///   notifications enabled (CoreBluetooth can't disambiguate a read completion from a
    ///   notification on the same characteristic, so BLESwift throws instead of allowing
    ///   the conflict); ``BLESwiftError/missingService(_:)``/``BLESwiftError/missingCharacteristic(_:)``
    ///   if discovery fails; ``BLESwiftError/timedOut`` on timeout; whatever `Value`'s
    ///   `Receivable` decoding throws; or whatever error CoreBluetooth reports for the read.
    public func read<Value: Receivable>(from characteristic: CharacteristicIdentifier, timeout: Duration? = nil) async throws -> Value {
        let central = try resolveCentral()
        let data = try await central.performRead(peripheral: id, characteristic: characteristic, timeout: timeout)
        return try Value(bluetoothData: data)
    }

    /// Writes `value` to `characteristic`.
    ///
    /// Concurrent operations on the *same* characteristic are serialized in the order
    /// they're called (see ``read(from:timeout:)``). The owning service and characteristic
    /// are discovered first if needed.
    ///
    /// For `type: .withoutResponse`, this awaits CoreBluetooth's write-without-response
    /// back-pressure signal (`canSendWriteWithoutResponse`) before writing, if it currently
    /// reports `false` — otherwise CoreBluetooth may silently drop the payload.
    /// CoreBluetooth delivers no completion callback for a `.withoutResponse` write, so
    /// this returns as soon as the write call itself is made.
    ///
    /// - Parameters:
    ///   - value: The value to write.
    ///   - characteristic: The characteristic to write to.
    ///   - type: Whether to wait for CoreBluetooth's write confirmation. Defaults to
    ///     `.withResponse`.
    ///   - timeout: How long to wait before giving up with ``BLESwiftError/timedOut``. `nil`
    ///     (the default) waits indefinitely.
    /// - Throws: ``BLESwiftError/notConnected`` if this peripheral is no longer connected;
    ///   ``BLESwiftError/missingService(_:)``/``BLESwiftError/missingCharacteristic(_:)`` if
    ///   discovery fails; ``BLESwiftError/timedOut`` on timeout; whatever `value`'s
    ///   `Transmittable` encoding throws; or whatever error CoreBluetooth reports for the
    ///   write.
    public func write<Value: Transmittable>(
        _ value: Value,
        to characteristic: CharacteristicIdentifier,
        type: WriteType = .withResponse,
        timeout: Duration? = nil
    ) async throws {
        let central = try resolveCentral()
        let data = try value.toBluetoothData()
        try await central.performWrite(peripheral: id, characteristic: characteristic, data: data, type: type, timeout: timeout)
    }

    /// Reads the peripheral's current RSSI (signal strength), in dBm.
    ///
    /// RSSI has no owning characteristic, so concurrent `readRSSI()` calls are serialized
    /// against each other independently of any characteristic's FIFO.
    ///
    /// - Parameter timeout: How long to wait before giving up with ``BLESwiftError/timedOut``.
    ///   `nil` (the default) waits indefinitely.
    /// - Returns: The current RSSI, in dBm.
    /// - Throws: ``BLESwiftError/notConnected`` if this peripheral is no longer connected;
    ///   ``BLESwiftError/timedOut`` on timeout; or whatever error CoreBluetooth reports for the
    ///   RSSI read.
    public func readRSSI(timeout: Duration? = nil) async throws -> Int {
        let central = try resolveCentral()
        return try await central.performReadRSSI(peripheral: id, timeout: timeout)
    }

    /// This peripheral's maximum payload length in bytes for a single write of `type`.
    ///
    /// Unlike every other method here, this never throws: it's a best-effort sizing hint,
    /// not an operation with a meaningful failure mode. Returns a documented default
    /// (the classic BLE ATT_MTU-3 default of 20 bytes) if this peripheral is no longer
    /// connected, rather than failing.
    ///
    /// - Parameter type: Which write type to report the maximum payload length for.
    /// - Returns: The maximum payload length, in bytes.
    public func maximumWriteValueLength(for type: WriteType) async -> Int {
        guard let central = centralBox.central else {
            return Central.defaultMaximumWriteValueLength
        }
        return await central.maximumWriteValueLength(peripheral: id, for: type)
    }

    /// Returns a multicast stream of every `didModifyServices` invalidation — the set of
    /// services CoreBluetooth just removed (or replaced) on THIS peripheral. Another
    /// peripheral's invalidations never appear here, even while both are connected through
    /// the same `Central`.
    ///
    /// CoreBluetooth itself prunes invalidated services from its own service graph as part
    /// of reporting this event, which the CoreBluetooth shim's `isDiscovered(_:)` reflects
    /// automatically — BLESwift keeps no separate discovery cache to invalidate. A subsequent
    /// `read`/`write`/etc. against an invalidated service therefore re-discovers it lazily,
    /// exactly as if it had never been discovered.
    ///
    /// No replay: a late subscriber only sees invalidations that happen after it starts
    /// consuming. Not actor-isolated to fetch (unlike ``Central/connectionEvents()``): the
    /// underlying registry is itself `Sendable` and independently thread-safe, so this
    /// can hand back a stream synchronously even if the owning ``Central`` has already been
    /// deallocated (in which case the returned stream finishes immediately, with nothing to
    /// subscribe to). The stream survives this peripheral disconnecting and reconnecting —
    /// it is keyed by identifier, not by any particular connection attempt.
    public func serviceChanges() -> AsyncStream<[ServiceIdentifier]> {
        guard let central = centralBox.central else {
            return AsyncStream { continuation in continuation.finish() }
        }
        return central.serviceChangesRegistry.broadcaster(for: id).stream()
    }
}
