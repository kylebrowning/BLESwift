//
//  RestoredPeripheralState.swift
//  BLESwiftCore
//

// Unconditionally public, for the same reason as `RestoredState` (see its NOTE): it is a
// pure value type in a CoreBluetooth-free module, and it is the payload of the public
// `PeripheralHostEvent.willRestoreState` case, which must carry a type at least as
// accessible as the enum. The BEHAVIORAL restoration surface (the iOS-gated
// `PeripheralRestorationEvent`/config in the `BLESwift` module) stays iOS-only; only this
// inert value type is public everywhere.

/// Everything CoreBluetooth handed back in the peripheral-role `willRestoreState` delegate
/// callback, converted eagerly (in the `BLESwift` module's delegate proxy — the only place
/// raw `[String: Any]` dictionaries are touched) into `Sendable` BLESwift value types.
///
/// The `CBPeripheralManager` counterpart to ``RestoredState``. Delivered via
/// `PeripheralHost`'s restoration event stream, which buffers restoration events until the
/// first consumer arrives — so state restored before your app finished wiring its consumers
/// is never lost.
public struct RestoredPeripheralState: Sendable, Hashable {

    /// The services CoreBluetooth preserved and re-published on the app's behalf
    /// (`CBPeripheralManagerRestoredStateServicesKey`). Reported by identifier; the full
    /// definitions live in CoreBluetooth's re-established GATT database.
    public let services: [ServiceIdentifier]

    /// The advertisement CoreBluetooth was broadcasting when the app was terminated
    /// (`CBPeripheralManagerRestoredStateAdvertisementDataKey`), or `nil` if it was not
    /// advertising. Note that `PeripheralHost` does **not** automatically resume a restored
    /// advertisement.
    public let advertisement: PeripheralAdvertisement?

    /// Creates a `RestoredPeripheralState`.
    ///
    /// - Parameters:
    ///   - services: The preserved services, by identifier.
    ///   - advertisement: The preserved advertisement, or `nil`.
    public init(services: [ServiceIdentifier], advertisement: PeripheralAdvertisement? = nil) {
        self.services = services
        self.advertisement = advertisement
    }
}
