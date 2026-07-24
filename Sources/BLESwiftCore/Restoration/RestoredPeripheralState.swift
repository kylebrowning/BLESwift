//
//  RestoredPeripheralState.swift
//  BLESwiftCore
//

/// Everything CoreBluetooth handed back in the peripheral-role `willRestoreState` delegate
/// callback, converted eagerly into `Sendable` BLESwift value types. The
/// `CBPeripheralManager` counterpart to ``RestoredState``. Delivered via `PeripheralHost`'s
/// restoration event stream, which buffers events until the first consumer arrives.
public struct RestoredPeripheralState: Sendable, Hashable {

    /// The services CoreBluetooth preserved and re-published on the app's behalf
    /// (`CBPeripheralManagerRestoredStateServicesKey`). Reported by identifier; the full
    /// definitions live in CoreBluetooth's re-established GATT database.
    public let services: [ServiceIdentifier]

    /// The advertisement CoreBluetooth was broadcasting when the app was terminated
    /// (`CBPeripheralManagerRestoredStateAdvertisementDataKey`), or `nil` if it was not
    /// advertising. When non-`nil`, CoreBluetooth *resumes* this advertisement across the
    /// relaunch on the app's behalf, so `PeripheralHost` reflects it in its `isAdvertising`
    /// snapshot — but `PeripheralHost` does **not** itself re-issue `startAdvertising`
    /// (CoreBluetooth already did).
    public let advertisement: PeripheralAdvertisement?

    /// Creates a `RestoredPeripheralState`.
    public init(services: [ServiceIdentifier], advertisement: PeripheralAdvertisement? = nil) {
        self.services = services
        self.advertisement = advertisement
    }
}
