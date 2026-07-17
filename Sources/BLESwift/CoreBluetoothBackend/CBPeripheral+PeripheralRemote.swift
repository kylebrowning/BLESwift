//
//  CBPeripheral+PeripheralRemote.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth
import Foundation

extension CBPeripheral {
    /// Assigns `target` as this peripheral's `CBPeripheralDelegate` — the wiring that
    /// routes all of its GATT callbacks (to `CentralDelegateProxy`, in production). A
    /// `nil` (or non-`CBPeripheralDelegate`) target clears the delegate.
    package func attachEventTarget(_ target: AnyObject?) {
        delegate = target as? CBPeripheralDelegate
    }
}

extension CBPeripheral {

    /// Finds an already-discovered service by identifier, or `nil` if it has not been
    /// discovered.
    fileprivate func bleSwiftService(_ identifier: ServiceIdentifier) -> CBService? {
        services?.first { ServiceIdentifier(cbuuid: $0.uuid) == identifier }
    }

    /// Finds an already-discovered characteristic by identifier, or `nil` if either its
    /// owning service or the characteristic itself has not been discovered.
    fileprivate func bleSwiftCharacteristic(_ identifier: CharacteristicIdentifier) -> CBCharacteristic? {
        bleSwiftService(identifier.service)?.characteristics?.first {
            CharacteristicIdentifier(cbuuid: $0.uuid, service: identifier.service) == identifier
        }
    }
}

/// `identifier`, `name`, `readRSSI()`, and `canSendWriteWithoutResponse` are already
/// implemented by `CBPeripheral` with identical signatures and require no additional code
/// here. `connectionState` maps the native `state` (`CBPeripheralState`) — it can't share
/// that name (see ``PeripheralRemote``'s note); `writeValue(_:for:type:)` and
/// `maximumWriteValueLength(for:)` take ``WriteType`` rather than
/// `CBCharacteristicWriteType`, so they need bridging overloads even though CoreBluetooth
/// already has same-named methods. The remaining members are identifier-based (see
/// ``PeripheralRemote``) and are implemented below by resolving the identifier to a
/// `CBService`/`CBCharacteristic` via ``bleSwiftService(_:)``/``bleSwiftCharacteristic(_:)`` and
/// delegating to the corresponding CoreBluetooth method — silently no-op-ing when the
/// service or characteristic has not yet been discovered, matching the `nil`-returning
/// behavior of `bleSwiftService(_:)`/`bleSwiftCharacteristic(_:)`.
///
/// No `@retroactive` needed: `PeripheralRemote` (in `BLESwiftCore`) and this conformance
/// (in `BLESwift`) are different modules but the same SPM *package* — SE-0364's
/// retroactive-conformance check (and its warning under `.treatAllWarnings(as: .error)`)
/// is package-scoped, not module-scoped, so this doesn't trigger it.
extension CBPeripheral: PeripheralRemote {

    /// Maps the native `state` (`CBPeripheralState`) to ``PeripheralConnectionState``.
    package var connectionState: PeripheralConnectionState {
        PeripheralConnectionState(state)
    }

    /// Discovers the given services (or all services, if `nil`).
    package func discoverServices(_ services: [ServiceIdentifier]?) {
        discoverServices(services?.map(\.cbuuid))
    }

    /// Discovers the given characteristics (or all characteristics, if `nil`) of
    /// `service`. A no-op if `service` has not yet been discovered.
    package func discoverCharacteristics(_ characteristics: [CharacteristicIdentifier]?, for service: ServiceIdentifier) {
        guard let cbService = bleSwiftService(service) else { return }
        discoverCharacteristics(characteristics?.map(\.cbuuid), for: cbService)
    }

    /// Requests the current value of `characteristic`. A no-op if it has not yet been
    /// discovered.
    package func readValue(for characteristic: CharacteristicIdentifier) {
        guard let cbCharacteristic = bleSwiftCharacteristic(characteristic) else { return }
        readValue(for: cbCharacteristic)
    }

    /// Writes `data` to `characteristic`. A no-op if it has not yet been discovered.
    package func writeValue(_ data: Data, for characteristic: CharacteristicIdentifier, type: WriteType) {
        guard let cbCharacteristic = bleSwiftCharacteristic(characteristic) else { return }
        writeValue(data, for: cbCharacteristic, type: type.cbWriteType)
    }

    /// Enables or disables notifications for `characteristic`. A no-op if it has not yet
    /// been discovered.
    package func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicIdentifier) {
        guard let cbCharacteristic = bleSwiftCharacteristic(characteristic) else { return }
        setNotifyValue(enabled, for: cbCharacteristic)
    }

    /// The maximum payload length in bytes for a single write of `type`.
    package func maximumWriteValueLength(for type: WriteType) -> Int {
        maximumWriteValueLength(for: type.cbWriteType)
    }

    /// Whether `service` has already been discovered on this peripheral.
    package func isDiscovered(_ service: ServiceIdentifier) -> Bool {
        bleSwiftService(service) != nil
    }

    /// Whether `characteristic` has already been discovered on this peripheral.
    package func isDiscovered(_ characteristic: CharacteristicIdentifier) -> Bool {
        bleSwiftCharacteristic(characteristic) != nil
    }

    /// Whether `characteristic` currently has notifications enabled. `false` if it has not
    /// yet been discovered.
    package func isNotifying(_ characteristic: CharacteristicIdentifier) -> Bool {
        bleSwiftCharacteristic(characteristic)?.isNotifying ?? false
    }
}
