//
//  CBPeripheral+PeripheralRemote.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth
import Foundation
import ObjectiveC

/// The identity token for the associated `PeripheralDelegateProxy`, which the
/// `CBPeripheral.eventHandler` below retains. `objc_(get|set)AssociatedObject` uses the
/// token's address. The code never reads or writes its value.
private nonisolated(unsafe) var peripheralProxyKey: UInt8 = 0

extension CBPeripheral {
    /// Implements `eventHandler` with a `PeripheralDelegateProxy`. An associated object retains
    /// the proxy, because `.delegate` is `weak`. A non-`nil` handler creates the proxy on first
    /// use and reuses it later. Setting `nil` clears the proxy's handler and `.delegate`. Unlike
    /// `CentralManaging.eventHandler`, there is no construction-order problem, because the
    /// `CBPeripheral` already exists.
    public var eventHandler: ((PeripheralEvent) -> Void)? {
        get {
            (objc_getAssociatedObject(self, &peripheralProxyKey) as? PeripheralDelegateProxy)?.handler
        }
        set {
            // Bridges the protocol's plain closure to the `@Sendable` storage of
            // `PeripheralDelegateProxy`. See the `CBCentralManager.eventHandler` setter for why
            // this `nonisolated(unsafe)` capture is safe.
            let sendableValue: (@Sendable (PeripheralEvent) -> Void)?
            if let newValue {
                nonisolated(unsafe) let captured = newValue
                sendableValue = { captured($0) }
            } else {
                sendableValue = nil
            }

            if let existing = objc_getAssociatedObject(self, &peripheralProxyKey) as? PeripheralDelegateProxy {
                existing.handler = sendableValue
                if newValue == nil {
                    delegate = nil
                    objc_setAssociatedObject(self, &peripheralProxyKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                }
            } else if let sendableValue {
                let proxy = PeripheralDelegateProxy()
                proxy.handler = sendableValue
                objc_setAssociatedObject(self, &peripheralProxyKey, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                delegate = proxy
            }
        }
    }
}

extension CBPeripheral {

    /// Finds an already discovered service by identifier, or `nil`.
    fileprivate func bleSwiftService(_ identifier: ServiceIdentifier) -> CBService? {
        services?.first { ServiceIdentifier(cbuuid: $0.uuid) == identifier }
    }

    /// Finds an already discovered characteristic by identifier. Returns `nil` if it or its
    /// service is not discovered.
    fileprivate func bleSwiftCharacteristic(_ identifier: CharacteristicIdentifier) -> CBCharacteristic? {
        bleSwiftService(identifier.service)?.characteristics?.first {
            CharacteristicIdentifier(cbuuid: $0.uuid, service: identifier.service) == identifier
        }
    }

    /// Finds an already discovered descriptor by identifier. Returns `nil` if it, its
    /// characteristic, or its service is not discovered.
    fileprivate func bleSwiftDescriptor(_ identifier: DescriptorIdentifier) -> CBDescriptor? {
        bleSwiftCharacteristic(identifier.characteristic)?.descriptors?.first {
            DescriptorIdentifier(cbuuid: $0.uuid, characteristic: identifier.characteristic) == identifier
        }
    }
}

/// The identifier-based members resolve the identifier to a CoreBluetooth object with
/// `bleSwiftService(_:)`, `bleSwiftCharacteristic(_:)`, or `bleSwiftDescriptor(_:)` and call
/// the corresponding CoreBluetooth method. If the object is not discovered yet, they do
/// nothing and report no error.
///
/// No `@retroactive` is necessary. `PeripheralRemote` and this conformance are in different
/// modules of the same SPM package, and the SE-0364 check is package-scoped.
extension CBPeripheral: PeripheralRemote {

    #if !os(iOS)
    /// The `PeripheralRemote.ancsAuthorized` witness off iOS, where `CBPeripheral` has no
    /// `ancsAuthorized`. ANCS is iOS-only, so the value is always `false`. On iOS, the native
    /// property is the witness.
    public var ancsAuthorized: Bool { false }
    #endif

    /// Maps `CBPeripheral.state` to ``PeripheralConnectionState``.
    public var connectionState: PeripheralConnectionState {
        PeripheralConnectionState(state)
    }

    /// Discovers the given services, or all services if `nil`.
    public func discoverServices(_ services: [ServiceIdentifier]?) {
        discoverServices(services?.map(\.cbuuid))
    }

    /// Discovers the given characteristics of `service`, or all characteristics if `nil`.
    /// It does nothing if `service` is not discovered yet.
    public func discoverCharacteristics(_ characteristics: [CharacteristicIdentifier]?, for service: ServiceIdentifier) {
        guard let cbService = bleSwiftService(service) else { return }
        discoverCharacteristics(characteristics?.map(\.cbuuid), for: cbService)
    }

    /// Requests the current value of `characteristic`. It does nothing if the characteristic
    /// is not discovered yet.
    public func readValue(for characteristic: CharacteristicIdentifier) {
        guard let cbCharacteristic = bleSwiftCharacteristic(characteristic) else { return }
        readValue(for: cbCharacteristic)
    }

    /// Writes `data` to `characteristic`. It does nothing if the characteristic is not
    /// discovered yet.
    public func writeValue(_ data: Data, for characteristic: CharacteristicIdentifier, type: WriteType) {
        guard let cbCharacteristic = bleSwiftCharacteristic(characteristic) else { return }
        writeValue(data, for: cbCharacteristic, type: type.cbWriteType)
    }

    /// Enables or disables notifications for `characteristic`. It does nothing if the
    /// characteristic is not discovered yet.
    public func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicIdentifier) {
        guard let cbCharacteristic = bleSwiftCharacteristic(characteristic) else { return }
        setNotifyValue(enabled, for: cbCharacteristic)
    }

    /// Discovers all descriptors of `characteristic`. It does nothing if the characteristic
    /// is not discovered yet.
    public func discoverDescriptors(for characteristic: CharacteristicIdentifier) {
        guard let cbCharacteristic = bleSwiftCharacteristic(characteristic) else { return }
        discoverDescriptors(for: cbCharacteristic)
    }

    /// Requests the current value of `descriptor`. It does nothing if the descriptor is not
    /// discovered yet.
    public func readValue(for descriptor: DescriptorIdentifier) {
        guard let cbDescriptor = bleSwiftDescriptor(descriptor) else { return }
        readValue(for: cbDescriptor)
    }

    /// Writes `data` to `descriptor`. It does nothing if the descriptor is not discovered yet.
    public func writeValue(_ data: Data, for descriptor: DescriptorIdentifier) {
        guard let cbDescriptor = bleSwiftDescriptor(descriptor) else { return }
        writeValue(data, for: cbDescriptor)
    }

    /// The maximum payload length in bytes for a single write of `type`.
    public func maximumWriteValueLength(for type: WriteType) -> Int {
        maximumWriteValueLength(for: type.cbWriteType)
    }

    /// Whether `service` is already discovered on this peripheral.
    public func isDiscovered(_ service: ServiceIdentifier) -> Bool {
        bleSwiftService(service) != nil
    }

    /// Whether `characteristic` is already discovered on this peripheral.
    public func isDiscovered(_ characteristic: CharacteristicIdentifier) -> Bool {
        bleSwiftCharacteristic(characteristic) != nil
    }

    /// Whether `descriptor` is already discovered on this peripheral.
    public func isDiscovered(_ descriptor: DescriptorIdentifier) -> Bool {
        bleSwiftDescriptor(descriptor) != nil
    }

    /// Whether `characteristic` has notifications enabled. It is `false` if the characteristic
    /// is not discovered yet.
    public func isNotifying(_ characteristic: CharacteristicIdentifier) -> Bool {
        bleSwiftCharacteristic(characteristic)?.isNotifying ?? false
    }

    /// The operations that `characteristic` advertises, mapped from
    /// `CBCharacteristic.properties`. It is empty if the characteristic is not discovered yet.
    public func properties(of characteristic: CharacteristicIdentifier) -> CharacteristicProperties {
        guard let cbCharacteristic = bleSwiftCharacteristic(characteristic) else { return [] }
        return CharacteristicProperties(cbCharacteristic.properties)
    }

    /// Every discovered service, mapped from `CBPeripheral.services`. The `CBService` values
    /// never leave this seam. It is empty before any service discovery result arrives.
    public var discoveredServices: [ServiceIdentifier] {
        services?.map { ServiceIdentifier(cbuuid: $0.uuid) } ?? []
    }

    /// Every discovered characteristic of `service`, mapped from `CBService.characteristics`. It
    /// is empty if `service` is not discovered, or no characteristic result has arrived yet.
    public func discoveredCharacteristics(for service: ServiceIdentifier) -> [CharacteristicIdentifier] {
        bleSwiftService(service)?.characteristics?.map {
            CharacteristicIdentifier(cbuuid: $0.uuid, service: service)
        } ?? []
    }

    /// Every discovered descriptor of `characteristic`, mapped from
    /// `CBCharacteristic.descriptors`. It is empty if `characteristic` is not discovered, or no
    /// descriptor result has arrived yet.
    public func discoveredDescriptors(for characteristic: CharacteristicIdentifier) -> [DescriptorIdentifier] {
        bleSwiftCharacteristic(characteristic)?.descriptors?.map {
            DescriptorIdentifier(cbuuid: $0.uuid, characteristic: characteristic)
        } ?? []
    }

    /// Opens an L2CAP channel to `psm`. It converts the ``L2CAPPSM`` to a `CBL2CAPPSM` and
    /// forwards to the native `openL2CAPChannel(_:)`, a separate overload that takes a
    /// `CBL2CAPPSM`. The completion arrives through `peripheral(_:didOpen:error:)`.
    public func openL2CAPChannel(_ psm: L2CAPPSM) {
        openL2CAPChannel(CBL2CAPPSM(psm.rawValue))
    }
}
