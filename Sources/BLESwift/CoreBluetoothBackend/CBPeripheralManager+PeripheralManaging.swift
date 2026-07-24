//
//  CBPeripheralManager+PeripheralManaging.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth
import Foundation
import ObjectiveC

/// The stable identity token for the associated ``PeripheralManagerDelegateProxy`` retained
/// by `CBPeripheralManager` below. Its address, not its value, is what matters to
/// `objc_(get|set)AssociatedObject`.
private nonisolated(unsafe) var peripheralManagerProxyKey: UInt8 = 0

/// `CBPeripheralManager` conforms to ``PeripheralManaging`` — the seam that lets
/// `PeripheralHost` drive a real manager the same way it drives a `FakePeripheralManager`.
/// The value-type GATT database is compiled to `CBMutableService`/`CBMutableCharacteristic`
/// here, and `respond`/`updateValue` reach the shared ``PeripheralManagerDelegateProxy`` to
/// recover the `CBATTRequest`/`CBCentral` objects the value-type API hides.
///
/// No `@retroactive` needed — package-scoped, same as the central conformance.
extension CBPeripheralManager: PeripheralManaging {

    /// The associated ``PeripheralManagerDelegateProxy``, if one has been installed (via the
    /// ``eventHandler`` setter, or registered by `PeripheralHost.init(configuration:)`).
    var bleSwiftPeripheralProxy: PeripheralManagerDelegateProxy? {
        objc_getAssociatedObject(self, &peripheralManagerProxyKey) as? PeripheralManagerDelegateProxy
    }

    /// Registers `proxy` as this manager's associated proxy, so `respond`/`updateValue` can
    /// reach it. Called by `PeripheralHost.init(configuration:)`, which constructs its own
    /// proxy and passes it directly to `CBPeripheralManager(delegate:queue:options:)` — the
    /// ``eventHandler`` setter's fresh-proxy path is wrong for that case.
    func bleSwiftRegisterProxy(_ proxy: PeripheralManagerDelegateProxy) {
        objc_setAssociatedObject(self, &peripheralManagerProxyKey, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Implements `eventHandler` with an associated-object-retained
    /// ``PeripheralManagerDelegateProxy`` assigned to `.delegate` (which is `weak` — the
    /// association keeps the proxy alive). Mirrors `CBCentralManager.eventHandler` exactly,
    /// including the `nonisolated(unsafe)` bridge from the protocol's plain closure into the
    /// proxy's `@Sendable` storage. See that property for the full rationale.
    ///
    /// - Important: `PeripheralHost.init(configuration:)` does **not** go through this
    ///   property — it creates its proxy and passes it to
    ///   `CBPeripheralManager(delegate:queue:options:)` directly, then calls
    ///   ``bleSwiftRegisterProxy(_:)``.
    public var eventHandler: ((PeripheralHostEvent) -> Void)? {
        get {
            (objc_getAssociatedObject(self, &peripheralManagerProxyKey) as? PeripheralManagerDelegateProxy)?.handler
        }
        set {
            let sendableValue: (@Sendable (PeripheralHostEvent) -> Void)?
            if let newValue {
                nonisolated(unsafe) let captured = newValue
                sendableValue = { captured($0) }
            } else {
                sendableValue = nil
            }

            if let existing = objc_getAssociatedObject(self, &peripheralManagerProxyKey) as? PeripheralManagerDelegateProxy {
                existing.handler = sendableValue
                if newValue == nil {
                    delegate = nil
                    objc_setAssociatedObject(self, &peripheralManagerProxyKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                }
            } else if let sendableValue {
                let proxy = PeripheralManagerDelegateProxy()
                proxy.handler = sendableValue
                objc_setAssociatedObject(self, &peripheralManagerProxyKey, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                delegate = proxy
            }
        }
    }

    /// Maps the native `state` (`CBManagerState`) to ``CentralState``.
    public var radioState: CentralState {
        CentralState(state)
    }

    /// Maps the native `CBManager.authorization` class property to ``BluetoothAuthorization``.
    public static var bluetoothAuthorization: BluetoothAuthorization {
        BluetoothAuthorization(authorization)
    }

    /// Builds the advertisement `[String: Any]` CoreBluetooth expects (only the two honored
    /// keys) and delegates to the real `startAdvertising(_:)`.
    public func startAdvertising(_ advertisement: PeripheralAdvertisement) {
        var data: [String: Any] = [:]
        if let localName = advertisement.localName {
            data[CBAdvertisementDataLocalNameKey] = localName
        }
        if !advertisement.serviceUUIDs.isEmpty {
            data[CBAdvertisementDataServiceUUIDsKey] = advertisement.serviceUUIDs.map(\.cbuuid)
        }
        startAdvertising(data)
    }

    // `stopAdvertising()` already exists on `CBPeripheralManager` with an identical
    // signature, so it satisfies the protocol with no extra code (like `stopScan()` on the
    // central conformance).

    /// Clears the proxy's characteristic-handle registry (so a stale handle can't be
    /// resolved by `updateValue` after removal), then delegates to the native
    /// `removeAllServices()`. Named distinctly from that method to avoid an
    /// identical-signature redeclaration clash — see ``PeripheralManaging``.
    public func removeAllHostedServices() {
        bleSwiftPeripheralProxy?.removeAllCharacteristicHandles()
        removeAllServices()
    }

    /// Compiles `service` (and its characteristics) into a `CBMutableService`/
    /// `CBMutableCharacteristic` tree, records each characteristic handle on the proxy for
    /// later `updateValue` resolution, and delegates to the real `add(_:)`.
    public func add(_ service: GATTService) {
        let cbService = CBMutableService(type: service.identifier.cbuuid, primary: service.isPrimary)
        let proxy = bleSwiftPeripheralProxy
        var cbCharacteristics: [CBMutableCharacteristic] = []
        for characteristic in service.characteristics {
            let cbCharacteristic = CBMutableCharacteristic(
                type: characteristic.identifier.cbuuid,
                properties: characteristic.properties.cbProperties,
                value: characteristic.value,
                permissions: characteristic.permissions.cbPermissions
            )
            proxy?.registerCharacteristic(cbCharacteristic, for: characteristic.identifier)
            cbCharacteristics.append(cbCharacteristic)
        }
        cbService.characteristics = cbCharacteristics
        add(cbService)
    }

    /// Recovers the `CBATTRequest`(s) the proxy stored under `token`, applies `value` (for a
    /// read) to the first request, and answers with the mapped `CBATTError.Code`
    /// (`.success` when `error == nil`). A no-op if `token` is unknown.
    public func respond(to token: RequestToken, value: Data?, error: ATTError?) {
        guard let proxy = bleSwiftPeripheralProxy,
              let requests = proxy.takeRequests(for: token),
              let primary = requests.first else { return }
        if let value {
            primary.value = value
        }
        respond(to: primary, withResult: error?.cbATTErrorCode ?? .success)
    }

    /// Resolves the live `CBMutableCharacteristic` handle and (for a targeted push) the
    /// `CBCentral`s, then delegates to the real `updateValue(_:for:onSubscribedCentrals:)`,
    /// returning its back-pressure `Bool`. Returns `false` if the characteristic has no live
    /// handle (never added, or removed).
    public func updateValue(_ value: Data, for characteristic: CharacteristicIdentifier, onSubscribed centrals: [Subscriber]?) -> Bool {
        guard let proxy = bleSwiftPeripheralProxy,
              let cbCharacteristic = proxy.characteristicHandle(for: characteristic) else { return false }
        let cbCentrals = centrals.map { proxy.resolveCentrals($0) }
        return updateValue(value, for: cbCharacteristic, onSubscribedCentrals: cbCentrals)
    }
}
