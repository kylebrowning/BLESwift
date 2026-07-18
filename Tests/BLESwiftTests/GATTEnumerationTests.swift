//
//  GATTEnumerationTests.swift
//  BLESwiftTests
//

import Foundation
import Testing
import BLESwiftCore
import BLESwiftTestSupport
import BLESwift

/// Exercises issue #12's GATT enumeration surface: `Peripheral.discoverServices()`,
/// `discoverCharacteristics(for:)`, and `discoverDescriptors(for:)` — listing a connected
/// peripheral's GATT graph without knowing UUIDs up front, driven through the scriptable
/// `FakePeripheral` service/characteristic/descriptor graph (`availableServices`,
/// `availableDescriptors`).
@Suite("GATT enumeration")
struct GATTEnumerationTests {

    // MARK: - Fixtures

    private static let heartRateService = ServiceIdentifier(uuid: "180D")
    private static let heartRateMeasurement = CharacteristicIdentifier(uuid: "2A37", service: heartRateService)
    private static let bodySensorLocation = CharacteristicIdentifier(uuid: "2A38", service: heartRateService)

    private static let batteryService = ServiceIdentifier(uuid: "180F")
    private static let batteryLevel = CharacteristicIdentifier(uuid: "2A19", service: batteryService)

    private static let userDescription = DescriptorIdentifier(uuid: "2901", characteristic: heartRateMeasurement)
    private static let presentationFormat = DescriptorIdentifier(uuid: "2904", characteristic: heartRateMeasurement)

    /// Scripts `fakePeripheral` with a two-service GATT graph, on its queue.
    private static func scriptGraph(_ fakePeripheral: FakePeripheral) async {
        await fakePeripheral.onQueue {
            fakePeripheral.availableServices = [
                heartRateService: [heartRateMeasurement, bodySensorLocation],
                batteryService: [batteryLevel],
            ]
        }
    }

    // MARK: - Service enumeration

    @Test("discoverServices() lists every service in the peripheral's GATT graph")
    func discoverServicesListsAll() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        await Self.scriptGraph(fakePeripheral)

        let services = try await peripheral.discoverServices()
        #expect(Set(services) == [Self.heartRateService, Self.batteryService])
        #expect(await fakePeripheral.onQueue { fakePeripheral.discoverServicesCallCount } == 1)
    }

    @Test("discoverServices() is cached: a second call re-uses the first enumeration")
    func discoverServicesCaches() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        await Self.scriptGraph(fakePeripheral)

        let first = try await peripheral.discoverServices()
        let second = try await peripheral.discoverServices()

        #expect(Set(first) == Set(second))
        #expect(await fakePeripheral.onQueue { fakePeripheral.discoverServicesCallCount } == 1)
    }

    @Test("discoverServices() on an empty graph returns an empty array")
    func discoverServicesEmptyGraph() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        await fakePeripheral.onQueue { fakePeripheral.availableServices = [:] }

        let services = try await peripheral.discoverServices()
        #expect(services.isEmpty)
    }

    // MARK: - Characteristic enumeration

    @Test("discoverCharacteristics(for:) lists every characteristic of a service")
    func discoverCharacteristicsListsAll() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        await Self.scriptGraph(fakePeripheral)

        let characteristics = try await peripheral.discoverCharacteristics(for: Self.heartRateService)
        #expect(Set(characteristics) == [Self.heartRateMeasurement, Self.bodySensorLocation])
    }

    @Test("discoverCharacteristics(for:) is cached: a second call re-uses the first enumeration")
    func discoverCharacteristicsCaches() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        await Self.scriptGraph(fakePeripheral)

        _ = try await peripheral.discoverCharacteristics(for: Self.heartRateService)
        let callsAfterFirst = await fakePeripheral.onQueue { fakePeripheral.discoverCharacteristicsCallCount }
        _ = try await peripheral.discoverCharacteristics(for: Self.heartRateService)
        let callsAfterSecond = await fakePeripheral.onQueue { fakePeripheral.discoverCharacteristicsCallCount }

        #expect(callsAfterFirst == 1)
        #expect(callsAfterSecond == 1)
    }

    @Test("discoverCharacteristics(for:) on a service with no characteristics returns an empty array")
    func discoverCharacteristicsEmpty() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        await fakePeripheral.onQueue {
            fakePeripheral.availableServices = [Self.heartRateService: []]
        }

        let characteristics = try await peripheral.discoverCharacteristics(for: Self.heartRateService)
        #expect(characteristics.isEmpty)
    }

    @Test("discoverCharacteristics(for:) throws .missingService for a service absent from the graph")
    func discoverCharacteristicsMissingService() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        await fakePeripheral.onQueue {
            fakePeripheral.availableServices = [Self.batteryService: [Self.batteryLevel]]
        }

        await #expect(throws: BLESwiftError.missingService(Self.heartRateService)) {
            _ = try await peripheral.discoverCharacteristics(for: Self.heartRateService)
        }
    }

    // MARK: - Descriptor enumeration

    @Test("discoverDescriptors(for:) lists every descriptor of a characteristic")
    func discoverDescriptorsListsAll() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        await Self.scriptGraph(fakePeripheral)
        await fakePeripheral.onQueue {
            fakePeripheral.availableDescriptors = [
                Self.heartRateMeasurement: [Self.userDescription, Self.presentationFormat],
            ]
        }

        let descriptors = try await peripheral.discoverDescriptors(for: Self.heartRateMeasurement)
        #expect(Set(descriptors) == [Self.userDescription, Self.presentationFormat])
    }

    @Test("discoverDescriptors(for:) is cached: a second call re-uses the first enumeration")
    func discoverDescriptorsCaches() async throws {
        let (_, _, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        await Self.scriptGraph(fakePeripheral)
        await fakePeripheral.onQueue {
            fakePeripheral.availableDescriptors = [Self.heartRateMeasurement: [Self.userDescription]]
        }

        _ = try await peripheral.discoverDescriptors(for: Self.heartRateMeasurement)
        let callsAfterFirst = await fakePeripheral.onQueue { fakePeripheral.discoverDescriptorsCallCount }
        _ = try await peripheral.discoverDescriptors(for: Self.heartRateMeasurement)
        let callsAfterSecond = await fakePeripheral.onQueue { fakePeripheral.discoverDescriptorsCallCount }

        #expect(callsAfterFirst == 1)
        #expect(callsAfterSecond == 1)
    }

    // MARK: - Disconnect fails a pending enumeration

    @Test("A pending discoverServices() fails when the connection is lost mid-flight")
    func disconnectFailsPendingEnumeration() async throws {
        let (central, fakeCentral, fakePeripheral, peripheral) = try await makeConnectedTestCentral()
        // Withhold the `didDiscoverServices` completion so the enumeration stays genuinely
        // pending (rather than resolving within the fake's own `queue.async` turn), letting the
        // disconnect land while its continuation is still parked.
        await Self.scriptGraph(fakePeripheral)
        await fakePeripheral.onQueue { fakePeripheral.holdServiceDiscoveryCompletions = true }

        let enumerationTask = Task<[ServiceIdentifier], Error> {
            try await peripheral.discoverServices()
        }
        // Wait until the enumeration has issued its (held) discoverServices call, then tear
        // the connection down out from under it.
        await waitFor { await fakePeripheral.onQueue { fakePeripheral.discoverServicesCallCount } == 1 }
        fakeCentral.simulateDisconnect(fakePeripheral.peripheralIdentifier, error: nil)

        let result = await enumerationTask.result
        switch result {
        case .success:
            Issue.record("expected the pending enumeration to fail once disconnected")
        case .failure(let error as BLESwiftError):
            #expect(error == .unexpectedDisconnect)
        case .failure(let error):
            Issue.record("expected a BLESwiftError, got \(error)")
        }

        guard case .disconnected = await central.connectionState(of: fakePeripheral.peripheralIdentifier) else {
            Issue.record("expected .disconnected")
            return
        }
    }
}
