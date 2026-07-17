//
//  CBCentralManager+CentralManaging.swift
//  BLESwift
//

import CoreBluetooth

/// `CBCentralManager` already implements `state`, the inherited `CBManager.authorization`
/// class property, `scanForPeripherals(withServices:options:)`, and `stopScan()` with
/// identical signatures, so those members require no additional code. The remaining three
/// members — `connect(_:options:)`, `cancelPeripheralConnection(_:)`, and
/// `retrievePeripherals(withIdentifiers:)` — take/return `any PeripheralRemote` in the
/// protocol (see ``CentralManaging`` for why) but `CBPeripheral` in the real
/// `CBCentralManager` API, so this conformance adds thin wrappers that downcast to
/// `CBPeripheral`, guard-let-else-return on a mismatch (never trap — mixing shim families
/// is a programmer error, not a runtime condition to crash on), and delegate to the real
/// method.
extension CBCentralManager: CentralManaging {

    /// Downcasts `peripheral` to `CBPeripheral` and delegates to
    /// `connect(_:options:)`. A no-op if `peripheral` is not a `CBPeripheral`.
    func connect(_ peripheral: any PeripheralRemote, options: [String: Any]?) {
        guard let cbPeripheral = peripheral as? CBPeripheral else { return }
        connect(cbPeripheral, options: options)
    }

    /// Downcasts `peripheral` to `CBPeripheral` and delegates to
    /// `cancelPeripheralConnection(_:)`. A no-op if `peripheral` is not a `CBPeripheral`.
    func cancelPeripheralConnection(_ peripheral: any PeripheralRemote) {
        guard let cbPeripheral = peripheral as? CBPeripheral else { return }
        cancelPeripheralConnection(cbPeripheral)
    }

    /// Delegates to the real `retrievePeripherals(withIdentifiers:)` (disambiguated from
    /// this method by its `[CBPeripheral]` return type) and upcasts the result to
    /// `[any PeripheralRemote]`.
    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [any PeripheralRemote] {
        let cbPeripherals: [CBPeripheral] = retrievePeripherals(withIdentifiers: identifiers)
        return cbPeripherals
    }
}
