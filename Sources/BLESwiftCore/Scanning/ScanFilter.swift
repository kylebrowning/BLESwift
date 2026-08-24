//
//  ScanFilter.swift
//  BLESwiftCore
//

import Foundation

/// Declarative match criteria for a scan. Only ``services`` reaches the radio
/// (CoreBluetooth's native service filter); every other field is applied on the actor,
/// per sighting, before any ``Discovery`` is reported — a non-matching sighting is
/// dropped entirely.
///
/// Every set field must hold (conditions AND together); a `nil`/unset field is not a
/// constraint. Holds a closure (``custom``), so `ScanFilter` is `Sendable` but not
/// `Equatable`/`Hashable`.
public struct ScanFilter: Sendable {

    /// The services to scan for — the only field passed to the radio
    /// (`scanForPeripherals(withServices:)`). `nil` scans for all peripherals.
    public var services: [ServiceIdentifier]?

    /// Requires the advertised name (falling back to the cached
    /// ``PeripheralIdentifier/name``) to start with this prefix.
    public var namePrefix: String?

    /// Requires the advertised name (falling back to the cached
    /// ``PeripheralIdentifier/name``) to equal this string exactly.
    public var nameExact: String?

    /// Requires ``AdvertisementData/manufacturerData`` whose first two bytes
    /// (little-endian company identifier) equal this value.
    public var manufacturerID: UInt16?

    /// Requires ``AdvertisementData/manufacturerData`` whose payload — the bytes *after*
    /// the 2-byte company identifier — starts with this prefix.
    public var manufacturerDataPrefix: Data?

    /// Per-service requirements on ``AdvertisementData/serviceData``: each keyed service
    /// must be present; a `nil` value means presence only, a non-`nil` value is a prefix
    /// match on that service's data.
    public var serviceData: [ServiceIdentifier: Data?]

    /// Requires ``Discovery/rssi`` to be at least this value (in dBm).
    public var minimumRSSI: Int?

    /// Requires ``AdvertisementData/isConnectable`` to be `true` — an absent
    /// `isConnectable` fails the filter when this is set.
    public var connectableOnly: Bool

    /// An arbitrary escape-hatch predicate, evaluated last.
    public var custom: (@Sendable (Discovery) -> Bool)?

    /// Creates a `ScanFilter`. Every parameter defaults to "no constraint".
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

    /// Whether `discovery` passes every set field. ``services`` is not re-checked here —
    /// it is a radio-level filter, already applied by CoreBluetooth.
    public func matches(_ discovery: Discovery) -> Bool {
        let name = discovery.advertisement.localName ?? discovery.peripheral.name

        if let namePrefix, !name.hasPrefix(namePrefix) {
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
