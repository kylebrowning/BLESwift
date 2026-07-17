//
//  CBCentralManager+CentralManaging.swift
//  BLESwift
//

import BLESwiftCore
import CoreBluetooth

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
/// condition to crash on), and delegate to the real method.
///
/// No `@retroactive` needed: `CentralManaging` (in `BLESwiftCore`) and this conformance
/// (in `BLESwift`) are different modules but the same SPM *package* — SE-0364's
/// retroactive-conformance check (and its warning under `.treatAllWarnings(as: .error)`)
/// is package-scoped, not module-scoped, so this doesn't trigger it.
extension CBCentralManager: CentralManaging {

    /// Maps the native `state` (`CBManagerState`) to ``CentralState``.
    package var radioState: CentralState {
        CentralState(state)
    }

    /// Maps the native `CBManager.authorization` class property (`CBManagerAuthorization`)
    /// to ``BluetoothAuthorization``.
    package static var bluetoothAuthorization: BluetoothAuthorization {
        BluetoothAuthorization(authorization)
    }

    /// Builds the `[CBUUID]?`/options dictionary CoreBluetooth's real
    /// `scanForPeripherals(withServices:options:)` expects, and delegates to it.
    package func scanForPeripherals(withServices services: [ServiceIdentifier]?, options: ScanOptions) {
        let cbOptions: [String: Any] = [
            CBCentralManagerScanOptionAllowDuplicatesKey: options.allowDuplicates
        ]
        scanForPeripherals(withServices: services?.map(\.cbuuid), options: cbOptions)
    }

    /// Downcasts `peripheral` to `CBPeripheral` and delegates to
    /// `connect(_:options:)`. A no-op if `peripheral` is not a `CBPeripheral`.
    package func connect(_ peripheral: any PeripheralRemote, options: WarningOptions?) {
        guard let cbPeripheral = peripheral as? CBPeripheral else { return }
        connect(cbPeripheral, options: options?.cbConnectOptions)
    }

    /// Downcasts `peripheral` to `CBPeripheral` and delegates to
    /// `cancelPeripheralConnection(_:)`. A no-op if `peripheral` is not a `CBPeripheral`.
    package func cancelPeripheralConnection(_ peripheral: any PeripheralRemote) {
        guard let cbPeripheral = peripheral as? CBPeripheral else { return }
        cancelPeripheralConnection(cbPeripheral)
    }

    /// Delegates to the real `retrievePeripherals(withIdentifiers:)` (disambiguated from
    /// this method by its `[CBPeripheral]` return type) and upcasts the result to
    /// `[any PeripheralRemote]`.
    package func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [any PeripheralRemote] {
        let cbPeripherals: [CBPeripheral] = retrievePeripherals(withIdentifiers: identifiers)
        return cbPeripherals
    }
}
