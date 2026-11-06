//
//  ScanFilter.swift
//  BLESwiftCore
//

import Foundation

/// Declarative match criteria for a scan. Only ``services`` reaches the radio (as CoreBluetooth's
/// native service filter). The actor applies every other field to each sighting before it reports
/// a ``Discovery``, and drops a sighting that does not match.
///
/// Every set field must hold (the conditions combine with AND). A field that is `nil` or unset is
/// not a constraint. The filter holds a closure (``custom``), so `ScanFilter` is `Sendable` but
/// not `Equatable` or `Hashable`.
public struct ScanFilter: Sendable {

    /// The services to scan for. It is the only field that goes to the radio
    /// (`scanForPeripherals(withServices:)`). `nil` scans for all peripherals.
    public var services: [ServiceIdentifier]?

    /// Requires the advertised name to start with this prefix. If there is no advertised name, the
    /// filter uses the cached ``PeripheralIdentifier/cachedName``. A peripheral with neither name
    /// fails.
    public var namePrefix: String?

    /// Requires the advertised name to equal this string exactly. If there is no advertised name,
    /// the filter uses the cached ``PeripheralIdentifier/cachedName``. A peripheral with neither
    /// name fails.
    public var nameExact: String?

    /// Requires ``AdvertisementData/manufacturerData`` whose first two bytes (the little-endian
    /// company identifier) equal this value.
    public var manufacturerID: UInt16?

    /// Requires ``AdvertisementData/manufacturerData`` whose payload starts with this prefix. The
    /// payload is the bytes *after* the 2-byte company identifier.
    public var manufacturerDataPrefix: Data?

    /// Per-service requirements on ``AdvertisementData/serviceData``. Each keyed service must be
    /// present. A `nil` value means presence only. Otherwise the value is a prefix that the
    /// service's data must start with.
    public var serviceData: [ServiceIdentifier: Data?]

    /// Requires ``Discovery/rssi`` to be at least this value (in dBm).
    public var minimumRSSI: Int?

    /// Requires ``AdvertisementData/isConnectable`` to be `true`. If this is set and
    /// `isConnectable` is absent, the filter fails.
    public var connectableOnly: Bool

    /// An arbitrary predicate for cases that the other fields do not cover. It is evaluated last.
    public var custom: (@Sendable (Discovery) -> Bool)?

    /// Creates a `ScanFilter`. Every parameter has the default "no constraint".
    public init(
        services: [ServiceIdentifier]? = nil,
        namePrefix: String? = nil,
        nameExact: String? = nil,
        manufacturerID: UInt16? = nil,
        manufacturerDataPrefix: Data? = nil,
        serviceData: [ServiceIdentifier: Data?] = [:],
        minimumRSSI: Int? = nil,
        connectableOnly: Bool = false,
        custom: (@Sendable (Discovery) -> Bool)? = nil
    ) {
        self.services = services
        self.namePrefix = namePrefix
        self.nameExact = nameExact
        self.manufacturerID = manufacturerID
        self.manufacturerDataPrefix = manufacturerDataPrefix
        self.serviceData = serviceData
        self.minimumRSSI = minimumRSSI
        self.connectableOnly = connectableOnly
        self.custom = custom
    }

    /// Whether `discovery` passes every set field. It does not check ``services``, because
    /// CoreBluetooth already applied that radio-level filter.
    public func matches(_ discovery: Discovery) -> Bool {
        let name = discovery.advertisement.localName ?? discovery.peripheral.cachedName

        if let namePrefix, name?.hasPrefix(namePrefix) != true {
            return false
        }
        if let nameExact, name != nameExact {
            return false
        }

        if let manufacturerID {
            guard let data = discovery.advertisement.manufacturerData, data.count >= 2 else {
                return false
            }
            let low = data[data.startIndex]
            let high = data[data.index(after: data.startIndex)]
            guard UInt16(low) | (UInt16(high) << 8) == manufacturerID else { return false }
        }
        if let manufacturerDataPrefix {
            guard let data = discovery.advertisement.manufacturerData, data.count >= 2,
                  data.dropFirst(2).starts(with: manufacturerDataPrefix) else {
                return false
            }
        }

        for (service, expected) in serviceData {
            guard let stored = discovery.advertisement.serviceData?[service] else { return false }
            if let expected, !stored.starts(with: expected) {
                return false
            }
        }

        if let minimumRSSI, discovery.rssi < minimumRSSI {
            return false
        }

        if connectableOnly, discovery.advertisement.isConnectable != true {
            return false
        }

        if let custom, !custom(discovery) {
            return false
        }

        return true
    }
}
