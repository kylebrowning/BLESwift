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

    /// The set of operations `characteristic` advertises support for — whether it's
    /// readable, writable, notifiable, and so on.
    ///
    /// Use this for capability-driven UI or clearer error paths, rather than discovering a
    /// characteristic's capabilities by attempting an operation and inspecting the error.
    /// Like ``read(from:timeout:)``/``write(_:to:type:timeout:)``, this lazily discovers the
    /// owning service and characteristic first if needed, and serializes against other
    /// operations on the *same* characteristic.
    ///
    /// - Parameter characteristic: The characteristic to introspect.
    /// - Returns: The characteristic's advertised ``CharacteristicProperties``.
    /// - Throws: ``BLESwiftError/notConnected`` if this peripheral is no longer connected;
    ///   ``BLESwiftError/missingService(_:)``/``BLESwiftError/missingCharacteristic(_:)`` if
    ///   discovery fails; or whatever error CoreBluetooth reports for that discovery.
    public func properties(of characteristic: CharacteristicIdentifier) async throws -> CharacteristicProperties {
        let central = try resolveCentral()
        return try await central.properties(peripheral: id, characteristic: characteristic)
    }

    /// Reads `descriptor`'s current value as raw `Data`.
    ///
    /// Descriptors — the Characteristic User Description, Presentation Format, and
    /// vendor-specific descriptors, among others — complete GATT attribute coverage beyond
    /// characteristics. The owning service, characteristic, and the characteristic's
    /// descriptors are discovered first if needed (extending BLESwift's lazy discovery one
    /// level, cache-short-circuited exactly like service/characteristic discovery). The
    /// operation is serialized on the *parent characteristic's* FIFO lane, so a descriptor
    /// read never races a read or write on the same characteristic.
    ///
    /// The value is returned as raw `Data`: a descriptor's payload shape depends on its type
    /// (a UTF-8 string for the User Description, a little-endian integer for the Extended
    /// Properties, opaque bytes for a vendor descriptor), so BLESwift hands back the bytes and
    /// lets the caller interpret them — see ``Data`` extraction helpers, or decode manually.
    /// (CoreBluetooth's own `Any?`-typed descriptor value is converted to `Data` eagerly at
    /// the backend boundary; `NSString` becomes its UTF-8 bytes, `NSNumber` its 16-bit
    /// little-endian encoding, `NSData` its bytes verbatim.)
    ///
    /// - Parameters:
    ///   - descriptor: The descriptor to read from.
    ///   - timeout: How long to wait before giving up with ``BLESwiftError/timedOut``. `nil`
    ///     (the default) waits indefinitely.
    /// - Returns: The descriptor's value, as raw `Data`.
    /// - Throws: ``BLESwiftError/notConnected`` if this peripheral is no longer connected;
    ///   ``BLESwiftError/missingService(_:)``/``BLESwiftError/missingCharacteristic(_:)``/``BLESwiftError/missingDescriptor(_:)``
    ///   if discovery fails; ``BLESwiftError/timedOut`` on timeout; or whatever error
    ///   CoreBluetooth reports for the read.
    public func readDescriptor(_ descriptor: DescriptorIdentifier, timeout: Duration? = nil) async throws -> Data {
        let central = try resolveCentral()
        return try await central.performReadDescriptor(peripheral: id, descriptor: descriptor, timeout: timeout)
    }

    /// Writes `value` to `descriptor`.
    ///
    /// The owning service, characteristic, and the characteristic's descriptors are
    /// discovered first if needed, and the operation is serialized on the *parent
    /// characteristic's* FIFO lane (see ``readDescriptor(_:timeout:)``). Descriptor writes
    /// are always with-response — CoreBluetooth exposes no write-type choice for a
    /// descriptor — so this always awaits the write confirmation before returning.
    ///
    /// `value` is written as raw `Data`; encode whatever the specific descriptor expects (for
    /// example, UTF-8 bytes for a writable User Description) yourself.
    ///
    /// - Parameters:
    ///   - descriptor: The descriptor to write to.
    ///   - value: The raw bytes to write.
    ///   - timeout: How long to wait before giving up with ``BLESwiftError/timedOut``. `nil`
    ///     (the default) waits indefinitely.
    /// - Throws: ``BLESwiftError/notConnected`` if this peripheral is no longer connected;
    ///   ``BLESwiftError/missingService(_:)``/``BLESwiftError/missingCharacteristic(_:)``/``BLESwiftError/missingDescriptor(_:)``
    ///   if discovery fails; ``BLESwiftError/timedOut`` on timeout; or whatever error
    ///   CoreBluetooth reports for the write.
    public func writeDescriptor(_ descriptor: DescriptorIdentifier, value: Data, timeout: Duration? = nil) async throws {
        let central = try resolveCentral()
        try await central.performWriteDescriptor(peripheral: id, descriptor: descriptor, data: value, timeout: timeout)
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
