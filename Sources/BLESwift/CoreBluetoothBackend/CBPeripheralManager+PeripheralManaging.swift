//
//  CBPeripheralManager+PeripheralManaging.swift
//  BLESwift
//

// iOS and macOS only, like `PeripheralHost`. visionOS has no construction of
// `CBMutableService` and `CBMutableCharacteristic`, which `add(_:)` below needs. watchOS
// and tvOS cannot construct `CBPeripheralManager`.
#if os(iOS) || os(macOS)

import BLESwiftCore
import CoreBluetooth
import Foundation
import ObjectiveC

/// The identity token for the associated ``PeripheralManagerDelegateProxy``, which the
/// `CBPeripheralManager` below retains. `objc_(get|set)AssociatedObject` uses the token's
/// address, not its value.
private nonisolated(unsafe) var peripheralManagerProxyKey: UInt8 = 0

/// `CBPeripheralManager` conforms to ``PeripheralManaging``. This seam lets `PeripheralHost`
/// drive a real manager as it drives a `FakePeripheralManager`. The conformance compiles the
/// value-type GATT database to `CBMutableService` and `CBMutableCharacteristic`. `respond` and
/// `updateValue` use the shared ``PeripheralManagerDelegateProxy`` to recover the
/// `CBATTRequest` and `CBCentral` objects that the value-type API hides.
///
/// No `@retroactive` is necessary. The conformance is package-scoped, as for the central.
extension CBPeripheralManager: PeripheralManaging {

    /// The associated ``PeripheralManagerDelegateProxy``, if any. The ``eventHandler`` setter
    /// or `PeripheralHost.init(configuration:)` installs it.
    var bleSwiftPeripheralProxy: PeripheralManagerDelegateProxy? {
        objc_getAssociatedObject(self, &peripheralManagerProxyKey) as? PeripheralManagerDelegateProxy
    }

    /// Registers `proxy` as this manager's associated proxy, so `respond` and `updateValue`
    /// can reach it. `PeripheralHost.init(configuration:)` calls this method, because it
    /// creates its own proxy and passes it directly to
    /// `CBPeripheralManager(delegate:queue:options:)`. The ``eventHandler`` setter would create
    /// a second proxy.
    func bleSwiftRegisterProxy(_ proxy: PeripheralManagerDelegateProxy) {
        objc_setAssociatedObject(self, &peripheralManagerProxyKey, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Implements `eventHandler` with a ``PeripheralManagerDelegateProxy``. An associated
    /// object retains the proxy, because `.delegate` is `weak`. It mirrors
    /// `CBCentralManager.eventHandler`, including the `nonisolated(unsafe)` bridge to the
    /// proxy's `@Sendable` storage. See that property for the reason.
    ///
    /// - Important: `PeripheralHost.init(configuration:)` does **not** use this property. It
    ///   passes its own proxy to `CBPeripheralManager(delegate:queue:options:)` and then calls
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

    /// Maps `CBManager.state` to ``CentralState``.
    public var radioState: CentralState {
        CentralState(state)
    }

    /// Maps `CBManager.authorization` to ``BluetoothAuthorization``.
    public static var bluetoothAuthorization: BluetoothAuthorization {
        BluetoothAuthorization(authorization)
    }

    /// Builds the advertisement `[String: Any]` with only the two honored keys (local name and
    /// service UUIDs) and calls `startAdvertising(_:)`.
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

    // `stopAdvertising()` already exists on `CBPeripheralManager` with an identical signature,
    // so it satisfies the protocol. `stopScan()` does the same for the central conformance.

    /// Clears the proxy's characteristic-handle registry, so `updateValue` cannot resolve a
    /// stale handle, and calls `removeAllServices()`. The name differs from the native method
    /// to avoid a clash with an identical signature. See ``PeripheralManaging``.
    public func removeAllHostedServices() {
        bleSwiftPeripheralProxy?.removeAllCharacteristicHandles()
        removeAllServices()
    }

    /// Compiles `service` and its characteristics into a `CBMutableService` and
    /// `CBMutableCharacteristic` tree, records each characteristic handle on the proxy for
    /// `updateValue`, and calls `add(_:)`.
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

    /// Recovers the `CBATTRequest` objects that the proxy stored under `token`, sets `value`
    /// on the first request, and responds with the mapped `CBATTError.Code` (`.success` when
    /// `error == nil`). It does nothing if `token` is unknown.
    public func respond(to token: RequestToken, value: Data?, error: ATTError?) {
        guard let proxy = bleSwiftPeripheralProxy,
              let requests = proxy.takeRequests(for: token),
              let primary = requests.first else { return }
        if let value {
            primary.value = value
        }
        respond(to: primary, withResult: error?.cbATTErrorCode ?? .success)
    }

    /// Resolves the live `CBMutableCharacteristic` handle and, for a targeted push, the
    /// `CBCentral` objects. It calls `updateValue(_:for:onSubscribedCentrals:)` and returns its
    /// back-pressure `Bool`. It returns `false` if the characteristic has no live handle,
    /// because it was never added or was removed.
    public func updateValue(_ value: Data, for characteristic: CharacteristicIdentifier, onSubscribed centrals: [Subscriber]?) -> Bool {
        guard let proxy = bleSwiftPeripheralProxy,
              let cbCharacteristic = proxy.characteristicHandle(for: characteristic) else { return false }
        let cbCentrals = centrals.map { proxy.resolveCentrals($0) }
        return updateValue(value, for: cbCharacteristic, onSubscribedCentrals: cbCentrals)
    }
}

#endif
