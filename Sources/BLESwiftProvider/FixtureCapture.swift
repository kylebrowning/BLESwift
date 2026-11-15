//
//  FixtureCapture.swift
//  BLESwiftProvider
//

#if os(macOS)
import BLESwift
import BLESwiftCore
import BLESwiftLink
import Foundation

/// The errors of ``FixtureCapture``.
package enum FixtureCaptureError: Error, Equatable, CustomStringConvertible {
    /// The text that the user typed is not a valid device selection. The value is the reason.
    case invalidSelection(String)

    package var description: String {
        switch self {
        case .invalidSelection(let reason):
            "invalid selection: \(reason)"
        }
    }
}

/// Records real devices as a ``BLESwiftLink/FixtureDocument``. The `capture` subcommand of
/// `bleswift-provider` uses it.
///
/// The type takes a `Central`, so a test can drive it with a virtual radio. The command line
/// gives it a `Central` on the Mac's CoreBluetooth.
package struct FixtureCapture: Sendable {

    /// One device that the scan saw: the latest advertisement and RSSI of a peripheral.
    package struct Candidate: Sendable {
        /// The identity of the peripheral.
        package var peripheral: PeripheralIdentifier
        /// The latest advertisement of the peripheral.
        package var advertisement: AdvertisementData
        /// The latest RSSI of the peripheral, in dBm.
        package var rssi: Int

        /// Creates a candidate.
        package init(peripheral: PeripheralIdentifier, advertisement: AdvertisementData, rssi: Int) {
            self.peripheral = peripheral
            self.advertisement = advertisement
            self.rssi = rssi
        }

        /// The advertised local name, else the peripheral's name, else `nil`.
        package var name: String? {
            advertisement.localName ?? peripheral.cachedName
        }

        /// Whether the advertisement says that the peripheral accepts connections. An
        /// advertisement without the flag counts as not connectable.
        package var isConnectable: Bool {
            advertisement.isConnectable ?? false
        }
    }

    /// The time limit for one connection attempt.
    package static let connectTimeout: Duration = .seconds(10)

    /// The time limit for one characteristic read.
    package static let readTimeout: Duration = .seconds(5)

    /// The central that scans for and connects to the devices.
    package let central: Central

    /// Creates a capture that uses `central`.
    package init(central: Central) {
        self.central = central
    }

    /// Scans for `duration` and returns the devices that match the filters.
    ///
    /// The scan does not report duplicates. It keeps the latest advertisement and RSSI of each
    /// peripheral. The result is in table order: the strongest RSSI first, then by name, then
    /// by identifier.
    ///
    /// - Parameters:
    ///   - duration: How long to scan.
    ///   - names: The name filters. See ``matches(_:names:services:)``.
    ///   - services: The service filters. See ``matches(_:names:services:)``.
    /// - Returns: The matching devices, in table order.
    /// - Throws: The error with which the scan stream failed.
    package func scan(for duration: Duration, names: [String], services: [String]) async throws -> [Candidate] {
        var latest: [UUID: Candidate] = [:]
        for try await event in await central.scan(services: nil, allowDuplicates: false, timeout: duration) {
            switch event {
            case .discovered(let discovery), .updated(let discovery):
                latest[discovery.peripheral.uuid] = Candidate(
                    peripheral: discovery.peripheral,
                    advertisement: discovery.advertisement,
                    rssi: discovery.rssi
                )
            case .lost:
                break
            }
        }
        return Self.sorted(latest.values.filter { Self.matches($0, names: names, services: services) })
    }

    /// Whether `candidate` passes the filters.
    ///
    /// A filter list that is empty passes every device. Within one list, one match is enough.
    /// A device must pass both lists.
    ///
    /// - Parameters:
    ///   - candidate: The device to test.
    ///   - names: Substrings of the advertised local name or the peripheral's name. Case does
    ///     not matter.
    ///   - services: Service UUID strings. The device must advertise one of them.
    /// - Returns: `true` if the device passes.
    package static func matches(_ candidate: Candidate, names: [String], services: [String]) -> Bool {
        let nameMatches = names.isEmpty || names.contains { filter in
            [candidate.advertisement.localName, candidate.peripheral.cachedName].contains { name in
                name?.range(of: filter, options: .caseInsensitive) != nil
            }
        }
        let advertised = Set(candidate.advertisement.serviceUUIDs ?? [])
        let serviceMatches = services.isEmpty || services.contains { filter in
            WireIdentifierValidation.isValid(filter) && advertised.contains(ServiceIdentifier(uuid: filter))
        }
        return nameMatches && serviceMatches
    }

    /// `candidates` in table order: the strongest RSSI first, then by name, then by identifier.
    package static func sorted(_ candidates: [Candidate]) -> [Candidate] {
        candidates.sorted { left, right in
            if left.rssi != right.rssi { return left.rssi > right.rssi }
            let leftName = left.name ?? ""
            let rightName = right.name ?? ""
            if leftName != rightName { return leftName < rightName }
            return left.peripheral.uuid.uuidString < right.peripheral.uuid.uuidString
        }
    }

    /// Parses the device selection that the user typed.
    ///
    /// The text is a comma-separated list of one-based table indexes, or `all`. Spaces do not
    /// matter. Empty text selects nothing.
    ///
    /// - Parameters:
    ///   - text: The text that the user typed.
    ///   - count: The number of devices in the table.
    /// - Returns: Zero-based indexes, in table order, with no duplicates.
    /// - Throws: ``FixtureCaptureError/invalidSelection(_:)`` for a part that is not a number
    ///   or not in the table.
    package static func parseSelection(_ text: String, count: Int) throws -> [Int] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.lowercased() == "all" { return Array(0..<count) }
        var selected: Set<Int> = []
        for part in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
            let item = part.trimmingCharacters(in: .whitespaces)
            guard let number = Int(item) else {
                throw FixtureCaptureError.invalidSelection("\(item) is not a number")
            }
            guard number >= 1, number <= count else {
                throw FixtureCaptureError.invalidSelection("\(number) is not in the list 1 to \(count)")
            }
            selected.insert(number - 1)
        }
        return selected.sorted()
    }

    /// Connects to each device in `candidates`, in order, and records it.
    ///
    /// For a connectable device, the method discovers every service and characteristic. It
    /// reads each characteristic that has the `read` property, then disconnects. A device that
    /// is not connectable, or that fails to connect, gives its advertisement only.
    ///
    /// The services and characteristics are in the order that `Peripheral` discovery returns.
    /// On hardware, this is the order of the device's GATT database. On a virtual radio, the
    /// order is unspecified.
    ///
    /// - Parameters:
    ///   - candidates: The devices to record, in table order.
    ///   - warn: Receives one line for each problem, such as a failed read.
    /// - Returns: One ``BLESwiftLink/FixtureDevice`` for each candidate, in the same order. Each
    ///   device has a new random `id`, not the identifier of the peripheral.
    package func inspect(_ candidates: [Candidate], warn: @Sendable (String) -> Void) async -> FixtureDocument {
        var devices: [FixtureDevice] = []
        for candidate in candidates {
            devices.append(await inspect(candidate, warn: warn))
        }
        return FixtureDocument(devices: devices)
    }

    /// Records one device.
    private func inspect(_ candidate: Candidate, warn: @Sendable (String) -> Void) async -> FixtureDevice {
        let label = candidate.name ?? candidate.peripheral.uuid.uuidString
        var device = FixtureDevice(
            // Use a new identifier, not the CoreBluetooth one. Under `--passthrough`, the real
            // device and the fixture device could otherwise have the same identifier.
            id: UUID(),
            name: candidate.name,
            advertisedServices: (candidate.advertisement.serviceUUIDs ?? []).map(\.uuidString),
            manufacturerData: candidate.advertisement.manufacturerData
        )
        guard candidate.isConnectable else {
            warn("\(label) is not connectable; recording its advertisement only")
            return device
        }
        let peripheral: Peripheral
        do {
            peripheral = try await central.connect(candidate.peripheral, timeout: Self.connectTimeout)
        } catch {
            warn("failed to connect to \(label): \(error); recording its advertisement only")
            return device
        }
        do {
            device.services = try await services(of: peripheral, label: label, warn: warn)
        } catch {
            warn("failed to discover the services of \(label): \(error); recording its advertisement only")
        }
        do {
            try await peripheral.disconnect()
        } catch {
            warn("failed to disconnect from \(label): \(error)")
        }
        return device
    }

    /// Discovers every service and characteristic of `peripheral` and reads the readable ones.
    private func services(
        of peripheral: Peripheral,
        label: String,
        warn: @Sendable (String) -> Void
    ) async throws -> [FixtureService] {
        var services: [FixtureService] = []
        for service in try await peripheral.discoverServices() {
            var characteristics: [FixtureCharacteristic] = []
            for characteristic in try await peripheral.discoverCharacteristics(for: service) {
                let properties = try await peripheral.properties(of: characteristic)
                var value: Data?
                if properties.contains(.read) {
                    do {
                        value = try await peripheral.read(from: characteristic, timeout: Self.readTimeout)
                    } catch {
                        warn("failed to read \(characteristic.uuidString) on \(label): \(error)")
                    }
                }
                characteristics.append(FixtureCharacteristic(
                    uuid: characteristic.uuidString,
                    properties: FixtureProperty.allCases.filter { properties.contains($0.characteristicProperty) },
                    permissions: nil,
                    value: value
                ))
            }
            // CoreBluetooth service discovery finds only primary services. A secondary service
            // is found only as an included service, which this capture does not discover.
            services.append(FixtureService(uuid: service.uuidString, isPrimary: true, characteristics: characteristics))
        }
        return services
    }
}
#endif
