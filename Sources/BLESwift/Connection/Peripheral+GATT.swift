//
//  Peripheral+GATT.swift
//  BLESwift
//

import BLESwiftCore
import Foundation

/// GATT operations: read, write, RSSI, and service-change notifications. They go through the
/// owning ``Central`` actor. Each method discovers the service or characteristic that it needs
/// lazily.
extension Peripheral {

    /// Reads the current value of `characteristic` and decodes it as `Value`. Concurrent
    /// operations on the *same* characteristic run in call order (FIFO). Operations on
    /// different characteristics interleave freely.
    ///
    /// - Parameters:
    ///   - characteristic: The characteristic to read from.
    ///   - timeout: How long to wait before the method gives up with
    ///     ``BLESwiftError/timedOut``. The default `nil` waits without a limit.
    /// - Returns: The value of the characteristic, decoded as `Value`.
    /// - Throws: One of these errors:
    ///   - ``BLESwiftError/notConnected``.
    ///   - ``BLESwiftError/readConflictsWithNotification`` if `characteristic` has
    ///     notifications enabled. CoreBluetooth cannot tell a read completion from a
    ///     notification.
    ///   - ``BLESwiftError/missingService(_:)`` or ``BLESwiftError/missingCharacteristic(_:)``.
    ///   - ``BLESwiftError/timedOut``.
    ///   - The error that the `Receivable` decoding of `Value` throws.
    ///   - The error that CoreBluetooth reports.
    public func read<Value: Receivable>(from characteristic: CharacteristicIdentifier, timeout: Duration? = nil) async throws -> Value {
        let central = try resolveCentral()
        let data = try await central.performRead(peripheral: id, characteristic: characteristic, timeout: timeout)
        return try Value(bluetoothData: data)
    }

    /// Writes `value` to `characteristic`. The method orders calls like
    /// ``read(from:timeout:)``. For `type: .withoutResponse`, the method first waits while
    /// CoreBluetooth's `canSendWriteWithoutResponse` is `false`, because CoreBluetooth can
    /// silently drop the payload otherwise. This write type has no completion callback, so
    /// the call returns as soon as it makes the write.
    ///
    /// - Parameters:
    ///   - value: The value to write.
    ///   - characteristic: The characteristic to write to.
    ///   - type: Whether to wait for the write confirmation. The default is `.withResponse`.
    ///   - timeout: How long to wait before the method gives up with
    ///     ``BLESwiftError/timedOut``. The default `nil` waits without a limit.
    /// - Throws: One of these errors:
    ///   - ``BLESwiftError/notConnected``.
    ///   - ``BLESwiftError/missingService(_:)`` or ``BLESwiftError/missingCharacteristic(_:)``.
    ///   - ``BLESwiftError/timedOut``.
    ///   - The error that the `Transmittable` encoding of `value` throws.
    ///   - The error that CoreBluetooth reports.
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

    /// The operations that `characteristic` advertises, for example readable, writable, or
    /// notifiable.
    ///
    /// - Parameter characteristic: The characteristic to examine.
    /// - Returns: The advertised ``CharacteristicProperties`` of the characteristic.
    /// - Throws: One of these errors:
    ///   - ``BLESwiftError/notConnected``.
    ///   - ``BLESwiftError/missingService(_:)`` or ``BLESwiftError/missingCharacteristic(_:)``.
    ///   - The error that CoreBluetooth reports.
    public func properties(of characteristic: CharacteristicIdentifier) async throws -> CharacteristicProperties {
        let central = try resolveCentral()
        return try await central.properties(peripheral: id, characteristic: characteristic)
    }

    /// Reads the current value of `descriptor` as raw `Data`. The method runs in the FIFO lane
    /// of the parent characteristic. The value's format depends on the descriptor type:
    ///
    /// - User Description: UTF-8.
    /// - Extended Properties: a little-endian integer.
    /// - Vendor descriptors: opaque bytes.
    ///
    /// BLESwift returns the raw bytes. The caller must interpret them.
    ///
    /// - Parameters:
    ///   - descriptor: The descriptor to read from.
    ///   - timeout: How long to wait before the method gives up with
    ///     ``BLESwiftError/timedOut``. The default `nil` waits without a limit.
    /// - Returns: The value of the descriptor, as raw `Data`.
    /// - Throws: One of these errors:
    ///   - ``BLESwiftError/notConnected``.
    ///   - ``BLESwiftError/missingService(_:)``, ``BLESwiftError/missingCharacteristic(_:)``,
    ///     or ``BLESwiftError/missingDescriptor(_:)``.
    ///   - ``BLESwiftError/timedOut``.
    ///   - The error that CoreBluetooth reports.
    public func readDescriptor(_ descriptor: DescriptorIdentifier, timeout: Duration? = nil) async throws -> Data {
        let central = try resolveCentral()
        return try await central.performReadDescriptor(peripheral: id, descriptor: descriptor, timeout: timeout)
    }

    /// Writes `value` to `descriptor` as raw `Data`. Encode the descriptor's format yourself.
    /// The method runs in the FIFO lane of the parent characteristic. Descriptor writes are
    /// always with-response.
    ///
    /// - Parameters:
    ///   - descriptor: The descriptor to write to.
    ///   - value: The raw bytes to write.
    ///   - timeout: How long to wait before the method gives up with
    ///     ``BLESwiftError/timedOut``. The default `nil` waits without a limit.
    /// - Throws: One of these errors:
    ///   - ``BLESwiftError/notConnected``.
    ///   - ``BLESwiftError/missingService(_:)``, ``BLESwiftError/missingCharacteristic(_:)``,
    ///     or ``BLESwiftError/missingDescriptor(_:)``.
    ///   - ``BLESwiftError/timedOut``.
    ///   - The error that CoreBluetooth reports.
    public func writeDescriptor(_ descriptor: DescriptorIdentifier, value: Data, timeout: Duration? = nil) async throws {
        let central = try resolveCentral()
        try await central.performWriteDescriptor(peripheral: id, descriptor: descriptor, data: value, timeout: timeout)
    }

    /// Discovers and lists the GATT services of this peripheral. Use it to enumerate a
    /// peripheral whose UUIDs you do not know in advance. The result is cached for this
    /// connection. A `didModifyServices` invalidation, which ``serviceChanges()`` reports,
    /// resets the cache.
    ///
    /// - Returns: The discovered ``ServiceIdentifier`` values. The list is empty if there are
    ///   none. The order is unspecified.
    /// - Throws: One of these errors:
    ///   - ``BLESwiftError/notConnected``.
    ///   - ``BLESwiftError/operationCancelled``.
    ///   - The error that CoreBluetooth reports.
    public func discoverServices() async throws -> [ServiceIdentifier] {
        let central = try resolveCentral()
        return try await central.enumerateServices(peripheral: id)
    }

    /// Discovers and lists the characteristics of `service` (see ``discoverServices()``). The
    /// result is cached for each service, with the same invalidation rules.
    ///
    /// - Parameter service: The service whose characteristics to enumerate.
    /// - Returns: The discovered ``CharacteristicIdentifier`` values. The list is empty if
    ///   there are none. The order is unspecified.
    /// - Throws: One of these errors:
    ///   - ``BLESwiftError/notConnected``.
    ///   - ``BLESwiftError/missingService(_:)``.
    ///   - ``BLESwiftError/operationCancelled``.
    ///   - The error that CoreBluetooth reports.
    public func discoverCharacteristics(for service: ServiceIdentifier) async throws -> [CharacteristicIdentifier] {
        let central = try resolveCentral()
        return try await central.enumerateCharacteristics(peripheral: id, service: service)
    }

    /// Discovers and lists the descriptors of `characteristic` (see ``discoverServices()``).
    /// The result is cached for each characteristic.
    ///
    /// - Parameter characteristic: The characteristic whose descriptors to enumerate.
    /// - Returns: The discovered ``DescriptorIdentifier`` values. The list is empty if there
    ///   are none. The order is unspecified. The result omits the Client Characteristic
    ///   Configuration descriptor (the notify/indicate toggle), which the notification API
    ///   manages.
    /// - Throws: One of these errors:
    ///   - ``BLESwiftError/notConnected``.
    ///   - ``BLESwiftError/missingService(_:)`` or ``BLESwiftError/missingCharacteristic(_:)``.
    ///   - ``BLESwiftError/operationCancelled``.
    ///   - The error that CoreBluetooth reports.
    public func discoverDescriptors(for characteristic: CharacteristicIdentifier) async throws -> [DescriptorIdentifier] {
        let central = try resolveCentral()
        return try await central.enumerateDescriptors(peripheral: id, characteristic: characteristic)
    }

    /// Reads the current RSSI (signal strength) of the peripheral, in dBm. The RSSI has no
    /// characteristic, so concurrent calls run in their own queue, independent of any
    /// characteristic's FIFO.
    ///
    /// - Parameter timeout: How long to wait before the method gives up with
    ///   ``BLESwiftError/timedOut``. The default `nil` waits without a limit.
    /// - Returns: The current RSSI, in dBm.
    /// - Throws: One of these errors:
    ///   - ``BLESwiftError/notConnected``.
    ///   - ``BLESwiftError/timedOut``.
    ///   - The error that CoreBluetooth reports.
    public func readRSSI(timeout: Duration? = nil) async throws -> Int {
        let central = try resolveCentral()
        return try await central.performReadRSSI(peripheral: id, timeout: timeout)
    }

    /// The maximum payload length in bytes for a single write of `type`. This is a best-effort
    /// hint and never throws. If this peripheral is no longer connected, it returns 20 bytes,
    /// the classic ATT_MTU-3 value.
    ///
    /// - Parameter type: The write type.
    /// - Returns: The maximum payload length, in bytes.
    public func maximumWriteValueLength(for type: WriteType) async -> Int {
        guard let central = centralBox.central else {
            return Central.defaultMaximumWriteValueLength
        }
        return await central.maximumWriteValueLength(peripheral: id, for: type)
    }

    /// Returns a multicast stream of every `didModifyServices` invalidation for THIS
    /// peripheral only. There is no replay. A subscriber sees only the invalidations after it
    /// subscribes. The method is synchronous and needs no actor isolation. If the owning
    /// ``Central`` is deallocated, the stream finishes immediately. The stream survives a
    /// disconnect and a reconnect of this peripheral, because it is keyed by the identifier
    /// and not the connection.
    public func serviceChanges() -> AsyncStream<[ServiceIdentifier]> {
        guard let central = centralBox.central else {
            return AsyncStream { continuation in continuation.finish() }
        }
        return central.serviceChangesRegistry.broadcaster(for: id).stream()
    }
}
