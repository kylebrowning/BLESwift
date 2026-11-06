//
//  PeripheralAdvertisement.swift
//  BLESwiftCore
//

/// The advertisement packet that a `PeripheralHost` broadcasts with
/// `PeripheralHost/startAdvertising(_:)`.
///
/// It carries only the two fields that `CBPeripheralManager` honors when it advertises: the local
/// name and the service UUIDs. A scanning central can observe other fields, but the advertising
/// side ignores them, so this type omits them.
public struct PeripheralAdvertisement: Sendable, Hashable {

    /// The local name to advertise (`CBAdvertisementDataLocalNameKey`). Use `nil` to advertise no
    /// name.
    public let localName: String?

    /// The service UUIDs to advertise (`CBAdvertisementDataServiceUUIDsKey`). If the array is
    /// empty, no service UUIDs are advertised.
    public let serviceUUIDs: [ServiceIdentifier]

    /// Creates a `PeripheralAdvertisement`.
    public init(localName: String? = nil, serviceUUIDs: [ServiceIdentifier] = []) {
        self.localName = localName
        self.serviceUUIDs = serviceUUIDs
    }
}
