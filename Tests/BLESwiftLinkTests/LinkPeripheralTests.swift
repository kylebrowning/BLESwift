//
//  LinkPeripheralTests.swift
//  BLESwiftLinkTests
//

// Sockets in a CI simulator are not reliable. See `LinkCentralTests`. A `LinkCentral` dials as soon
// as it is built, so the compiler removes this suite from the simulator build.
#if !targetEnvironment(simulator)
import BLESwiftCore
import BLESwiftLink
@testable import BLESwiftSimulatorLink
import Dispatch
import Foundation
import Testing

/// The discovery cache of the client-side mirror, driven directly.
///
/// `LinkPeripheral` mirrors what the provider reports. No provider answers in these tests, so they
/// feed the peripheral the events that a provider would have sent.
@Suite("LinkPeripheral mirror")
struct LinkPeripheralTests {

    private static let heartRate = ServiceIdentifier(uuid: "180D")
    private static let battery = ServiceIdentifier(uuid: "180F")
    private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: heartRate)

    /// A mirror for a peripheral that nothing answers for. Its central dials a port with no
    /// listener, so the session drops every request.
    private func makeMirror(label: String) -> (LinkCentral, LinkPeripheral, DispatchQueue) {
        let queue = DispatchQueue(label: label)
        let central = LinkCentral(
            endpoint: LinkEndpoint(host: "127.0.0.1", port: 1),
            queue: queue,
            clientName: "mirror",
            retryInterval: .seconds(60)
        )
        let peripheral = queue.sync {
            central.retrievePeripherals(withIdentifiers: [UUID()])[0] as! LinkPeripheral
        }
        return (central, peripheral, queue)
    }

    @Test("A filtered discovery's answer joins the mirror; an unfiltered one replaces it")
    func filteredDiscoveryJoinsTheMirror() {
        let (central, peripheral, queue) = makeMirror(label: "LinkPeripheralTests.union")
        defer { central.shutdown() }

        queue.sync {
            peripheral.discoverServices(nil)
            peripheral.recordDiscoveredServices([Self.heartRate, Self.battery])
            #expect(peripheral.discoveredServices == [Self.heartRate, Self.battery])

            // A discovery narrowed to one service describes only that service, so the answer joins
            // the mirror. The provider's `VirtualPeripheralRemote` applies the same rule. If the
            // mirror replaced its data, it would forget a service that the provider still holds.
            peripheral.discoverServices([Self.battery])
            peripheral.recordDiscoveredServices([Self.battery])
            #expect(peripheral.discoveredServices == [Self.heartRate, Self.battery])

            peripheral.discoverServices([Self.heartRate])
            peripheral.recordDiscoveredServices([Self.heartRate])
            #expect(peripheral.discoveredServices == [Self.heartRate, Self.battery])

            // An unfiltered answer does describe the whole database, so a service that is missing
            // from it really is gone.
            peripheral.discoverServices(nil)
            peripheral.recordDiscoveredServices([Self.heartRate])
            #expect(peripheral.discoveredServices == [Self.heartRate])

            // The mirror reads an answer with no request behind it as unfiltered. A provider that
            // volunteers a service list describes the whole database.
            peripheral.recordDiscoveredServices([Self.battery])
            #expect(peripheral.discoveredServices == [Self.battery])
        }
    }

    @Test("A disconnect forgets the discoveries it was still waiting on")
    func disconnectForgetsPendingDiscoveries() {
        let (central, peripheral, queue) = makeMirror(label: "LinkPeripheralTests.disconnect")
        defer { central.shutdown() }

        queue.sync {
            // A filtered discovery goes unanswered across a disconnect. The answer that arrives
            // later belongs to a connection that is gone. If the mirror applied this request's
            // filter to the next connection's answer, it would join where it must replace.
            peripheral.discoverServices([Self.battery])
            peripheral.markDisconnected()
            #expect(peripheral.discoveredServices.isEmpty)

            peripheral.recordDiscoveredServices([Self.heartRate])
            #expect(peripheral.discoveredServices == [Self.heartRate])
            #expect(!peripheral.isDiscovered(Self.measurement))
        }
    }
}
#endif
