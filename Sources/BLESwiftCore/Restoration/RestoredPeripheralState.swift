//
//  RestoredPeripheralState.swift
//  BLESwiftCore
//

/// Everything that CoreBluetooth handed back in the peripheral-role `willRestoreState` delegate
/// callback, converted immediately to `Sendable` BLESwift value types. It is the
/// `CBPeripheralManager` counterpart of ``RestoredState``. `PeripheralHost`'s restoration event
/// stream delivers it and buffers events until the first consumer arrives.
public struct RestoredPeripheralState: Sendable, Hashable {

    /// The services that CoreBluetooth preserved and republished for the app
    /// (`CBPeripheralManagerRestoredStateServicesKey`), by identifier. The full definitions are in
    /// the GATT database that CoreBluetooth restored.
    public let services: [ServiceIdentifier]

    /// The advertisement that CoreBluetooth broadcast when the app was terminated
    /// (`CBPeripheralManagerRestoredStateAdvertisementDataKey`). It is `nil` if the peripheral did
    /// not advertise. Otherwise CoreBluetooth *resumes* this advertisement across the relaunch, so
    /// `PeripheralHost` reports it in its `isAdvertising` snapshot. `PeripheralHost` does **not**
    /// call `startAdvertising` again.
    public let advertisement: PeripheralAdvertisement?

    /// Creates a `RestoredPeripheralState`.
    public init(services: [ServiceIdentifier], advertisement: PeripheralAdvertisement? = nil) {
        self.services = services
        self.advertisement = advertisement
    }
}
