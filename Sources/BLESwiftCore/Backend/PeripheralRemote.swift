//
//  PeripheralRemote.swift
//  BLESwiftCore
//

import Foundation

/// A protocol seam over `CBPeripheral`, speaking exclusively in BLESwift-owned types.
/// Conformances: CoreBluetooth (`BLESwift`) and scriptable fakes (`BLESwiftTestSupport`);
/// conforming your own type is possible but unsupported.
///
/// **Identifier-based, not object-graph-based.** `PeripheralRemote` takes
/// ``ServiceIdentifier``/``CharacteristicIdentifier`` value types throughout rather than
/// `CBService`/`CBCharacteristic` references; the `CBPeripheral` conformance resolves them
/// internally, silently no-op-ing an operation whose target has not yet been discovered.
///
/// - Important: Every ``eventHandler`` delivery must happen asynchronously, on the serial
///   queue the owning `Central` was constructed with — never deliver inline.
/// - Note: ``connectionState`` is renamed to avoid colliding with `CBPeripheral`'s own
///   `state` property, exactly as on ``CentralManaging``.
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
    /// `CBPeripheral.discoverDescriptors(for:)`.
    func discoverDescriptors(for characteristic: CharacteristicIdentifier)

    /// Requests the current value of an already-discovered descriptor. A no-op if
    /// `descriptor` has not yet been discovered. Mirrors `CBPeripheral.readValue(for:)` for
    /// a `CBDescriptor`.
    func readValue(for descriptor: DescriptorIdentifier)

    /// Writes `data` to an already-discovered descriptor. A no-op if `descriptor` has not
    /// yet been discovered. Descriptor writes are always with-response. Mirrors
    /// `CBPeripheral.writeValue(_:for:)` for a `CBDescriptor`.
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
    /// characteristic with ``BLESwiftError/readConflictsWithNotification``.
    func isNotifying(_ characteristic: CharacteristicIdentifier) -> Bool

    /// The set of operations `characteristic` advertises support for. Mirrors
    /// `CBCharacteristic.properties`. Returns `[]` if `characteristic` has not yet been
    /// discovered.
    func properties(of characteristic: CharacteristicIdentifier) -> CharacteristicProperties

    /// Every service currently discovered on this peripheral. Empty until a
    /// `discoverServices(_:)` completion has landed. Maps `CBPeripheral.services`; order is
    /// unspecified.
    var discoveredServices: [ServiceIdentifier] { get }

    /// Every characteristic currently discovered under `service`. Maps
    /// `CBService.characteristics`; order is unspecified.
    func discoveredCharacteristics(for service: ServiceIdentifier) -> [CharacteristicIdentifier]

    /// Every descriptor currently discovered under `characteristic`. Maps
    /// `CBCharacteristic.descriptors`; order is unspecified.
    func discoveredDescriptors(for characteristic: CharacteristicIdentifier) -> [DescriptorIdentifier]

    /// Opens an L2CAP channel to `psm`. Completion arrives asynchronously as
    /// ``PeripheralEvent/didOpenL2CAPChannel(channel:error:)`` (one per call, in call
    /// order). Mirrors `CBPeripheral.openL2CAPChannel(_:)`, taking BLESwift's owned
    /// ``L2CAPPSM`` rather than CoreBluetooth's `CBL2CAPPSM`.
    func openL2CAPChannel(_ psm: L2CAPPSM)
}
