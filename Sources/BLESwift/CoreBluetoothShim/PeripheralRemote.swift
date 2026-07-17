//
//  PeripheralRemote.swift
//  BLESwift
//

import CoreBluetooth
import Foundation

/// A protocol seam over `CBPeripheral`, mirroring only the API surface BLESwift uses.
///
/// `CBPeripheral` has no accessible public initializer and cannot be instantiated in
/// tests, so the actor core is written entirely against this protocol instead of the
/// concrete CoreBluetooth type. `CBPeripheral` conforms retroactively (see
/// `CBPeripheral+PeripheralRemote.swift`); a scriptable `FakePeripheral` conforms for
/// tests, standing in for hardware.
///
/// **Identifier-based, not object-graph-based.** Real `CBPeripheral` GATT operations
/// take `CBService`/`CBCharacteristic` object references, which only exist once
/// discovery has run. `PeripheralRemote` instead takes BLESwift's ``ServiceIdentifier`` and
/// ``CharacteristicIdentifier`` value types throughout; the `CBPeripheral` conformance
/// resolves those identifiers to the underlying `CBService`/`CBCharacteristic` internally,
/// silently no-op-ing an operation whose service or characteristic has not yet
/// been discovered. This keeps `FakePeripheral` trivial (no `CBService`/`CBCharacteristic`
/// stand-ins needed) and avoids a nested existential hierarchy.
protocol PeripheralRemote: AnyObject {

    /// The identifier CoreBluetooth uses for this peripheral. Mirrors
    /// `CBPeripheral.identifier`.
    var identifier: UUID { get }

    /// The peripheral's advertised or cached name. Mirrors `CBPeripheral.name`.
    var name: String? { get }

    /// The peripheral's current connection state. Mirrors `CBPeripheral.state`.
    var state: CBPeripheralState { get }

    /// Whether the peripheral is currently able to accept a
    /// `.withoutResponse` write without CoreBluetooth dropping it. Mirrors
    /// `CBPeripheral.canSendWriteWithoutResponse`; used to await
    /// ``PeripheralEvent/isReadyToSendWriteWithoutResponse`` before writing when `false`.
    var canSendWriteWithoutResponse: Bool { get }

    /// Attaches (or, with `nil`, detaches) the object this peripheral's events should be
    /// delivered to. Mirrors assigning `CBPeripheral.delegate` — the one CoreBluetooth
    /// wiring step a `connect(_:options:)` call does **not** perform implicitly; without
    /// it, none of this peripheral's GATT callbacks would ever arrive (Phase 8 BINDING
    /// ledger fix — the gap was masked in tests because fakes deliver through their
    /// `eventSink`s instead of a delegate).
    ///
    /// Typed `AnyObject?` rather than `CBPeripheralDelegate?` so the shim stays free of
    /// CoreBluetooth delegate types in requirements: the `CBPeripheral` conformance
    /// downcasts internally (a non-delegate target simply clears the delegate — mixing
    /// shim families is a programmer error, never a trap, per ``CentralManaging``'s
    /// conventions); `FakePeripheral` records the call and ignores the target (fakes
    /// deliver via `eventSink`, not a delegate).
    func attachEventTarget(_ target: AnyObject?)

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
    func writeValue(_ data: Data, for characteristic: CharacteristicIdentifier, type: CBCharacteristicWriteType)

    /// Enables or disables notifications for an already-discovered characteristic. A
    /// no-op if `characteristic` has not yet been discovered. Mirrors
    /// `CBPeripheral.setNotifyValue(_:for:)`.
    func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicIdentifier)

    /// Requests the peripheral's current RSSI. Mirrors `CBPeripheral.readRSSI()`.
    func readRSSI()

    /// The maximum payload length in bytes for a single write of `type`. Mirrors
    /// `CBPeripheral.maximumWriteValueLength(for:)`.
    func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int

    /// Whether `service` has already been discovered on this peripheral, for
    /// discovery-cache short-circuiting.
    func isDiscovered(_ service: ServiceIdentifier) -> Bool

    /// Whether `characteristic` has already been discovered on this peripheral, for
    /// discovery-cache short-circuiting.
    func isDiscovered(_ characteristic: CharacteristicIdentifier) -> Bool

    /// Whether `characteristic` currently has notifications enabled. Mirrors
    /// `CBCharacteristic.isNotifying`. Used to reject a concurrent `read` on the same
    /// characteristic with ``BLESwiftError/readConflictsWithNotification`` rather than letting
    /// CoreBluetooth's ambiguous `didUpdateValueFor` delivery race the two.
    func isNotifying(_ characteristic: CharacteristicIdentifier) -> Bool
}
