//
//  CBCentralManager+CentralManaging.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth
import ObjectiveC

/// The stable identity token for the associated `CentralDelegateProxy` retained by
/// `CBCentralManager.eventHandler` below. Its address, not its value, is what matters to
/// `objc_(get|set)AssociatedObject` — the value is never read or written.
private nonisolated(unsafe) var centralManagerProxyKey: UInt8 = 0

/// Bridges `CentralManaging` to the real `CBCentralManager` API: mismatched `PeripheralRemote`
/// downcasts are a no-op, never a trap (mixing shim families is a programmer error, not a
/// runtime condition to crash on).
///
/// No `@retroactive` needed: `CentralManaging` and this conformance are different modules
/// but the same SPM package — SE-0364's retroactive-conformance check is package-scoped.
extension CBCentralManager: CentralManaging {

    /// Implements `eventHandler` with an associated-object-retained `CentralDelegateProxy`
    /// assigned to `.delegate` (which is `weak` — the association is what keeps the proxy
    /// alive). Setting a non-`nil` handler creates the proxy on first use and reuses it on
    /// subsequent sets; setting `nil` clears both the proxy's handler and `.delegate`.
    ///
    /// - Important: `Central.init(configuration:)` does **not** go through this property —
    ///   this setter always creates a *fresh* proxy, which would be a second, disconnected
    ///   instance if used at construction time. `init` passes its own proxy directly to
    ///   `CBCentralManager(delegate:queue:options:)` instead.
    public var eventHandler: ((CentralEvent) -> Void)? {
        get {
            (objc_getAssociatedObject(self, &centralManagerProxyKey) as? CentralDelegateProxy)?.handler
        }
        set {
            // Bridges the protocol's plain (non-`@Sendable`) closure type into
            // `CentralDelegateProxy.handler`'s `@Sendable` storage. Sound: `Central` is the
            // only caller, and every closure it passes here captures only `[weak self]` and
            // the (`Sendable`) event payload — the compiler just can't see that through the
            // protocol's fixed non-`@Sendable` signature, so `nonisolated(unsafe)` asserts
            // it explicitly.
            let sendableValue: (@Sendable (CentralEvent) -> Void)?
            if let newValue {
                nonisolated(unsafe) let captured = newValue
                sendableValue = { captured($0) }
            } else {
                sendableValue = nil
            }

            if let existing = objc_getAssociatedObject(self, &centralManagerProxyKey) as? CentralDelegateProxy {
                existing.handler = sendableValue
                if newValue == nil {
                    delegate = nil
                    objc_setAssociatedObject(self, &centralManagerProxyKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                }
            } else if let sendableValue {
                let proxy = CentralDelegateProxy()
                proxy.handler = sendableValue
                objc_setAssociatedObject(self, &centralManagerProxyKey, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                delegate = proxy
            }
        }
    }

    /// Maps the native `state` (`CBManagerState`) to ``CentralState``.
    public var radioState: CentralState {
        CentralState(state)
    }

    /// Maps the native `CBManager.authorization` class property (`CBManagerAuthorization`)
    /// to ``BluetoothAuthorization``.
    public static var bluetoothAuthorization: BluetoothAuthorization {
        BluetoothAuthorization(authorization)
    }

    /// Builds the `[CBUUID]?`/options dictionary CoreBluetooth's real
    /// `scanForPeripherals(withServices:options:)` expects, and delegates to it.
    public func scanForPeripherals(withServices services: [ServiceIdentifier]?, options: ScanOptions) {
        let cbOptions: [String: Any] = [
            CBCentralManagerScanOptionAllowDuplicatesKey: options.allowDuplicates
        ]
        scanForPeripherals(withServices: services?.map(\.cbuuid), options: cbOptions)
    }

    /// Downcasts `peripheral` to `CBPeripheral` and delegates to
    /// `connect(_:options:)`. A no-op if `peripheral` is not a `CBPeripheral`.
    public func connect(_ peripheral: any PeripheralRemote, options: WarningOptions?) {
        guard let cbPeripheral = peripheral as? CBPeripheral else { return }
        connect(cbPeripheral, options: options?.cbConnectOptions)
    }

    /// Downcasts `peripheral` to `CBPeripheral` and delegates to
    /// `cancelPeripheralConnection(_:)`. A no-op if `peripheral` is not a `CBPeripheral`.
    public func cancelPeripheralConnection(_ peripheral: any PeripheralRemote) {
        guard let cbPeripheral = peripheral as? CBPeripheral else { return }
        cancelPeripheralConnection(cbPeripheral)
    }

    /// Delegates to the real `retrievePeripherals(withIdentifiers:)` (disambiguated from
    /// this method by its `[CBPeripheral]` return type) and upcasts the result to
    /// `[any PeripheralRemote]`.
    public func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [any PeripheralRemote] {
        let cbPeripherals: [CBPeripheral] = retrievePeripherals(withIdentifiers: identifiers)
        return cbPeripherals
    }

    /// Builds the `[CBUUID]` CoreBluetooth's real
    /// `retrieveConnectedPeripherals(withServices:)` expects, delegates to it (disambiguated
    /// from this method by its `[CBPeripheral]` return type), and upcasts the result to
    /// `[any PeripheralRemote]`.
    public func retrieveConnectedPeripherals(withServices services: [ServiceIdentifier]) -> [any PeripheralRemote] {
        let cbPeripherals: [CBPeripheral] = retrieveConnectedPeripherals(withServices: services.map(\.cbuuid))
        return cbPeripherals
    }
}
