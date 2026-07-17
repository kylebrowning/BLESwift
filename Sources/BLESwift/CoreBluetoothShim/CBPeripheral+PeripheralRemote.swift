//
//  CBPeripheral+PeripheralRemote.swift
//  BLESwift
//

import CoreBluetooth

extension CBPeripheral {
    /// Assigns `target` as this peripheral's `CBPeripheralDelegate` — the wiring that
    /// routes all of its GATT callbacks (to `CentralDelegateProxy`, in production). A
    /// `nil` (or non-`CBPeripheralDelegate`) target clears the delegate.
    func attachEventTarget(_ target: AnyObject?) {
        delegate = target as? CBPeripheralDelegate
    }
}
import Foundation

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

/// `identifier`, `name`, `state`, `readRSSI()`, and `maximumWriteValueLength(for:)` are
/// already implemented by `CBPeripheral` with identical signatures and require no
/// additional code here. The remaining members are identifier-based (see
/// ``PeripheralRemote``) and are implemented below by resolving the identifier to a
/// `CBService`/`CBCharacteristic` via ``bleSwiftService(_:)``/``bleSwiftCharacteristic(_:)`` and
/// delegating to the corresponding CoreBluetooth method — silently no-op-ing when the
/// service or characteristic has not yet been discovered, matching the `nil`-returning
/// behavior of `bleSwiftService(_:)`/`bleSwiftCharacteristic(_:)`.
extension CBPeripheral: PeripheralRemote {

    /// Discovers the given services (or all services, if `nil`).
    func discoverServices(_ services: [ServiceIdentifier]?) {
        discoverServices(services?.map(\.cbuuid))
    }

    /// Discovers the given characteristics (or all characteristics, if `nil`) of
    /// `service`. A no-op if `service` has not yet been discovered.
    func discoverCharacteristics(_ characteristics: [CharacteristicIdentifier]?, for service: ServiceIdentifier) {
        guard let cbService = bleSwiftService(service) else { return }
        discoverCharacteristics(characteristics?.map(\.cbuuid), for: cbService)
    }

    /// Requests the current value of `characteristic`. A no-op if it has not yet been
    /// discovered.
    func readValue(for characteristic: CharacteristicIdentifier) {
        guard let cbCharacteristic = bleSwiftCharacteristic(characteristic) else { return }
        readValue(for: cbCharacteristic)
    }

    /// Writes `data` to `characteristic`. A no-op if it has not yet been discovered.
    func writeValue(_ data: Data, for characteristic: CharacteristicIdentifier, type: CBCharacteristicWriteType) {
        guard let cbCharacteristic = bleSwiftCharacteristic(characteristic) else { return }
        writeValue(data, for: cbCharacteristic, type: type)
    }

    /// Enables or disables notifications for `characteristic`. A no-op if it has not yet
    /// been discovered.
    func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicIdentifier) {
        guard let cbCharacteristic = bleSwiftCharacteristic(characteristic) else { return }
        setNotifyValue(enabled, for: cbCharacteristic)
    }

    /// Whether `service` has already been discovered on this peripheral.
    func isDiscovered(_ service: ServiceIdentifier) -> Bool {
        bleSwiftService(service) != nil
    }

    /// Whether `characteristic` has already been discovered on this peripheral.
    func isDiscovered(_ characteristic: CharacteristicIdentifier) -> Bool {
        bleSwiftCharacteristic(characteristic) != nil
    }

    /// Whether `characteristic` currently has notifications enabled. `false` if it has not
    /// yet been discovered.
    func isNotifying(_ characteristic: CharacteristicIdentifier) -> Bool {
        bleSwiftCharacteristic(characteristic)?.isNotifying ?? false
    }
}
