//
//  PeripheralAdvertisement.swift
//  BLESwiftCore
//

/// The advertisement packet a `PeripheralHost` broadcasts via
/// `PeripheralHost/startAdvertising(_:)`.
///
/// Carries only the two fields `CBPeripheralManager` actually honors when advertising —
/// local name and service UUIDs; every other field a scanning central can observe is
/// ignored on the advertising side, so this type omits them.
public struct PeripheralAdvertisement: Sendable, Hashable {

    /// The local name to advertise (`CBAdvertisementDataLocalNameKey`), or `nil` to
    /// advertise no name.
    public let localName: String?

    /// The service UUIDs to advertise (`CBAdvertisementDataServiceUUIDsKey`). Empty
    /// advertises no service UUIDs.
    public let serviceUUIDs: [ServiceIdentifier]

    /// Creates a `PeripheralAdvertisement`.
    public init(localName: String? = nil, serviceUUIDs: [ServiceIdentifier] = []) {
        self.localName = localName
        self.serviceUUIDs = serviceUUIDs
    }
}
