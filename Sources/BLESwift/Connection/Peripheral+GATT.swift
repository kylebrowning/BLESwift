//
//  Peripheral+GATT.swift
//  BLESwift
//

import BLESwiftCore
import Foundation

/// GATT operations — read, write, RSSI, and service-change notifications — all routed
/// through the owning ``Central`` actor. Every method lazily discovers the
/// service/characteristic it needs first.
extension Peripheral {

    /// Reads `characteristic`'s current value and decodes it as `Value`. Concurrent
    /// operations on the *same* characteristic are serialized in call order (a
    /// per-characteristic FIFO); different characteristics interleave freely.
    ///
    /// - Parameters:
    ///   - characteristic: The characteristic to read from.
    ///   - timeout: How long to wait before giving up with ``BLESwiftError/timedOut``. `nil`
    ///     (the default) waits indefinitely.
    /// - Returns: The characteristic's value, decoded as `Value`.
    /// - Throws: ``BLESwiftError/notConnected``;
    ///   ``BLESwiftError/readConflictsWithNotification`` if `characteristic` currently has
    ///   notifications enabled (CoreBluetooth can't disambiguate a read completion from a
    ///   notification on the same characteristic);
    ///   ``BLESwiftError/missingService(_:)``/``BLESwiftError/missingCharacteristic(_:)``;
    ///   ``BLESwiftError/timedOut``; whatever `Value`'s `Receivable` decoding throws; or
    ///   whatever error CoreBluetooth reports.
    public func read<Value: Receivable>(from characteristic: CharacteristicIdentifier, timeout: Duration? = nil) async throws -> Value {
        let central = try resolveCentral()
        let data = try await central.performRead(peripheral: id, characteristic: characteristic, timeout: timeout)
        return try Value(bluetoothData: data)
    }

    /// Writes `value` to `characteristic`. Serialized like ``read(from:timeout:)``. For
    /// `type: .withoutResponse`, awaits CoreBluetooth's back-pressure signal
    /// (`canSendWriteWithoutResponse`) first if it currently reports `false` — otherwise
    /// CoreBluetooth may silently drop the payload; this write type has no completion
    /// callback, so the call returns as soon as it is made.
    ///
    /// - Parameters:
    ///   - value: The value to write.
    ///   - characteristic: The characteristic to write to.
    ///   - type: Whether to wait for CoreBluetooth's write confirmation. Defaults to
    ///     `.withResponse`.
    ///   - timeout: How long to wait before giving up with ``BLESwiftError/timedOut``. `nil`
    ///     (the default) waits indefinitely.
    /// - Throws: ``BLESwiftError/notConnected``;
    ///   ``BLESwiftError/missingService(_:)``/``BLESwiftError/missingCharacteristic(_:)``;
    ///   ``BLESwiftError/timedOut``; whatever `value`'s `Transmittable` encoding throws; or
    ///   whatever error CoreBluetooth reports.
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

    /// The set of operations `characteristic` advertises support for — whether it's
    /// readable, writable, notifiable, and so on.
    ///
    /// - Parameter characteristic: The characteristic to introspect.
    /// - Returns: The characteristic's advertised ``CharacteristicProperties``.
    /// - Throws: ``BLESwiftError/notConnected``;
    ///   ``BLESwiftError/missingService(_:)``/``BLESwiftError/missingCharacteristic(_:)``;
    ///   or whatever error CoreBluetooth reports.
    public func properties(of characteristic: CharacteristicIdentifier) async throws -> CharacteristicProperties {
        let central = try resolveCentral()
        return try await central.properties(peripheral: id, characteristic: characteristic)
    }

    /// Reads `descriptor`'s current value as raw `Data`. Serialized on the parent
    /// characteristic's FIFO lane. The value's shape depends on the descriptor's type (UTF-8
    /// for User Description, little-endian integer for Extended Properties, opaque bytes for
    /// vendor descriptors); BLESwift hands back the raw bytes and lets the caller interpret
    /// them.
    ///
    /// - Parameters:
    ///   - descriptor: The descriptor to read from.
    ///   - timeout: How long to wait before giving up with ``BLESwiftError/timedOut``. `nil`
    ///     (the default) waits indefinitely.
    /// - Returns: The descriptor's value, as raw `Data`.
    /// - Throws: ``BLESwiftError/notConnected``;
    ///   ``BLESwiftError/missingService(_:)``/``BLESwiftError/missingCharacteristic(_:)``/``BLESwiftError/missingDescriptor(_:)``;
    ///   ``BLESwiftError/timedOut``; or whatever error CoreBluetooth reports.
    public func readDescriptor(_ descriptor: DescriptorIdentifier, timeout: Duration? = nil) async throws -> Data {
        let central = try resolveCentral()
        return try await central.performReadDescriptor(peripheral: id, descriptor: descriptor, timeout: timeout)
    }

    /// Writes `value` to `descriptor`, as raw `Data` — encode whatever the descriptor
    /// expects yourself. Serialized on the parent characteristic's FIFO lane. Descriptor
    /// writes are always with-response; CoreBluetooth exposes no write-type choice here.
    ///
    /// - Parameters:
    ///   - descriptor: The descriptor to write to.
    ///   - value: The raw bytes to write.
    ///   - timeout: How long to wait before giving up with ``BLESwiftError/timedOut``. `nil`
    ///     (the default) waits indefinitely.
    /// - Throws: ``BLESwiftError/notConnected``;
    ///   ``BLESwiftError/missingService(_:)``/``BLESwiftError/missingCharacteristic(_:)``/``BLESwiftError/missingDescriptor(_:)``;
    ///   ``BLESwiftError/timedOut``; or whatever error CoreBluetooth reports.
    public func writeDescriptor(_ descriptor: DescriptorIdentifier, value: Data, timeout: Duration? = nil) async throws {
        let central = try resolveCentral()
        try await central.performWriteDescriptor(peripheral: id, descriptor: descriptor, data: value, timeout: timeout)
    }

    /// Discovers and lists this peripheral's GATT services (the entry point to enumerating a
    /// peripheral whose UUIDs aren't known up front). Cached for this connection until a
    /// `didModifyServices` invalidation (observable on ``serviceChanges()``) resets it.
    ///
    /// - Returns: The discovered ``ServiceIdentifier``s (empty if none). Order unspecified.
    /// - Throws: ``BLESwiftError/notConnected``; ``BLESwiftError/operationCancelled``; or
    ///   whatever error CoreBluetooth reports.
    public func discoverServices() async throws -> [ServiceIdentifier] {
        let central = try resolveCentral()
        return try await central.enumerateServices(peripheral: id)
    }

    /// Discovers and lists the characteristics of `service`. The characteristic-level step
    /// of GATT enumeration (see ``discoverServices()``); cached per service, same
    /// invalidation semantics.
    ///
    /// - Parameter service: The service whose characteristics to enumerate.
    /// - Returns: The discovered ``CharacteristicIdentifier``s (empty if none). Order
    ///   unspecified.
    /// - Throws: ``BLESwiftError/notConnected``; ``BLESwiftError/missingService(_:)``;
    ///   ``BLESwiftError/operationCancelled``; or whatever error CoreBluetooth reports.
    public func discoverCharacteristics(for service: ServiceIdentifier) async throws -> [CharacteristicIdentifier] {
        let central = try resolveCentral()
        return try await central.enumerateCharacteristics(peripheral: id, service: service)
    }

    /// Discovers and lists the descriptors of `characteristic`. The descriptor-level step of
    /// GATT enumeration (see ``discoverServices()``); cached per characteristic.
    ///
    /// - Parameter characteristic: The characteristic whose descriptors to enumerate.
    /// - Returns: The discovered ``DescriptorIdentifier``s (empty if none). Order
    ///   unspecified. The Client Characteristic Configuration descriptor (the
    ///   notify/indicate toggle) is managed implicitly by BLESwift's notification API and
    ///   not surfaced here.
    /// - Throws: ``BLESwiftError/notConnected``;
    ///   ``BLESwiftError/missingService(_:)``/``BLESwiftError/missingCharacteristic(_:)``;
    ///   ``BLESwiftError/operationCancelled``; or whatever error CoreBluetooth reports.
    public func discoverDescriptors(for characteristic: CharacteristicIdentifier) async throws -> [DescriptorIdentifier] {
        let central = try resolveCentral()
        return try await central.enumerateDescriptors(peripheral: id, characteristic: characteristic)
    }

    /// Reads the peripheral's current RSSI (signal strength), in dBm. Has no owning
    /// characteristic, so concurrent calls are serialized independently of any
    /// characteristic's FIFO.
    ///
    /// - Parameter timeout: How long to wait before giving up with ``BLESwiftError/timedOut``.
    ///   `nil` (the default) waits indefinitely.
    /// - Returns: The current RSSI, in dBm.
    /// - Throws: ``BLESwiftError/notConnected``; ``BLESwiftError/timedOut``; or whatever
    ///   error CoreBluetooth reports.
    public func readRSSI(timeout: Duration? = nil) async throws -> Int {
        let central = try resolveCentral()
        return try await central.performReadRSSI(peripheral: id, timeout: timeout)
    }

    /// This peripheral's maximum payload length in bytes for a single write of `type`. A
    /// best-effort sizing hint that never throws; returns a documented default (the classic
    /// ATT_MTU-3 default of 20 bytes) if this peripheral is no longer connected.
    ///
    /// - Parameter type: Which write type to report the maximum payload length for.
    /// - Returns: The maximum payload length, in bytes.
    public func maximumWriteValueLength(for type: WriteType) async -> Int {
        guard let central = centralBox.central else {
            return Central.defaultMaximumWriteValueLength
        }
        return await central.maximumWriteValueLength(peripheral: id, for: type)
    }

    /// Returns a multicast stream of every `didModifyServices` invalidation for THIS
    /// peripheral only. No replay — a late subscriber only sees invalidations after it
    /// starts consuming. Not actor-isolated to fetch, so this hands back a stream
    /// synchronously even if the owning ``Central`` has already deallocated (the stream then
    /// finishes immediately). Survives this peripheral disconnecting and reconnecting; keyed
    /// by identifier, not by connection attempt.
    public func serviceChanges() -> AsyncStream<[ServiceIdentifier]> {
        guard let central = centralBox.central else {
            return AsyncStream { continuation in continuation.finish() }
        }
        return central.serviceChangesRegistry.broadcaster(for: id).stream()
    }
}
