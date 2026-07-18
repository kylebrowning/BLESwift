//
//  PeripheralAdvertisement.swift
//  BLESwiftCore
//

/// The advertisement packet a `PeripheralHost` broadcasts via
/// `PeripheralHost/startAdvertising(_:)`.
///
/// Deliberately carries only the two fields CoreBluetooth's `CBPeripheralManager`
/// **honors** when advertising — a local name and a set of service UUIDs
/// (`CBAdvertisementDataLocalNameKey` / `CBAdvertisementDataServiceUUIDsKey`). Every other
/// advertisement field a *scanning* central can observe (manufacturer data, service data,
/// tx power, …) is ignored by CoreBluetooth on the advertising side, so this type omits
/// them rather than implying they take effect. (The scan-side ``AdvertisementData`` is the
/// fuller, receive-side view.)
public struct PeripheralAdvertisement: Sendable, Hashable {

    /// The local name to advertise (`CBAdvertisementDataLocalNameKey`), or `nil` to
    /// advertise no name.
    public let localName: String?

    /// The service UUIDs to advertise (`CBAdvertisementDataServiceUUIDsKey`). Empty
    /// advertises no service UUIDs.
    public let serviceUUIDs: [ServiceIdentifier]

    /// Creates a `PeripheralAdvertisement`.
    ///
    /// - Parameters:
    ///   - localName: The local name to advertise. Defaults to `nil`.
    ///   - serviceUUIDs: The service UUIDs to advertise. Defaults to `[]`.
    public init(localName: String? = nil, serviceUUIDs: [ServiceIdentifier] = []) {
        self.localName = localName
        self.serviceUUIDs = serviceUUIDs
    }
}
