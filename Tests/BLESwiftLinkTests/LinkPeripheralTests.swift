//
//  LinkPeripheralTests.swift
//  BLESwiftLinkTests
//

// Sockets in a CI simulator are unreliable — see `LinkCentralTests` — and a `LinkCentral`
// dials as soon as it is built, so this suite is compiled out there like every other one
// that opens one.
#if !targetEnvironment(simulator)
import BLESwiftCore
import BLESwiftLink
@testable import BLESwiftSimulatorLink
import Dispatch
import Foundation
import Testing

/// The client-side mirror's discovery cache, driven directly.
///
/// `LinkPeripheral` mirrors what the provider reports because there is no CoreBluetooth
/// object graph on this side of the seam to consult. These tests drive the mirror itself: no
/// provider answers, so the peripheral is fed the events a provider would have sent.
@Suite("LinkPeripheral mirror")
struct LinkPeripheralTests {

    private static let heartRate = ServiceIdentifier(uuid: "180D")
    private static let battery = ServiceIdentifier(uuid: "180F")
    private static let measurement = CharacteristicIdentifier(uuid: "2A37", service: heartRate)

    /// A mirror for a peripheral nothing will ever answer for, on a central dialing a port
    /// nothing listens on — every request it sends is dropped by the unconnected session.
    private func makeMirror(label: String) -> (LinkCentral, LinkPeripheral, DispatchSerialQueue) {
        let queue = DispatchSerialQueue(label: label)
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
            // The whole database, as an unfiltered discovery reports it.
            peripheral.discoverServices(nil)
            peripheral.recordDiscoveredServices([Self.heartRate, Self.battery])
            #expect(peripheral.discoveredServices == [Self.heartRate, Self.battery])

            // A discovery narrowed to one service describes that service and nothing else, so
            // the answer joins the mirror — the same rule the provider's
            // `VirtualPeripheralRemote` applies to the same answer. Replacing here would have
            // this half of the seam forget a service the other half still holds.
            peripheral.discoverServices([Self.battery])
            peripheral.recordDiscoveredServices([Self.battery])
            #expect(peripheral.discoveredServices == [Self.heartRate, Self.battery])

            // Joining never duplicates a service already mirrored.
            peripheral.discoverServices([Self.heartRate])
            peripheral.recordDiscoveredServices([Self.heartRate])
            #expect(peripheral.discoveredServices == [Self.heartRate, Self.battery])

            // An unfiltered answer does describe the whole database, so a service missing
            // from it really is gone.
            peripheral.discoverServices(nil)
            peripheral.recordDiscoveredServices([Self.heartRate])
            #expect(peripheral.discoveredServices == [Self.heartRate])

            // An answer with no request behind it is read as unfiltered: a provider
            // volunteering a service list is describing the whole database.
            peripheral.recordDiscoveredServices([Self.battery])
            #expect(peripheral.discoveredServices == [Self.battery])
        }
    }

    @Test("A disconnect forgets the discoveries it was still waiting on")
    func disconnectForgetsPendingDiscoveries() {
        let (central, peripheral, queue) = makeMirror(label: "LinkPeripheralTests.disconnect")
        defer { central.shutdown() }

        queue.sync {
            // A filtered discovery goes unanswered across a disconnect: the answer that
            // arrives afterwards belongs to a connection that is gone, and crediting the next
            // connection's answer with this request's filter would join where it must replace.
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
