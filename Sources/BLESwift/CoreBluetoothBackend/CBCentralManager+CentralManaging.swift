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

/// `CBCentralManager` already implements `stopScan()` with an identical signature, so that
/// member requires no additional code. Every other requirement needs a bridging
/// implementation: `radioState`/`bluetoothAuthorization` map CoreBluetooth's own
/// identically-named-but-differently-typed `state`/`authorization` properties (they can't
/// share the name — see ``CentralManaging``'s note); `scanForPeripherals(withServices:options:)`
/// builds the `[CBUUID]?`/options dictionary CoreBluetooth expects; `connect(_:options:)`,
/// `cancelPeripheralConnection(_:)`, and `retrievePeripherals(withIdentifiers:)` take/return
/// `any PeripheralRemote` in the protocol (see ``CentralManaging`` for why) but `CBPeripheral`
/// in the real `CBCentralManager` API, so downcast to `CBPeripheral`, guard-let-else-return
/// on a mismatch (never trap — mixing shim families is a programmer error, not a runtime
/// condition to crash on), and delegate to the real method;
/// `retrieveConnectedPeripherals(withServices:)` builds the `[CBUUID]` array CoreBluetooth
/// expects from `[ServiceIdentifier]`, same conversion as `scanForPeripherals`'s.
///
/// No `@retroactive` needed: `CentralManaging` (in `BLESwiftCore`) and this conformance
/// (in `BLESwift`) are different modules but the same SPM *package* — SE-0364's
/// retroactive-conformance check (and its warning under `.treatAllWarnings(as: .error)`)
/// is package-scoped, not module-scoped, so this doesn't trigger it.
extension CBCentralManager: CentralManaging {

    /// Implements `eventHandler` with an associated-object-retained `CentralDelegateProxy`
    /// assigned to `.delegate` (which is `weak` — the association is what keeps the proxy
    /// alive). Setting a non-`nil` handler creates the proxy on first use and reuses it on
    /// subsequent sets (updating its `handler`); setting `nil` clears both the proxy's
    /// handler and `.delegate`, and drops the association.
    ///
    /// - Important: `Central.init(configuration:)` does **not** go through this property —
    ///   it must create its `CentralDelegateProxy` and pass it directly to
    ///   `CBCentralManager(delegate:queue:options:)` at construction time (this property's
    ///   setter always creates a *fresh* proxy, which would be a second, disconnected
    ///   instance if used here), then sets that proxy's `handler` afterward. This asymmetry
    ///   is `Central`'s to document; `init(adopting:)` and the public backend init both use
    ///   this property uniformly, since in both cases the manager already exists.
    public var eventHandler: ((CentralEvent) -> Void)? {
        get {
            (objc_getAssociatedObject(self, &centralManagerProxyKey) as? CentralDelegateProxy)?.handler
        }
        set {
            // Bridges the protocol's plain (non-`@Sendable`) closure type into
            // `CentralDelegateProxy.handler`'s `@Sendable` storage. Sound, not merely
            // convenient: `Central` is the only caller of this setter, and every closure
            // it ever passes here captures nothing but `[weak self]` of the `Central`
            // actor itself (unconditionally `Sendable`) plus the event payload (also
            // `Sendable`) — genuinely safe to hand across isolation domains. The compiler
            // cannot see that through the protocol's necessarily non-`@Sendable` fixed
            // signature (`eventHandler`'s type is fixed by `CentralManaging`), so this
            // narrow `nonisolated(unsafe)` capture asserts it explicitly instead of
            // widening the protocol's own closure type.
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
