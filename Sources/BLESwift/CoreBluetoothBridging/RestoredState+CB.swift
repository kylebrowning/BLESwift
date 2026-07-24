//
//  RestoredState+CB.swift
//  BLESwift
//

import BLESwiftCore
#if os(iOS)
import CoreBluetooth
#endif

#if os(iOS)

extension RestoredState {

    /// Eagerly converts CoreBluetooth's raw `willRestoreState` dictionary into `Sendable`
    /// BLESwift value types. Called only by `CentralDelegateProxy`.
    init(restorationDictionary dictionary: [String: Any]) {
        let cbPeripherals = dictionary[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        let peripherals = cbPeripherals.map { peripheral in
            RestoredPeripheral(
                identifier: PeripheralIdentifier(uuid: peripheral.identifier, name: peripheral.name),
                state: PeripheralConnectionState(peripheral.state)
            )
        }

        let scanServices = (dictionary[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID] ?? [])
            .map(ServiceIdentifier.init(cbuuid:))

        let scanOptions: RestoredScanOptions?
        if let rawOptions = dictionary[CBCentralManagerRestoredStateScanOptionsKey] as? [String: Any] {
            scanOptions = RestoredScanOptions(
                allowDuplicates: (rawOptions[CBCentralManagerScanOptionAllowDuplicatesKey] as? Bool) ?? false,
                solicitedServices: (rawOptions[CBCentralManagerScanOptionSolicitedServiceUUIDsKey] as? [CBUUID] ?? [])
                    .map(ServiceIdentifier.init(cbuuid:))
            )
        } else {
            scanOptions = nil
        }

        self.init(peripherals: peripherals, scanServices: scanServices, scanOptions: scanOptions)
    }
}

#endif
