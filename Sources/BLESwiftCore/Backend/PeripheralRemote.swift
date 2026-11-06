//
//  PeripheralRemote.swift
//  BLESwiftCore
//

import Foundation

/// A protocol seam over `CBPeripheral`. It uses only types that BLESwift owns. The conformances are
/// CoreBluetooth (`BLESwift`) and scriptable fakes (`BLESwiftTestSupport`). You can conform your
/// own type, but this is not supported.
///
/// **Identifier-based, not object-graph-based.** `PeripheralRemote` uses the value types
/// ``ServiceIdentifier`` and ``CharacteristicIdentifier`` throughout, and no `CBService` or
/// `CBCharacteristic` references. The `CBPeripheral` conformance resolves the identifiers
/// internally. If an operation's target is not yet discovered, the operation silently does
/// nothing.
///
/// - Important: Every ``eventHandler`` delivery must happen asynchronously, on the serial queue
///   that the owning `Central` was created with. Never deliver inline.
/// - Note: ``connectionState`` is renamed to avoid a collision with `CBPeripheral`'s `state`
///   property, as on ``CentralManaging``.
public protocol PeripheralRemote: AnyObject {

    /// The identifier that CoreBluetooth uses for this peripheral. Mirrors
    /// `CBPeripheral.identifier`.
    var identifier: UUID { get }

    /// The peripheral's advertised or cached name. Mirrors `CBPeripheral.name`.
    var name: String? { get }

    /// The peripheral's current connection state. Mirrors `CBPeripheral.state`.
    var connectionState: PeripheralConnectionState { get }

    /// Whether the connection required ANCS and the user authorized ANCS data sharing. Mirrors
    /// `CBPeripheral.ancsAuthorized`. CoreBluetooth has this on iOS only. Conformances return
    /// `false` on other platforms.
    var ancsAuthorized: Bool { get }

    /// Whether the peripheral can accept a `.withoutResponse` write without CoreBluetooth dropping
    /// it. Mirrors `CBPeripheral.canSendWriteWithoutResponse`. If it is `false`, wait for
    /// ``PeripheralEvent/isReadyToSendWriteWithoutResponse`` before you write.
    var canSendWriteWithoutResponse: Bool { get }

    /// Receives every ``PeripheralEvent`` that this peripheral produces. Mirrors setting
    /// `CBPeripheral.delegate`. `connect(_:options:)` does **not** set it implicitly. If you do not
    /// set this handler, none of this peripheral's GATT callbacks arrive. `Central` sets the
    /// handler on every path that creates a session for this peripheral, and clears it (`nil`) on
    /// teardown. See the delivery contract in the protocol's doc comment.
    var eventHandler: ((PeripheralEvent) -> Void)? { get set }

    /// Discovers the given services (or all services, if `nil`). Mirrors
    /// `CBPeripheral.discoverServices(_:)`.
    func discoverServices(_ services: [ServiceIdentifier]?)

    /// Discovers the given characteristics (or all characteristics, if `nil`) of a service that is
    /// already discovered. If `service` is not yet discovered, this function does nothing. Mirrors
    /// `CBPeripheral.discoverCharacteristics(_:for:)`.
    func discoverCharacteristics(_ characteristics: [CharacteristicIdentifier]?, for service: ServiceIdentifier)

    /// Requests the current value of a characteristic that is already discovered. If
    /// `characteristic` is not yet discovered, this function does nothing. Mirrors
    /// `CBPeripheral.readValue(for:)`.
    func readValue(for characteristic: CharacteristicIdentifier)

    /// Writes `data` to a characteristic that is already discovered. If `characteristic` is not yet
    /// discovered, this function does nothing. Mirrors `CBPeripheral.writeValue(_:for:type:)`.
    func writeValue(_ data: Data, for characteristic: CharacteristicIdentifier, type: WriteType)

    /// Enables or disables notifications for a characteristic that is already discovered. If
    /// `characteristic` is not yet discovered, this function does nothing. Mirrors
    /// `CBPeripheral.setNotifyValue(_:for:)`.
    func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicIdentifier)

    /// Discovers all descriptors of a characteristic that is already discovered. If
    /// `characteristic` is not yet discovered, this function does nothing. Mirrors
    /// `CBPeripheral.discoverDescriptors(for:)`.
    func discoverDescriptors(for characteristic: CharacteristicIdentifier)

    /// Requests the current value of a descriptor that is already discovered. If `descriptor` is
    /// not yet discovered, this function does nothing. Mirrors `CBPeripheral.readValue(for:)` for a
    /// `CBDescriptor`.
    func readValue(for descriptor: DescriptorIdentifier)

    /// Writes `data` to a descriptor that is already discovered. If `descriptor` is not yet
    /// discovered, this function does nothing. Descriptor writes are always with a response.
    /// Mirrors `CBPeripheral.writeValue(_:for:)` for a `CBDescriptor`.
    func writeValue(_ data: Data, for descriptor: DescriptorIdentifier)

    /// Requests the peripheral's current RSSI. Mirrors `CBPeripheral.readRSSI()`.
    func readRSSI()

    /// The maximum payload length in bytes for a single write of `type`. Mirrors
    /// `CBPeripheral.maximumWriteValueLength(for:)`.
    func maximumWriteValueLength(for type: WriteType) -> Int

    /// Whether `service` is already discovered on this peripheral. The discovery cache uses this to
    /// skip a repeat discovery.
    func isDiscovered(_ service: ServiceIdentifier) -> Bool

    /// Whether `characteristic` is already discovered on this peripheral. The discovery cache uses
    /// this to skip a repeat discovery.
    func isDiscovered(_ characteristic: CharacteristicIdentifier) -> Bool

    /// Whether `descriptor` is already discovered on this peripheral. The discovery cache uses this
    /// to skip a repeat discovery.
    func isDiscovered(_ descriptor: DescriptorIdentifier) -> Bool

    /// Whether `characteristic` has notifications enabled. Mirrors
    /// `CBCharacteristic.isNotifying`. `Central` uses it to reject a concurrent `read` on the same
    /// characteristic with ``BLESwiftError/readConflictsWithNotification``.
    func isNotifying(_ characteristic: CharacteristicIdentifier) -> Bool

    /// The operations that `characteristic` supports. Mirrors
    /// `CBCharacteristic.properties`. Returns `[]` if `characteristic` is not yet discovered.
    func properties(of characteristic: CharacteristicIdentifier) -> CharacteristicProperties

    /// Every service discovered on this peripheral. The list is empty until a
    /// `discoverServices(_:)` completion has arrived. Maps `CBPeripheral.services`. The order is
    /// unspecified.
    var discoveredServices: [ServiceIdentifier] { get }

    /// Every characteristic discovered under `service`. Maps
    /// `CBService.characteristics`. The order is unspecified.
    func discoveredCharacteristics(for service: ServiceIdentifier) -> [CharacteristicIdentifier]

    /// Every descriptor discovered under `characteristic`. Maps
    /// `CBCharacteristic.descriptors`. The order is unspecified.
    func discoveredDescriptors(for characteristic: CharacteristicIdentifier) -> [DescriptorIdentifier]

    /// Opens an L2CAP channel to `psm`. The completion arrives asynchronously as
    /// ``PeripheralEvent/didOpenL2CAPChannel(channel:error:)``. One event arrives for each call, in
    /// call order. Mirrors `CBPeripheral.openL2CAPChannel(_:)`. It takes BLESwift's ``L2CAPPSM``
    /// and not CoreBluetooth's `CBL2CAPPSM`.
    func openL2CAPChannel(_ psm: L2CAPPSM)
}
