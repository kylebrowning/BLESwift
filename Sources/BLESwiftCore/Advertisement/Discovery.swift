//
//  Discovery.swift
//  BLESwiftCore
//

/// A single scan sighting of a peripheral: its identity, advertisement payload, and
/// signal strength.
public struct Discovery: Sendable {

    /// The identity of the discovered peripheral.
    public let peripheral: PeripheralIdentifier

    /// The peripheral's parsed advertisement data.
    public let advertisement: AdvertisementData

    /// The received signal strength indicator, in dBm.
    public let rssi: Int

    /// Creates a `Discovery`.
    ///
    /// - Parameters:
    ///   - peripheral: The identity of the discovered peripheral.
    ///   - advertisement: The peripheral's parsed advertisement data.
    ///   - rssi: The received signal strength indicator, in dBm.
    public init(peripheral: PeripheralIdentifier, advertisement: AdvertisementData, rssi: Int) {
        self.peripheral = peripheral
        self.advertisement = advertisement
        self.rssi = rssi
    }
}
