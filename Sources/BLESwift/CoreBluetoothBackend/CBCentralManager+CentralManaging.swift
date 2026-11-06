//
//  CBCentralManager+CentralManaging.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth
import ObjectiveC

/// The identity token for the associated `CentralDelegateProxy`, which the
/// `CBCentralManager.eventHandler` below retains. `objc_(get|set)AssociatedObject` uses the
/// token's address. The code never reads or writes its value.
private nonisolated(unsafe) var centralManagerProxyKey: UInt8 = 0

/// Bridges `CentralManaging` to the real `CBCentralManager` API. A downcast of a mismatched
/// `PeripheralRemote` does nothing and never traps, because mixing shim families is a
/// programmer error.
///
/// No `@retroactive` is necessary. `CentralManaging` and this conformance are in different
/// modules of the same SPM package, and the SE-0364 check is package-scoped.
extension CBCentralManager: CentralManaging {

    /// Implements `eventHandler` with a `CentralDelegateProxy`. An associated object retains
    /// the proxy, because `.delegate` is `weak`. A non-`nil` handler creates the proxy on first
    /// use and reuses it later. Setting `nil` clears the proxy's handler and `.delegate`.
    ///
    /// - Important: `Central.init(configuration:)` does **not** use this property. At
    ///   construction, this setter would create a second, disconnected proxy. `init` passes its
    ///   own proxy directly to `CBCentralManager(delegate:queue:options:)`.
    public var eventHandler: ((CentralEvent) -> Void)? {
        get {
            (objc_getAssociatedObject(self, &centralManagerProxyKey) as? CentralDelegateProxy)?.handler
        }
        set {
            // Bridges the protocol's non-`@Sendable` closure to the `@Sendable` storage of
            // `CentralDelegateProxy.handler`. This is safe: `Central` is the only caller, and its
            // closures capture only `[weak self]` and the `Sendable` event payload. The compiler
            // cannot see this through the protocol's signature, so `nonisolated(unsafe)` asserts
            // it.
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

    /// Maps `CBManager.authorization` to ``BluetoothAuthorization``.
    public static var bluetoothAuthorization: BluetoothAuthorization {
        BluetoothAuthorization(authorization)
    }

    /// Builds the `[CBUUID]?` and options dictionary and calls CoreBluetooth's
    /// `scanForPeripherals(withServices:options:)`.
    public func scanForPeripherals(withServices services: [ServiceIdentifier]?, options: ScanOptions) {
        let cbOptions: [String: Any] = [
            CBCentralManagerScanOptionAllowDuplicatesKey: options.allowDuplicates
        ]
        scanForPeripherals(withServices: services?.map(\.cbuuid), options: cbOptions)
    }

    /// Downcasts `peripheral` to `CBPeripheral`, merges `requiresANCS` into the options
    /// (`CBConnectPeripheralOptionRequiresANCS`, iOS only), and calls `connect(_:options:)`. It
    /// does nothing if `peripheral` is not a `CBPeripheral`.
    public func connect(_ peripheral: any PeripheralRemote, options: WarningOptions?, requiresANCS: Bool) {
        guard let cbPeripheral = peripheral as? CBPeripheral else { return }
        var cbOptions: [String: Any] = options?.cbConnectOptions ?? [:]
        #if os(iOS)
        if requiresANCS {
            cbOptions[CBConnectPeripheralOptionRequiresANCS] = true
        }
        #endif
        connect(cbPeripheral, options: cbOptions.isEmpty ? nil : cbOptions)
    }

    /// Downcasts `peripheral` to `CBPeripheral` and calls `cancelPeripheralConnection(_:)`.
    /// It does nothing if `peripheral` is not a `CBPeripheral`.
    public func cancelPeripheralConnection(_ peripheral: any PeripheralRemote) {
        guard let cbPeripheral = peripheral as? CBPeripheral else { return }
        cancelPeripheralConnection(cbPeripheral)
    }

    /// Calls CoreBluetooth's `retrievePeripherals(withIdentifiers:)` and upcasts the result to
    /// `[any PeripheralRemote]`.
    public func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [any PeripheralRemote] {
        let cbPeripherals: [CBPeripheral] = retrievePeripherals(withIdentifiers: identifiers)
        return cbPeripherals
    }

    /// Builds the `[CBUUID]`, calls CoreBluetooth's `retrieveConnectedPeripherals(withServices:)`,
    /// and upcasts the result to `[any PeripheralRemote]`.
    public func retrieveConnectedPeripherals(withServices services: [ServiceIdentifier]) -> [any PeripheralRemote] {
        let cbPeripherals: [CBPeripheral] = retrieveConnectedPeripherals(withServices: services.map(\.cbuuid))
        return cbPeripherals
    }

    /// Builds the `[CBConnectionEventMatchingOption: Any]` and calls CoreBluetooth's
    /// `registerForConnectionEvents(options:)`. It does nothing on macOS, which lacks the API.
    public func registerForConnectionEvents(services: [ServiceIdentifier]?, peripherals: [UUID]?) {
        #if !os(macOS)
        var options: [CBConnectionEventMatchingOption: Any] = [:]
        if let services {
            options[.serviceUUIDs] = services.map(\.cbuuid)
        }
        if let peripherals {
            options[.peripheralUUIDs] = peripherals
        }
        registerForConnectionEvents(options: options)
        #endif
    }

    /// Calls `registerForConnectionEvents(options:)` with `nil`, which deregisters. It does
    /// nothing on macOS.
    public func unregisterForConnectionEvents() {
        #if !os(macOS)
        registerForConnectionEvents(options: nil)
        #endif
    }
}
