//
//  RetrievalTests.swift
//  BLESwiftTests
//

@preconcurrency import CoreBluetooth
import BLESwift
import BLESwiftCore
import BLESwiftTestSupport
import Dispatch
import Testing

/// Exercises plan 04's system-known peripheral retrieval surface:
/// ``Central/knownPeripherals(withIdentifiers:)`` and
/// ``Central/systemConnectedPeripherals(withServices:)``, driven entirely through the
/// fakes (`makeTestCentral()`), plus the `.stopped` guard on a real `CBCentralManager`.
@Suite("Retrieval")
struct RetrievalTests {

    private static let heartRateService = ServiceIdentifier(uuid: "180D")
    private static let batteryService = ServiceIdentifier(uuid: "180F")

    // MARK: - knownPeripherals(withIdentifiers:)

    @Test("knownPeripherals resolves a scripted retrievablePeripherals entry to a PeripheralIdentifier")
    func knownPeripheralsResolvesScriptedEntry() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)
        fakeCentral.onQueue {
            fakeCentral.retrievablePeripherals[fakePeripheral.identifier] = fakePeripheral
        }

        let results = try await central.knownPeripherals(withIdentifiers: [fakePeripheral.identifier])

        #expect(results == [fakePeripheral.peripheralIdentifier])
        #expect(results.first?.uuid == fakePeripheral.identifier)
        #expect(results.first?.name == fakePeripheral.name)
    }

    @Test("knownPeripherals omits unknown UUIDs and returns [] when nothing is scripted; [] input -> [] output")
    func knownPeripheralsOmitsUnknownAndHandlesEmpty() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)
        fakeCentral.onQueue {
            fakeCentral.retrievablePeripherals[fakePeripheral.identifier] = fakePeripheral
        }

        let unknown = UUID()
        let results = try await central.knownPeripherals(withIdentifiers: [fakePeripheral.identifier, unknown])
        #expect(results == [fakePeripheral.peripheralIdentifier])

        // Nothing scripted at all.
        let (emptyCentral, _, _) = makeTestCentral()
        let emptyResults = try await emptyCentral.knownPeripherals(withIdentifiers: [UUID()])
        #expect(emptyResults == [])

        // Empty input.
        let noInputResults = try await central.knownPeripherals(withIdentifiers: [])
        #expect(noInputResults == [])
    }

    // MARK: - systemConnectedPeripherals(withServices:)

    @Test("systemConnectedPeripherals returns exactly the scripted peripherals whose services intersect the query")
    func systemConnectedPeripheralsFiltersByServiceIntersection() async throws {
        let (central, fakeCentral, queue) = makeFakeCentralOnly()
        fakeCentral.simulateStateChange(.poweredOn)

        let heartRatePeripheral = FakePeripheral(name: "Heart Rate Monitor", queue: queue)
        let batteryPeripheral = FakePeripheral(name: "Battery Pack", queue: queue)
        fakeCentral.onQueue {
            fakeCentral.systemConnectedPeripherals = [
                (peripheral: heartRatePeripheral, services: [Self.heartRateService]),
                (peripheral: batteryPeripheral, services: [Self.batteryService])
            ]
        }

        let results = try await central.systemConnectedPeripherals(withServices: [Self.heartRateService])

        #expect(results == [heartRatePeripheral.peripheralIdentifier])
    }

    @Test("systemConnectedPeripherals returns [] for no overlap and [] when nothing scripted")
    func systemConnectedPeripheralsReturnsEmptyForNoOverlapOrNothingScripted() async throws {
        let (central, fakeCentral, queue) = makeFakeCentralOnly()
        fakeCentral.simulateStateChange(.poweredOn)

        // Nothing scripted at all.
        let noneScripted = try await central.systemConnectedPeripherals(withServices: [Self.heartRateService])
        #expect(noneScripted == [])

        // Scripted, but disjoint from the query.
        let batteryPeripheral = FakePeripheral(name: "Battery Pack", queue: queue)
        fakeCentral.onQueue {
            fakeCentral.systemConnectedPeripherals = [
                (peripheral: batteryPeripheral, services: [Self.batteryService])
            ]
        }
        let noOverlap = try await central.systemConnectedPeripherals(withServices: [Self.heartRateService])
        #expect(noOverlap == [])
    }

    // MARK: - The retrieve-then-connect loop

    @Test("a systemConnectedPeripherals result connects: script into both systemConnectedPeripherals and retrievablePeripherals")
    func retrieveThenConnectLoop() async throws {
        let (central, fakeCentral, fakePeripheral) = makeTestCentral()
        fakeCentral.simulateStateChange(.poweredOn)

        // Plan 04 §6: on real CoreBluetooth, a system-connected peripheral is a fortiori
        // known; in fakes these are two separately scripted maps, so both must be scripted
        // to mirror that reality.
        fakeCentral.onQueue {
            fakeCentral.systemConnectedPeripherals = [
                (peripheral: fakePeripheral, services: [Self.heartRateService])
            ]
            fakeCentral.retrievablePeripherals[fakePeripheral.identifier] = fakePeripheral
            fakeCentral.connectBehavior = .succeed
        }

        let found = try await central.systemConnectedPeripherals(withServices: [Self.heartRateService])
        let identifier = try #require(found.first)
        #expect(found.count == 1)

        let peripheral = try await central.connect(identifier)

        #expect(peripheral.id == identifier)
        let connectionState = await central.connectionState(of: identifier)
        guard case .connected = connectionState else {
            Issue.record("expected .connected, got \(connectionState)")
            return
        }
    }

    // MARK: - .stopped

    @Test("knownPeripherals and systemConnectedPeripherals throw .stopped after stopAndExtractState()")
    func bothMethodsThrowStoppedAfterExtraction() async throws {
        // Same real-CBCentralManager adopting-init pattern as
        // CentralTests.adoptingInitWiresGivenManager — the only way to make `.stopped`
        // reachable for a `Central` backed by a real (rather than test-adopted `nil`)
        // manager.
        let mainQueue = DispatchQueue.main as! DispatchSerialQueue
        let manager = CBCentralManager(delegate: nil, queue: mainQueue)
        let central = Central(adopting: manager, callbackQueue: mainQueue)

        _ = try await central.stopAndExtractState()

        do {
            _ = try await central.knownPeripherals(withIdentifiers: [UUID()])
            Issue.record("expected knownPeripherals(withIdentifiers:) to throw .stopped")
        } catch let error as BLESwiftError {
            #expect(error == .stopped)
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }

        do {
            _ = try await central.systemConnectedPeripherals(withServices: [Self.heartRateService])
            Issue.record("expected systemConnectedPeripherals(withServices:) to throw .stopped")
        } catch let error as BLESwiftError {
            #expect(error == .stopped)
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }

    // MARK: - Helpers

    /// Like `makeFakeCentral()`, but returns the queue directly rather than pairing the
    /// fake central with a single fake peripheral — the service-intersection tests above
    /// script multiple independent `FakePeripheral`s on the same queue.
    private func makeFakeCentralOnly(label: String = "RetrievalTests.FakeCentral") -> (Central, FakeCentral, DispatchSerialQueue) {
        let queue = DispatchSerialQueue(label: label)
        let fakeCentral = FakeCentral(queue: queue)
        let central = Central(backend: fakeCentral, queue: queue)
        return (central, fakeCentral, queue)
    }
}
