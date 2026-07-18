//
//  PeripheralRemote.swift
//  BLESwiftCore
//

import Foundation

/// This is BLESwift's backend implementation seam. BLESwift ships two conformances —
/// CoreBluetooth (the `BLESwift` module) and scriptable fakes (`BLESwiftTestSupport`).
/// Conforming your own types is possible but unsupported: the semantic contract (event
/// ordering, queue confinement, delivery asynchrony) is documented here on a best-effort
/// basis and may gain requirements in any release.
///
/// A protocol seam over `CBPeripheral`, mirroring only the API surface BLESwift uses,
/// speaking exclusively in BLESwift-owned (never CoreBluetooth) types.
///
/// `CBPeripheral` has no accessible public initializer and cannot be instantiated in
/// tests, so `Central` (in the `BLESwift` module) is written entirely against this
/// protocol instead of the concrete CoreBluetooth type. `CBPeripheral` conforms
/// retroactively (`BLESwift`'s `CBPeripheral+PeripheralRemote.swift`); `BLESwiftTestSupport`'s
/// `FakePeripheral` conforms for tests, standing in for hardware.
///
/// **Identifier-based, not object-graph-based.** Real `CBPeripheral` GATT operations
/// take `CBService`/`CBCharacteristic` object references, which only exist once
/// discovery has run. `PeripheralRemote` instead takes BLESwift's ``ServiceIdentifier`` and
/// ``CharacteristicIdentifier`` value types throughout; the `CBPeripheral` conformance
/// resolves those identifiers to the underlying `CBService`/`CBCharacteristic` internally,
/// silently no-op-ing an operation whose service or characteristic has not yet
/// been discovered. This keeps the fake peripheral trivial (no `CBService`/`CBCharacteristic`
/// stand-ins needed) and avoids a nested existential hierarchy.
///
/// - Important: Every ``eventHandler`` delivery must happen **asynchronously**, on the
///   single serial `DispatchSerialQueue` the owning `Central` was constructed with — never
///   deliver inline from within a method call on this protocol.
///
/// - Note: ``connectionState`` is named to avoid colliding with `CBPeripheral`'s own
///   identically-named `state` property — see ``CentralManaging``'s note on
///   ``CentralManaging/radioState``/``CentralManaging/bluetoothAuthorization`` for why.
public protocol PeripheralRemote: AnyObject {

    /// The identifier CoreBluetooth uses for this peripheral. Mirrors
    /// `CBPeripheral.identifier`.
    var identifier: UUID { get }

    /// The peripheral's advertised or cached name. Mirrors `CBPeripheral.name`.
    var name: String? { get }

    /// The peripheral's current connection state. Mirrors `CBPeripheral.state`.
    var connectionState: PeripheralConnectionState { get }

    /// Whether the peripheral is currently able to accept a
    /// `.withoutResponse` write without CoreBluetooth dropping it. Mirrors
    /// `CBPeripheral.canSendWriteWithoutResponse`; used to await
    /// ``PeripheralEvent/isReadyToSendWriteWithoutResponse`` before writing when `false`.
    var canSendWriteWithoutResponse: Bool { get }

    /// Receives every ``PeripheralEvent`` this peripheral produces. Mirrors assigning
    /// `CBPeripheral.delegate` — the one CoreBluetooth wiring step a `connect(_:options:)`
    /// call does **not** perform implicitly; without setting this, none of this
    /// peripheral's GATT callbacks would ever arrive. `Central` sets this on every path
    /// that creates a session for this peripheral, and clears it (`nil`) on teardown. See
    /// the delivery contract on the protocol's doc comment.
    var eventHandler: ((PeripheralEvent) -> Void)? { get set }

    /// Discovers the given services (or all services, if `nil`). Mirrors
    /// `CBPeripheral.discoverServices(_:)`.
    func discoverServices(_ services: [ServiceIdentifier]?)

    /// Discovers the given characteristics (or all characteristics, if `nil`) of an
    /// already-discovered service. A no-op if `service` has not yet been discovered.
    /// Mirrors `CBPeripheral.discoverCharacteristics(_:for:)`.
    func discoverCharacteristics(_ characteristics: [CharacteristicIdentifier]?, for service: ServiceIdentifier)

    /// Requests the current value of an already-discovered characteristic. A no-op if
    /// `characteristic` has not yet been discovered. Mirrors
    /// `CBPeripheral.readValue(for:)`.
    func readValue(for characteristic: CharacteristicIdentifier)

    /// Writes `data` to an already-discovered characteristic. A no-op if `characteristic`
    /// has not yet been discovered. Mirrors `CBPeripheral.writeValue(_:for:type:)`.
    func writeValue(_ data: Data, for characteristic: CharacteristicIdentifier, type: WriteType)

    /// Enables or disables notifications for an already-discovered characteristic. A
    /// no-op if `characteristic` has not yet been discovered. Mirrors
    /// `CBPeripheral.setNotifyValue(_:for:)`.
    func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicIdentifier)

    /// Discovers all descriptors of an already-discovered characteristic. A no-op if
    /// `characteristic` has not yet been discovered. Mirrors
    /// `CBPeripheral.discoverDescriptors(for:)` — which, unlike characteristic discovery,
    /// takes no filter list: a characteristic's descriptors are always discovered as a
    /// group.
    func discoverDescriptors(for characteristic: CharacteristicIdentifier)

    /// Requests the current value of an already-discovered descriptor. A no-op if
    /// `descriptor` has not yet been discovered. Mirrors `CBPeripheral.readValue(for:)` for
    /// a `CBDescriptor` — its completion (``PeripheralEvent/didUpdateValueForDescriptor(descriptor:value:error:)``)
    /// carries the value already converted to `Data`.
    func readValue(for descriptor: DescriptorIdentifier)

    /// Writes `data` to an already-discovered descriptor. A no-op if `descriptor` has not
    /// yet been discovered. Mirrors `CBPeripheral.writeValue(_:for:)` for a `CBDescriptor` —
    /// which, unlike a characteristic write, has no write-type parameter (descriptor writes
    /// are always with-response) and always delivers a
    /// ``PeripheralEvent/didWriteValueForDescriptor(descriptor:error:)`` completion.
    func writeValue(_ data: Data, for descriptor: DescriptorIdentifier)

    /// Requests the peripheral's current RSSI. Mirrors `CBPeripheral.readRSSI()`.
    func readRSSI()

    /// The maximum payload length in bytes for a single write of `type`. Mirrors
    /// `CBPeripheral.maximumWriteValueLength(for:)`.
    func maximumWriteValueLength(for type: WriteType) -> Int

    /// Whether `service` has already been discovered on this peripheral, for
    /// discovery-cache short-circuiting.
    func isDiscovered(_ service: ServiceIdentifier) -> Bool

    /// Whether `characteristic` has already been discovered on this peripheral, for
    /// discovery-cache short-circuiting.
    func isDiscovered(_ characteristic: CharacteristicIdentifier) -> Bool

    /// Whether `descriptor` has already been discovered on this peripheral, for
    /// discovery-cache short-circuiting.
    func isDiscovered(_ descriptor: DescriptorIdentifier) -> Bool

    /// Whether `characteristic` currently has notifications enabled. Mirrors
    /// `CBCharacteristic.isNotifying`. Used to reject a concurrent `read` on the same
    /// characteristic with ``BLESwiftError/readConflictsWithNotification`` rather than letting
    /// CoreBluetooth's ambiguous `didUpdateValueFor` delivery race the two.
    func isNotifying(_ characteristic: CharacteristicIdentifier) -> Bool

    /// The set of operations `characteristic` advertises support for. Mirrors
    /// `CBCharacteristic.properties`, mapped to BLESwift's own ``CharacteristicProperties``
    /// at the CoreBluetooth seam. Returns `[]` (an empty set) if `characteristic` has not
    /// yet been discovered — callers trigger lazy discovery first, exactly as they do before
    /// `readValue(for:)`/`writeValue(_:for:type:)`.
    func properties(of characteristic: CharacteristicIdentifier) -> CharacteristicProperties
}
