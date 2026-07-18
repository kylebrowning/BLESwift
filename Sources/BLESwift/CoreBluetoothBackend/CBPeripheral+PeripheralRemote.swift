//
//  CBPeripheral+PeripheralRemote.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth
import Foundation
import ObjectiveC

/// The stable identity token for the associated `PeripheralDelegateProxy` retained by
/// `CBPeripheral.eventHandler` below. Its address, not its value, is what matters to
/// `objc_(get|set)AssociatedObject` — the value is never read or written.
private nonisolated(unsafe) var peripheralProxyKey: UInt8 = 0

extension CBPeripheral {
    /// Implements `eventHandler` with an associated-object-retained `PeripheralDelegateProxy`
    /// assigned to `.delegate` (which is `weak` — the association is what keeps the proxy
    /// alive). Setting a non-`nil` handler creates the proxy on first use and reuses it on
    /// subsequent sets (updating its `handler`); setting `nil` clears both the proxy's
    /// handler and `.delegate`, and drops the association. `Central` sets this uniformly
    /// on every session-creating path (see `PeripheralRemote`'s doc comment) — unlike
    /// `CentralManaging`'s `eventHandler`, there is no construction-order asymmetry here:
    /// every `CBPeripheral` this property is set on already exists (handed back by
    /// CoreBluetooth), so this is always the sole wiring mechanism.
    public var eventHandler: ((PeripheralEvent) -> Void)? {
        get {
            (objc_getAssociatedObject(self, &peripheralProxyKey) as? PeripheralDelegateProxy)?.handler
        }
        set {
            // Bridges the protocol's plain (non-`@Sendable`) closure type into
            // `PeripheralDelegateProxy.handler`'s `@Sendable` storage — see
            // `CBCentralManager.eventHandler`'s setter for the full justification of this
            // `nonisolated(unsafe)` capture (identical reasoning: `Central` is the only
            // caller, and every closure it passes here only captures `[weak self]` of the
            // `Central` actor plus a captured `PeripheralIdentifier` value, both
            // genuinely `Sendable`).
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

    /// Finds an already-discovered descriptor by identifier, or `nil` if its owning service,
    /// characteristic, or the descriptor itself has not been discovered.
    fileprivate func bleSwiftDescriptor(_ identifier: DescriptorIdentifier) -> CBDescriptor? {
        bleSwiftCharacteristic(identifier.characteristic)?.descriptors?.first {
            DescriptorIdentifier(cbuuid: $0.uuid, characteristic: identifier.characteristic) == identifier
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
/// `CBService`/`CBCharacteristic` via `bleSwiftService(_:)`/`bleSwiftCharacteristic(_:)` and
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
    public var connectionState: PeripheralConnectionState {
        PeripheralConnectionState(state)
    }

    /// Discovers the given services (or all services, if `nil`).
    public func discoverServices(_ services: [ServiceIdentifier]?) {
        discoverServices(services?.map(\.cbuuid))
    }

    /// Discovers the given characteristics (or all characteristics, if `nil`) of
    /// `service`. A no-op if `service` has not yet been discovered.
    public func discoverCharacteristics(_ characteristics: [CharacteristicIdentifier]?, for service: ServiceIdentifier) {
        guard let cbService = bleSwiftService(service) else { return }
        discoverCharacteristics(characteristics?.map(\.cbuuid), for: cbService)
    }

    /// Requests the current value of `characteristic`. A no-op if it has not yet been
    /// discovered.
    public func readValue(for characteristic: CharacteristicIdentifier) {
        guard let cbCharacteristic = bleSwiftCharacteristic(characteristic) else { return }
        readValue(for: cbCharacteristic)
    }

    /// Writes `data` to `characteristic`. A no-op if it has not yet been discovered.
    public func writeValue(_ data: Data, for characteristic: CharacteristicIdentifier, type: WriteType) {
        guard let cbCharacteristic = bleSwiftCharacteristic(characteristic) else { return }
        writeValue(data, for: cbCharacteristic, type: type.cbWriteType)
    }

    /// Enables or disables notifications for `characteristic`. A no-op if it has not yet
    /// been discovered.
    public func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicIdentifier) {
        guard let cbCharacteristic = bleSwiftCharacteristic(characteristic) else { return }
        setNotifyValue(enabled, for: cbCharacteristic)
    }

    /// Discovers all descriptors of `characteristic`. A no-op if it has not yet been
    /// discovered.
    public func discoverDescriptors(for characteristic: CharacteristicIdentifier) {
        guard let cbCharacteristic = bleSwiftCharacteristic(characteristic) else { return }
        discoverDescriptors(for: cbCharacteristic)
    }

    /// Requests the current value of `descriptor`. A no-op if it has not yet been
    /// discovered.
    public func readValue(for descriptor: DescriptorIdentifier) {
        guard let cbDescriptor = bleSwiftDescriptor(descriptor) else { return }
        readValue(for: cbDescriptor)
    }

    /// Writes `data` to `descriptor`. A no-op if it has not yet been discovered.
    public func writeValue(_ data: Data, for descriptor: DescriptorIdentifier) {
        guard let cbDescriptor = bleSwiftDescriptor(descriptor) else { return }
        writeValue(data, for: cbDescriptor)
    }

    /// The maximum payload length in bytes for a single write of `type`.
    public func maximumWriteValueLength(for type: WriteType) -> Int {
        maximumWriteValueLength(for: type.cbWriteType)
    }

    /// Whether `service` has already been discovered on this peripheral.
    public func isDiscovered(_ service: ServiceIdentifier) -> Bool {
        bleSwiftService(service) != nil
    }

    /// Whether `characteristic` has already been discovered on this peripheral.
    public func isDiscovered(_ characteristic: CharacteristicIdentifier) -> Bool {
        bleSwiftCharacteristic(characteristic) != nil
    }

    /// Whether `descriptor` has already been discovered on this peripheral.
    public func isDiscovered(_ descriptor: DescriptorIdentifier) -> Bool {
        bleSwiftDescriptor(descriptor) != nil
    }

    /// Whether `characteristic` currently has notifications enabled. `false` if it has not
    /// yet been discovered.
    public func isNotifying(_ characteristic: CharacteristicIdentifier) -> Bool {
        bleSwiftCharacteristic(characteristic)?.isNotifying ?? false
    }

    /// The set of operations `characteristic` advertises support for, mapping the native
    /// `CBCharacteristic.properties` at this sanctioned CoreBluetooth seam. `[]` (empty) if
    /// it has not yet been discovered.
    public func properties(of characteristic: CharacteristicIdentifier) -> CharacteristicProperties {
        guard let cbCharacteristic = bleSwiftCharacteristic(characteristic) else { return [] }
        return CharacteristicProperties(cbCharacteristic.properties)
    }

    /// Every discovered service, mapping `CBPeripheral.services`' `CBUUID`s back to
    /// ``ServiceIdentifier`` at this sanctioned seam (the `CBService`s never escape). `[]`
    /// before any service discovery has landed.
    public var discoveredServices: [ServiceIdentifier] {
        services?.map { ServiceIdentifier(cbuuid: $0.uuid) } ?? []
    }

    /// Every discovered characteristic under `service`, mapping
    /// `CBService.characteristics`' `CBUUID`s back to ``CharacteristicIdentifier``. `[]` if
    /// `service` has not been discovered, or has had no characteristic discovery land yet.
    public func discoveredCharacteristics(for service: ServiceIdentifier) -> [CharacteristicIdentifier] {
        bleSwiftService(service)?.characteristics?.map {
            CharacteristicIdentifier(cbuuid: $0.uuid, service: service)
        } ?? []
    }

    /// Every discovered descriptor under `characteristic`, mapping
    /// `CBCharacteristic.descriptors`' `CBUUID`s back to ``DescriptorIdentifier``. `[]` if
    /// `characteristic` has not been discovered, or has had no descriptor discovery land yet.
    public func discoveredDescriptors(for characteristic: CharacteristicIdentifier) -> [DescriptorIdentifier] {
        bleSwiftCharacteristic(characteristic)?.descriptors?.map {
            DescriptorIdentifier(cbuuid: $0.uuid, characteristic: characteristic)
        } ?? []
    }

    /// Opens an L2CAP channel to `psm`, bridging BLESwift's ``L2CAPPSM`` to CoreBluetooth's
    /// `CBL2CAPPSM`. A distinct overload of `CBPeripheral`'s own `openL2CAPChannel(_:)`
    /// (which takes a `CBL2CAPPSM`), disambiguated by the parameter type; it forwards to
    /// that native method. Completion arrives via `peripheral(_:didOpen:error:)`.
    public func openL2CAPChannel(_ psm: L2CAPPSM) {
        openL2CAPChannel(CBL2CAPPSM(psm.rawValue))
    }
}
