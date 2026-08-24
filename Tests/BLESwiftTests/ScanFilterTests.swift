//
//  ScanFilterTests.swift
//  BLESwiftTests
//

import Foundation
import Testing
import BLESwiftCore
import BLESwiftTestSupport
import BLESwift

/// Exercises `ScanFilter.matches` per field (pure, no Central), `Central.scan(filter:)`'s
/// pre-recording drop of non-matching sightings, `findFirst`'s every-exit-path teardown,
/// and the `connect(identifier:fallbackScan:)` saved-device flow.
@Suite("ScanFilter")
struct ScanFilterTests {

    /// Builds a `Discovery` directly, for filter unit tests.
    private func makeDiscovery(
        localName: String? = nil,
        peripheralName: String? = nil,
        manufacturerData: Data? = nil,
        serviceData: [ServiceIdentifier: Data]? = nil,
        isConnectable: Bool? = nil,
        rssi: Int = -50
    ) -> Discovery {
        Discovery(
            peripheral: PeripheralIdentifier(uuid: UUID(), name: peripheralName),
            advertisement: AdvertisementData(
                localName: localName,
                manufacturerData: manufacturerData,
                serviceData: serviceData,
                isConnectable: isConnectable
            ),
            rssi: rssi
        )
    }

    // MARK: - matches, per field

    @Test("An all-default filter matches everything")
    func allNilMatchesEverything() {
        #expect(ScanFilter().matches(makeDiscovery()))
        #expect(ScanFilter().matches(makeDiscovery(localName: "X", rssi: -100)))
    }

    @Test("services is radio-level only — matches ignores it")
    func servicesIgnoredByMatches() {
        let filter = ScanFilter(services: [ServiceIdentifier(uuid: "180D")])
        #expect(filter.matches(makeDiscovery()))
    }

    @Test("namePrefix matches the advertised name, falling back to the cached name")
    func namePrefixMatching() {
        let filter = ScanFilter(namePrefix: "Kettle")
        #expect(filter.matches(makeDiscovery(localName: "Kettle-01")))
        #expect(!filter.matches(makeDiscovery(localName: "Toaster-01")))
        // Falls back to the cached peripheral name when localName is absent.
        #expect(filter.matches(makeDiscovery(peripheralName: "Kettle-01")))
        // No advertised name and no cached name ("No Name") fails.
        #expect(!filter.matches(makeDiscovery()))
        // The advertised name wins over the cached one.
        #expect(!filter.matches(makeDiscovery(localName: "Toaster", peripheralName: "Kettle")))
    }

    @Test("nameExact requires an exact name")
    func nameExactMatching() {
        let filter = ScanFilter(nameExact: "Kettle-01")
        #expect(filter.matches(makeDiscovery(localName: "Kettle-01")))
        #expect(!filter.matches(makeDiscovery(localName: "Kettle-012")))
        #expect(filter.matches(makeDiscovery(peripheralName: "Kettle-01")))
        #expect(!filter.matches(makeDiscovery()))
    }

    @Test("manufacturerID matches the little-endian company identifier")
    func manufacturerIDMatching() {
        let filter = ScanFilter(manufacturerID: 0x004C)
        #expect(filter.matches(makeDiscovery(manufacturerData: Data([0x4C, 0x00, 0xFF]))))
        #expect(!filter.matches(makeDiscovery(manufacturerData: Data([0x00, 0x4C, 0xFF]))))
        #expect(!filter.matches(makeDiscovery(manufacturerData: Data([0x4C]))))
        #expect(!filter.matches(makeDiscovery()))
    }

    @Test("manufacturerDataPrefix matches the payload after the company identifier")
    func manufacturerDataPrefixMatching() {
        let filter = ScanFilter(manufacturerDataPrefix: Data([0x01, 0x02]))
        #expect(filter.matches(makeDiscovery(manufacturerData: Data([0x4C, 0x00, 0x01, 0x02, 0x03]))))
        #expect(!filter.matches(makeDiscovery(manufacturerData: Data([0x4C, 0x00, 0x02, 0x01]))))
        // The company identifier bytes themselves never count toward the prefix.
        #expect(!filter.matches(makeDiscovery(manufacturerData: Data([0x01, 0x02]))))
        #expect(!filter.matches(makeDiscovery()))
    }

    @Test("manufacturerID and manufacturerDataPrefix must both hold when both set")
    func manufacturerBothFields() {
        let filter = ScanFilter(manufacturerID: 0x004C, manufacturerDataPrefix: Data([0x01]))
        #expect(filter.matches(makeDiscovery(manufacturerData: Data([0x4C, 0x00, 0x01]))))
        #expect(!filter.matches(makeDiscovery(manufacturerData: Data([0x4C, 0x00, 0x02]))))
        #expect(!filter.matches(makeDiscovery(manufacturerData: Data([0x4D, 0x00, 0x01]))))
    }

    @Test("serviceData with a nil value requires presence only")
    func serviceDataPresenceOnly() {
        let service = ServiceIdentifier(uuid: "FE0F")
        let filter = ScanFilter(serviceData: [service: nil])
        #expect(filter.matches(makeDiscovery(serviceData: [service: Data([0x00])])))
        #expect(!filter.matches(makeDiscovery(serviceData: [ServiceIdentifier(uuid: "180D"): Data()])))
        #expect(!filter.matches(makeDiscovery()))
    }

    @Test("serviceData with a value requires a prefix match on that service's data")
    func serviceDataPrefixMatching() {
        let service = ServiceIdentifier(uuid: "FE0F")
        let filter = ScanFilter(serviceData: [service: Data([0xAA, 0xBB])])
        #expect(filter.matches(makeDiscovery(serviceData: [service: Data([0xAA, 0xBB, 0xCC])])))
        #expect(!filter.matches(makeDiscovery(serviceData: [service: Data([0xAA])])))
        #expect(!filter.matches(makeDiscovery(serviceData: [service: Data([0xBB, 0xAA])])))
    }

    @Test("minimumRSSI is an at-least bound")
    func minimumRSSIMatching() {
        let filter = ScanFilter(minimumRSSI: -60)
        #expect(filter.matches(makeDiscovery(rssi: -60)))
        #expect(filter.matches(makeDiscovery(rssi: -40)))
        #expect(!filter.matches(makeDiscovery(rssi: -61)))
    }

    @Test("connectableOnly requires isConnectable == true — absent fails")
    func connectableOnlyMatching() {
        let filter = ScanFilter(connectableOnly: true)
        #expect(filter.matches(makeDiscovery(isConnectable: true)))
        #expect(!filter.matches(makeDiscovery(isConnectable: false)))
        #expect(!filter.matches(makeDiscovery()))
    }

    @Test("custom is evaluated last and can veto")
    func customMatching() {
        let filter = ScanFilter(custom: { $0.rssi.isMultiple(of: 2) })
        #expect(filter.matches(makeDiscovery(rssi: -50)))
        #expect(!filter.matches(makeDiscovery(rssi: -51)))
    }

    @Test("Every set field must hold — conditions AND together")
    func combinedFilterAND() {
        let filter = ScanFilter(
            namePrefix: "Kettle",
            manufacturerID: 0x004C,
            minimumRSSI: -70,
            custom: { _ in true }
        )
        let matching = makeDiscovery(localName: "Kettle-01", manufacturerData: Data([0x4C, 0x00]), rssi: -60)
        #expect(filter.matches(matching))
        // Each single miss fails the whole filter.
        #expect(!filter.matches(makeDiscovery(localName: "Toaster", manufacturerData: Data([0x4C, 0x00]), rssi: -60)))
        #expect(!filter.matches(makeDiscovery(localName: "Kettle-01", manufacturerData: Data([0x4D, 0x00]), rssi: -60)))
        #expect(!filter.matches(makeDiscovery(localName: "Kettle-01", manufacturerData: Data([0x4C, 0x00]), rssi: -80)))
    }

    // MARK: - scan(filter:)

    @Test("scan(filter:) passes filter.services to the radio")
    func filterServicesReachTheRadio() async throws {
        let (central, fakeCentral, _) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {}

        let service = ServiceIdentifier(uuid: "180D")
        _ = await central.scan(filter: ScanFilter(services: [service]))

        let recorded = await fakeCentral.onQueue { fakeCentral.lastScanServices }
        #expect(recorded == [service])
    }

    @Test("scan(filter:) drops a non-matching sighting entirely and emits the matching one")
    func filterDropsNonMatchingSightings() async throws {
        let (central, fakeCentral, _) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {}

        let stream = await central.scan(filter: ScanFilter(namePrefix: "Kettle"))
        var iterator = stream.makeAsyncIterator()

        let nonMatching = PeripheralIdentifier(uuid: UUID(), name: nil)
        fakeCentral.simulateDiscovery(
            peripheral: nonMatching,
            advertisement: AdvertisementData(localName: "Toaster-01"),
            rssi: -40
        )
        await fakeCentral.onQueue {}

        let matching = PeripheralIdentifier(uuid: UUID(), name: nil)
        fakeCentral.simulateDiscovery(
            peripheral: matching,
            advertisement: AdvertisementData(localName: "Kettle-01"),
            rssi: -50
        )

        // If the non-matching sighting had wrongly been recorded/emitted, this .next()
        // would have returned it instead of the matching peripheral.
        let event = try await iterator.next()
        guard case .discovered(let discovery) = event else {
            Issue.record("expected .discovered, got \(String(describing: event))")
            return
        }
        #expect(discovery.peripheral == matching)
    }

    // MARK: - findFirst

    /// Waits (bounded) for `central`'s scan to be live before scripting a discovery.
    private func waitUntilScanning(_ central: Central) async throws {
        for _ in 0..<2000 where !central.isScanning {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(central.isScanning, "timed out waiting for the scan to start")
    }

    @Test("findFirst returns the first match and has torn the scan down before returning")
    func findFirstSuccess() async throws {
        let (central, fakeCentral, _) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {}

        let task = Task {
            try await central.findFirst(matching: ScanFilter(namePrefix: "Kettle"), timeout: .seconds(5))
        }
        try await waitUntilScanning(central)

        // A non-matching sighting first — findFirst must keep waiting.
        fakeCentral.simulateDiscovery(
            peripheral: PeripheralIdentifier(uuid: UUID(), name: nil),
            advertisement: AdvertisementData(localName: "Toaster-01"),
            rssi: -40
        )
        let expected = PeripheralIdentifier(uuid: UUID(), name: nil)
        fakeCentral.simulateDiscovery(
            peripheral: expected,
            advertisement: AdvertisementData(localName: "Kettle-01"),
            rssi: -50
        )

        let discovery = try await task.value
        #expect(discovery.peripheral == expected)
        // Torn down synchronously before findFirst returned — no queue flush here.
        #expect(central.isScanning == false)
    }

    @Test("findFirst with no match throws .timedOut and leaves no active scan")
    func findFirstTimeout() async throws {
        let (central, fakeCentral, _) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {}

        do {
            _ = try await central.findFirst(matching: ScanFilter(namePrefix: "Kettle"), timeout: .milliseconds(50))
            Issue.record("expected findFirst to throw .timedOut")
        } catch let error as BLESwiftError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
        #expect(central.isScanning == false)
    }

    @Test("findFirst cancelled mid-scan leaves no active scan")
    func findFirstCancellation() async throws {
        let (central, fakeCentral, _) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {}

        let task = Task {
            try await central.findFirst(matching: ScanFilter(namePrefix: "Kettle"))
        }
        try await waitUntilScanning(central)
        task.cancel()

        let result = await task.result
        guard case .failure = result else {
            Issue.record("expected the cancelled findFirst to throw")
            return
        }
        #expect(central.isScanning == false)
    }

    // MARK: - connect(identifier:fallbackScan:)

    @Test("connect(identifier:) succeeds via a known peripheral, no scan involved")
    func connectByIdentifierKnown() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {
            fakeCentral.retrievablePeripherals[fakePeripheral.identifier] = fakePeripheral
            fakeCentral.connectBehavior = .succeed
        }

        let peripheral = try await central.connect(identifier: fakePeripheral.identifier)
        #expect(peripheral.id == fakePeripheral.peripheralIdentifier)
        #expect(await fakeCentral.onQueue { fakeCentral.scanCallCount } == 0)
    }

    @Test("connect(identifier:) falls back to a scan and connects the discovered peripheral")
    func connectByIdentifierViaFallbackScan() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)
        // The saved UUID is stale (not retrievable), but the peripheral the fallback scan
        // finds IS registered retrievable — connect(_:)'s reserveConnectingSlot resolves the
        // discovered peripheral via retrievePeripherals(withIdentifiers:), so an
        // unregistered one could never complete the connect.
        await fakeCentral.onQueue {
            fakeCentral.retrievablePeripherals[fakePeripheral.identifier] = fakePeripheral
            fakeCentral.connectBehavior = .succeed
        }

        let staleIdentifier = UUID()
        let task = Task {
            try await central.connect(
                identifier: staleIdentifier,
                fallbackScan: ScanFilter(namePrefix: "Kettle")
            )
        }
        try await waitUntilScanning(central)

        fakeCentral.simulateDiscovery(
            peripheral: fakePeripheral.peripheralIdentifier,
            advertisement: AdvertisementData(localName: "Kettle-01"),
            rssi: -50
        )

        let peripheral = try await task.value
        #expect(peripheral.id == fakePeripheral.peripheralIdentifier)
        // The fallback-found peripheral's UUID may (and here does) differ from the saved one.
        #expect(peripheral.id.uuid != staleIdentifier)
        #expect(central.isScanning == false)
    }

    @Test("connect(identifier:) with no fallback throws .unexpectedPeripheral")
    func connectByIdentifierUnknownNoFallback() async throws {
        let (central, fakeCentral, _) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {}

        let identifier = UUID()
        do {
            _ = try await central.connect(identifier: identifier)
            Issue.record("expected connect to throw .unexpectedPeripheral")
        } catch let error as BLESwiftError {
            #expect(error == .unexpectedPeripheral(PeripheralIdentifier(uuid: identifier, name: nil)))
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }

    @Test("connect(identifier:) whose fallback never matches throws .timedOut")
    func connectByIdentifierFallbackTimesOut() async throws {
        let (central, fakeCentral, _) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)
        await fakeCentral.onQueue {}

        do {
            _ = try await central.connect(
                identifier: UUID(),
                fallbackScan: ScanFilter(namePrefix: "Kettle"),
                timeout: .milliseconds(50)
            )
            Issue.record("expected connect to throw .timedOut")
        } catch let error as BLESwiftError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
        #expect(central.isScanning == false)
    }
}
