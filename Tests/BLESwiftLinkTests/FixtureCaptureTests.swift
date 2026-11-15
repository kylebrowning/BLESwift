//
//  FixtureCaptureTests.swift
//  BLESwiftLinkTests
//

#if os(macOS)
import BLESwift
import BLESwiftCore
import BLESwiftLink
import BLESwiftProvider
import Dispatch
import Foundation
import BLESwiftCompat17
import Testing

/// The capture of real devices as a fixture document, driven by an in-process virtual radio so
/// that no Bluetooth hardware is necessary.
@Suite("Fixture capture")
struct FixtureCaptureTests {

    private static let service = ServiceIdentifier(uuid: "180D")
    private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: service)
    private static let control = CharacteristicIdentifier(uuid: "2A39", service: service)
    private static let manufacturerData = Data([0x4C, 0x00, 0x01])

    /// A handler that the test never needs. The radio answers the static read itself, and the
    /// capture writes nothing.
    private struct IdleHandler: VirtualDeviceHandler {
        func read(_ characteristic: CharacteristicIdentifier, offset: Int, from central: Subscriber) async -> Result<Data, ATTError> {
            .failure(.readNotPermitted)
        }
        func write(_ entries: [WriteRequest.Entry], from central: Subscriber) async -> Result<Void, ATTError> {
            .success(())
        }
        func subscriptionChanged(_ characteristic: CharacteristicIdentifier, central: Subscriber, isSubscribed: Bool) async {}
    }

    /// Collects the warnings of a capture.
    private final class Warnings: Sendable {
        private let lines = Mutex<[String]>([])
        func append(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
    }

    /// Registers the test device on `radio`: one readable characteristic with a value, one
    /// write-only characteristic, and manufacturer data.
    private static func registerDevice(on radio: VirtualRadio, identifier: UUID) async -> VirtualDeviceHandle {
        await radio.register(VirtualDevice(
            descriptor: VirtualDeviceDescriptor(
                identifier: identifier,
                name: "Capture HRM",
                advertisement: AdvertisementData(
                    localName: "Capture HRM",
                    serviceUUIDs: [service],
                    manufacturerData: manufacturerData,
                    isConnectable: true
                ),
                services: [
                    GATTService(identifier: service, characteristics: [
                        GATTCharacteristic(identifier: measurement, properties: [.read], permissions: [.readable], value: Data([0, 72])),
                        GATTCharacteristic(identifier: control, properties: [.write], permissions: [.writeable]),
                    ])
                ]
            ),
            handler: IdleHandler()
        ))
    }

    /// A `Central` on `radio`, after it is powered on.
    private static func makeCentral(radio: VirtualRadio) async -> Central {
        let queue = DispatchQueue(label: "FixtureCaptureTests.central")
        let central = Central(backend: VirtualCentralBackend(radio: radio, queue: queue), queue: queue)
        await waitFor(timeout: .seconds(5)) { central.state == .poweredOn }
        return central
    }

    /// The document that a capture of the test device gives, with `measurementValue` as the
    /// value of the readable characteristic.
    private static func expectedDocument(identifier: UUID, measurementValue: Data?) -> FixtureDocument {
        FixtureDocument(devices: [
            FixtureDevice(
                id: identifier,
                name: "Capture HRM",
                advertisedServices: ["180D"],
                manufacturerData: manufacturerData,
                services: [
                    FixtureService(uuid: "180D", isPrimary: true, characteristics: [
                        FixtureCharacteristic(uuid: "2A37", properties: [.read], permissions: nil, value: measurementValue),
                        FixtureCharacteristic(uuid: "2A39", properties: [.write], permissions: nil, value: nil),
                    ])
                ]
            )
        ])
    }

    /// Checks that the device ids of `document` are unique and are not any of `peripherals`.
    /// Then returns the ids, so that the caller can compare the rest of the document.
    private static func checkIdentifiers(of document: FixtureDocument, peripherals: [UUID]) -> [UUID] {
        let ids = document.devices.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(Set(ids).isDisjoint(with: peripherals))
        return ids
    }

    /// `document` with its services and characteristics sorted by UUID. The order of discovery
    /// on a virtual radio is unspecified, so the tests compare sorted documents.
    private static func sortedByUUID(_ document: FixtureDocument) -> FixtureDocument {
        var sorted = document
        for index in sorted.devices.indices {
            sorted.devices[index].services.sort { $0.uuid < $1.uuid }
            for serviceIndex in sorted.devices[index].services.indices {
                sorted.devices[index].services[serviceIndex].characteristics.sort { $0.uuid < $1.uuid }
            }
        }
        return sorted
    }

    private static func candidate(
        name: String?,
        cachedName: String? = nil,
        services: [ServiceIdentifier] = [],
        rssi: Int = -50,
        uuid: UUID = UUID()
    ) -> FixtureCapture.Candidate {
        FixtureCapture.Candidate(
            peripheral: PeripheralIdentifier(uuid: uuid, name: cachedName),
            advertisement: AdvertisementData(localName: name, serviceUUIDs: services, isConnectable: true),
            rssi: rssi
        )
    }

    @Test("A capture records the advertisement, the GATT database, and the read values", .timeLimit(.minutes(1)))
    func capturesADevice() async throws {
        let radio = VirtualRadio()
        let identifier = UUID()
        _ = await Self.registerDevice(on: radio, identifier: identifier)
        let central = await Self.makeCentral(radio: radio)
        let capture = FixtureCapture(central: central)

        let candidates = try await capture.scan(for: .milliseconds(300), names: ["capture"], services: [])
        #expect(candidates.map(\.peripheral.uuid) == [identifier])
        let warnings = Warnings()
        let document = await capture.inspect(candidates) { warnings.append($0) }

        let id = try #require(Self.checkIdentifiers(of: document, peripherals: [identifier]).first)
        #expect(Self.sortedByUUID(document) == Self.expectedDocument(identifier: id, measurementValue: Data([0, 72])))
        // Two captures of the same peripheral get two different ids.
        let twice = await capture.inspect(candidates + candidates) { warnings.append($0) }
        #expect(twice.devices.count == 2)
        _ = Self.checkIdentifiers(of: twice, peripherals: [identifier])
        #expect(warnings.all.isEmpty)
        // The encoded form loads back. The load derives the permissions from the properties.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var loaded = Self.expectedDocument(identifier: id, measurementValue: Data([0, 72]))
        loaded.devices[0].services[0].characteristics[0].permissions = [.readable]
        loaded.devices[0].services[0].characteristics[1].permissions = [.writeable]
        #expect(try Self.sortedByUUID(FixtureDocument.parse(encoder.encode(document))) == loaded)
    }

    @Test("A failed read gives a nil value and one warning", .timeLimit(.minutes(1)))
    func failedReadGivesNil() async throws {
        let radio = VirtualRadio()
        let identifier = UUID()
        let handle = await Self.registerDevice(on: radio, identifier: identifier)
        await handle.setATTError(.readNotPermitted, for: Self.measurement, operations: .read)
        let central = await Self.makeCentral(radio: radio)
        let capture = FixtureCapture(central: central)

        let candidates = try await capture.scan(for: .milliseconds(300), names: [], services: ["180d"])
        let warnings = Warnings()
        let document = await capture.inspect(candidates) { warnings.append($0) }

        let id = try #require(Self.checkIdentifiers(of: document, peripherals: [identifier]).first)
        #expect(Self.sortedByUUID(document) == Self.expectedDocument(identifier: id, measurementValue: nil))
        #expect(warnings.all.count == 1)
        #expect(warnings.all.first?.contains("2A37") == true)
    }

    @Test("Filters are OR within a kind and AND across kinds")
    func filters() {
        let heartRate = ServiceIdentifier(uuid: "180D")
        let battery = ServiceIdentifier(uuid: "180F")
        let device = Self.candidate(name: "Polar H10", services: [heartRate])
        #expect(FixtureCapture.matches(device, names: [], services: []))
        #expect(FixtureCapture.matches(device, names: ["polar"], services: []))
        #expect(FixtureCapture.matches(device, names: ["garmin", "H10"], services: []))
        #expect(!FixtureCapture.matches(device, names: ["garmin"], services: []))
        #expect(FixtureCapture.matches(device, names: [], services: ["180F", "180d"]))
        #expect(!FixtureCapture.matches(device, names: [], services: [battery.uuidString]))
        #expect(FixtureCapture.matches(device, names: ["polar"], services: ["180D"]))
        #expect(!FixtureCapture.matches(device, names: ["polar"], services: ["180F"]))
        #expect(!FixtureCapture.matches(device, names: ["garmin"], services: ["180D"]))
        // The peripheral's name also matches when the advertisement has no local name.
        let cached = Self.candidate(name: nil, cachedName: "Kitchen Scale")
        #expect(FixtureCapture.matches(cached, names: ["scale"], services: []))
        #expect(!FixtureCapture.matches(Self.candidate(name: nil), names: ["scale"], services: []))
    }

    @Test("The table order is the strongest RSSI first, then the name, then the identifier")
    func tableOrder() throws {
        let low = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let high = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let candidates = [
            Self.candidate(name: "B", rssi: -70, uuid: UUID()),
            Self.candidate(name: "Z", rssi: -40, uuid: UUID()),
            Self.candidate(name: "A", rssi: -70, uuid: high),
            Self.candidate(name: "A", rssi: -70, uuid: low),
        ]
        let sorted = FixtureCapture.sorted(candidates)
        #expect(sorted.map(\.name) == ["Z", "A", "A", "B"])
        #expect(sorted[1].peripheral.uuid == low)
        #expect(sorted[2].peripheral.uuid == high)
    }

    @Test("Selection parsing")
    func selection() throws {
        #expect(try FixtureCapture.parseSelection("1,3", count: 3) == [0, 2])
        #expect(try FixtureCapture.parseSelection(" 3, 1 ,1 ", count: 3) == [0, 2])
        #expect(try FixtureCapture.parseSelection("all", count: 3) == [0, 1, 2])
        #expect(try FixtureCapture.parseSelection("ALL", count: 2) == [0, 1])
        #expect(try FixtureCapture.parseSelection("", count: 3) == [])
        #expect(try FixtureCapture.parseSelection("  \n", count: 3) == [])
        #expect(throws: FixtureCaptureError.self) { try FixtureCapture.parseSelection("9", count: 3) }
        #expect(throws: FixtureCaptureError.self) { try FixtureCapture.parseSelection("0", count: 3) }
        #expect(throws: FixtureCaptureError.self) { try FixtureCapture.parseSelection("1,x", count: 3) }
        #expect(throws: FixtureCaptureError.self) { try FixtureCapture.parseSelection("1,,2", count: 3) }
    }
}
#endif
