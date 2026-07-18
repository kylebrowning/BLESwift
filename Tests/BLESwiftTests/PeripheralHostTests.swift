//
//  PeripheralHostTests.swift
//  BLESwiftTests
//

@preconcurrency import CoreBluetooth
import Dispatch
import Foundation
import Testing
import BLESwiftCore
import BLESwiftTestSupport
import BLESwift

/// Creates a `PeripheralHost` wired to a fresh queue-confined `FakePeripheralManager`.
private func makeFakePeripheralHost(
    label: String = "BLESwiftTests.FakePeripheralManager"
) -> (PeripheralHost, FakePeripheralManager, DispatchSerialQueue) {
    let queue = DispatchSerialQueue(label: label)
    let fake = FakePeripheralManager(queue: queue)
    let host = PeripheralHost(backend: fake, queue: queue)
    return (host, fake, queue)
}

private let heartRate = ServiceIdentifier(uuid: "180D")
private let measurement = CharacteristicIdentifier(uuid: "2A37", service: heartRate)

private func aCentral(maxLength: Int = 20) -> Subscriber {
    Subscriber(id: UUID(), maximumUpdateValueLength: maxLength)
}

@Suite("PeripheralHost lifecycle")
struct PeripheralHostTests {

    @Test("Radio state flows through to the nonisolated snapshot and stream")
    func stateFlows() async throws {
        let (host, fake, _) = makeFakePeripheralHost()
        #expect(host.state == .unknown)

        // Subscribe before simulating, so the transition is observed. (The .latest replay
        // only buffers *yielded* values; the initial .unknown is never yielded, so it is not
        // replayed here.)
        var iterator = await host.stateEvents().makeAsyncIterator()

        fake.simulateStateChange(.poweredOn)
        #expect(await iterator.next() == .poweredOn)
        #expect(host.state == .poweredOn)
    }

    @Test("add(_:) awaits didAddService and records the compiled service")
    func addService() async throws {
        let (host, fake, _) = makeFakePeripheralHost()
        fake.simulateStateChange(.poweredOn)

        let service = GATTService(identifier: heartRate, characteristics: [
            GATTCharacteristic(identifier: measurement, properties: [.read, .notify], permissions: [.readable])
        ])
        try await host.add(service)

        let added = await fake.onQueue { fake.addedServices }
        #expect(added.count == 1)
        #expect(added.first?.identifier == heartRate)
        #expect(added.first?.characteristics.first?.properties == [.read, .notify])
    }

    @Test("add(_:) surfaces CoreBluetooth's add error")
    func addServiceError() async throws {
        let (host, fake, _) = makeFakePeripheralHost()
        let expected = NSError(domain: "BLESwiftTests", code: 7)
        await fake.onQueue { fake.addServiceError = expected }

        await #expect(throws: expected) {
            try await host.add(GATTService(identifier: heartRate))
        }
    }

    @Test("startAdvertising awaits didStartAdvertising and flips isAdvertising")
    func advertising() async throws {
        let (host, fake, _) = makeFakePeripheralHost()
        fake.simulateStateChange(.poweredOn)
        await fake.onQueue {} // flush

        #expect(!host.isAdvertising)
        try await host.startAdvertising(PeripheralAdvertisement(localName: "Rig", serviceUUIDs: [heartRate]))
        #expect(host.isAdvertising)

        let advertisement = await fake.onQueue { fake.lastAdvertisement }
        #expect(advertisement?.localName == "Rig")
        #expect(advertisement?.serviceUUIDs == [heartRate])

        await host.stopAdvertising()
        #expect(await fake.onQueue { fake.stopAdvertisingCallCount } == 1)
    }

    @Test("startAdvertising surfaces a failure error")
    func advertisingFailure() async throws {
        let (host, fake, _) = makeFakePeripheralHost()
        let expected = NSError(domain: "BLESwiftTests", code: 9)
        await fake.onQueue { fake.startAdvertisingError = expected }

        await #expect(throws: expected) {
            try await host.startAdvertising(PeripheralAdvertisement(localName: "Rig"))
        }
        #expect(!host.isAdvertising)
    }

    @Test("A read request is surfaced and answered with data")
    func readRequestRoundTrip() async throws {
        let (host, fake, _) = makeFakePeripheralHost()
        fake.simulateStateChange(.poweredOn)

        var iterator = await host.readRequests().makeAsyncIterator()
        let central = aCentral()
        fake.simulateReadRequest(central: central, characteristic: measurement, offset: 0)

        let request = try #require(await iterator.next())
        #expect(request.characteristic == measurement)
        #expect(request.central == central)

        await host.respond(to: request, with: .success(Data([0x11, 0x22])))

        let responses = await fake.onQueue { fake.respondCalls }
        #expect(responses.count == 1)
        #expect(responses.first?.token == request.token)
        #expect(responses.first?.value == Data([0x11, 0x22]))
        #expect(responses.first?.error == nil)
    }

    @Test("A read request can be rejected with an ATT error")
    func readRequestRejected() async throws {
        let (host, fake, _) = makeFakePeripheralHost()
        fake.simulateStateChange(.poweredOn)

        var iterator = await host.readRequests().makeAsyncIterator()
        fake.simulateReadRequest(central: aCentral(), characteristic: measurement)
        let request = try #require(await iterator.next())

        await host.respond(to: request, with: .failure(.readNotPermitted))

        let responses = await fake.onQueue { fake.respondCalls }
        #expect(responses.first?.error == .readNotPermitted)
        #expect(responses.first?.value == nil)
    }

    @Test("A write-request batch is surfaced and acknowledged once")
    func writeRequestRoundTrip() async throws {
        let (host, fake, _) = makeFakePeripheralHost()
        fake.simulateStateChange(.poweredOn)

        var iterator = await host.writeRequests().makeAsyncIterator()
        let central = aCentral()
        fake.simulateWriteRequest(central: central, characteristic: measurement, value: Data([0xAB]))

        let request = try #require(await iterator.next())
        #expect(request.entries.count == 1)
        #expect(request.entries.first?.value == Data([0xAB]))
        #expect(request.entries.first?.characteristic == measurement)

        await host.respond(to: request, with: .success(()))

        let responses = await fake.onQueue { fake.respondCalls }
        #expect(responses.count == 1)
        #expect(responses.first?.token == request.token)
        #expect(responses.first?.error == nil)
    }

    @Test("Subscribe/unsubscribe events are surfaced and tracked in subscribers(for:)")
    func subscriptionTracking() async throws {
        let (host, fake, _) = makeFakePeripheralHost()
        fake.simulateStateChange(.poweredOn)

        var iterator = await host.subscriptionEvents().makeAsyncIterator()
        let central = aCentral()

        fake.simulateSubscribe(central: central, to: measurement)
        guard case .subscribed(let subscribed, let characteristic) = try #require(await iterator.next()) else {
            Issue.record("expected .subscribed")
            return
        }
        #expect(subscribed == central)
        #expect(characteristic == measurement)
        #expect(await host.subscribers(for: measurement) == [central])

        fake.simulateUnsubscribe(central: central, from: measurement)
        guard case .unsubscribed = try #require(await iterator.next()) else {
            Issue.record("expected .unsubscribed")
            return
        }
        #expect(await host.subscribers(for: measurement).isEmpty)
    }

    @Test("updateValue awaits transmit capacity: false then ready then retry succeeds")
    func updateValueBackPressure() async throws {
        let (host, fake, _) = makeFakePeripheralHost()
        fake.simulateStateChange(.poweredOn)
        // Script exactly one full-queue return, so the first updateValue returns false.
        await fake.onQueue { fake.scriptedUpdateValueReturns = [false] }

        let central = aCentral()
        fake.simulateSubscribe(central: central, to: measurement)
        await fake.onQueue {} // flush subscribe

        let update = Task { try await host.updateValue(Data([0xAA]), for: measurement) }

        // The first (false) call must have happened, and the update must still be pending.
        await waitFor { await fake.onQueue { fake.updateValueCalls.count } >= 1 }
        #expect(await fake.onQueue { fake.updateValueCalls.first?.returned } == false)

        fake.simulateReadyToUpdate()
        try await update.value

        let calls = await fake.onQueue { fake.updateValueCalls }
        #expect(calls.count == 2)
        #expect(calls.last?.returned == true)
        #expect(calls.last?.value == Data([0xAA]))
    }

    @Test("An updateValue awaiting capacity fails when the radio powers off")
    func updateValueFailsOnPowerOff() async throws {
        let (host, fake, _) = makeFakePeripheralHost()
        fake.simulateStateChange(.poweredOn)
        await fake.onQueue { fake.scriptedUpdateValueReturns = [false] }

        let update = Task { try await host.updateValue(Data([0x01]), for: measurement) }
        await waitFor { await fake.onQueue { fake.updateValueCalls.count } >= 1 }

        fake.simulateStateChange(.poweredOff)

        await #expect(throws: BLESwiftError.bluetoothUnavailable) {
            try await update.value
        }
    }

    @Test("removeAllServices clears the backend, and stopAndExtractState throws for a fake backend")
    func teardown() async throws {
        let (host, fake, _) = makeFakePeripheralHost()
        fake.simulateStateChange(.poweredOn)
        try await host.add(GATTService(identifier: heartRate))
        #expect(await fake.onQueue { fake.addedServices.count } == 1)

        await host.removeAllServices()
        #expect(await fake.onQueue { fake.removeAllServicesCallCount } == 1)
        #expect(await fake.onQueue { fake.addedServices.isEmpty })

        // A backend-backed host was not created against a real CBPeripheralManager.
        do {
            _ = try await host.stopAndExtractState()
            Issue.record("expected stopAndExtractState() to throw .stopped")
        } catch let error as BLESwiftError {
            #expect(error == .stopped)
        } catch {
            Issue.record("expected a BLESwiftError, got \(error)")
        }
    }
}
