//
//  ServiceChangesRegistryTests.swift
//  BLESwiftTests
//

import Foundation
import Testing
import BLESwiftCore
@testable import BLESwift

/// Tests ``ServiceChangesRegistry`` alone: get-or-create identity, independence of each identifier,
/// and no lost broadcaster in a race on a concurrent first access. `Central` uses it to keep the
/// `Peripheral.serviceChanges()` streams separate for each peripheral.
@Suite("ServiceChangesRegistry")
struct ServiceChangesRegistryTests {

    @Test("broadcaster(for:) returns the SAME instance across repeated calls for the same identifier")
    func getOrCreateReturnsSameInstance() {
        let registry = ServiceChangesRegistry()
        let id = PeripheralIdentifier(uuid: UUID(), name: "A")

        let first = registry.broadcaster(for: id)
        let second = registry.broadcaster(for: id)

        #expect(first === second)
    }

    @Test("Two different identifiers get two independent broadcasters")
    func differentIdentifiersGetIndependentBroadcasters() async {
        let registry = ServiceChangesRegistry()
        let idA = PeripheralIdentifier(uuid: UUID(), name: "A")
        let idB = PeripheralIdentifier(uuid: UUID(), name: "B")

        let broadcasterA = registry.broadcaster(for: idA)
        let broadcasterB = registry.broadcaster(for: idB)
        #expect(broadcasterA !== broadcasterB)

        let streamA = broadcasterA.stream()
        let streamB = broadcasterB.stream()
        async let collectedA = collect(streamA, count: 1)
        async let collectedB = collect(streamB, count: 0)

        await Task.yield()
        broadcasterA.yield([ServiceIdentifier(uuid: "180D")])
        broadcasterA.finish()
        broadcasterB.finish()

        #expect(await collectedA == [[ServiceIdentifier(uuid: "180D")]])
        #expect(await collectedB == [])
    }

    @Test("Two concurrent first-access calls for the same identifier never produce two broadcasters (no lost-broadcaster race)")
    func concurrentFirstAccessReturnsOneInstance() async {
        let registry = ServiceChangesRegistry()
        let id = PeripheralIdentifier(uuid: UUID(), name: "A")

        async let a = registry.broadcaster(for: id)
        async let b = registry.broadcaster(for: id)
        async let c = registry.broadcaster(for: id)

        let (resultA, resultB, resultC) = await (a, b, c)
        #expect(resultA === resultB)
        #expect(resultB === resultC)
    }

    /// Collects exactly `count` elements from `stream`, then returns without waiting for the stream
    /// to finish.
    private func collect(_ stream: AsyncStream<[ServiceIdentifier]>, count: Int) async -> [[ServiceIdentifier]] {
        var results: [[ServiceIdentifier]] = []
        var iterator = stream.makeAsyncIterator()
        while results.count < count, let value = await iterator.next() {
            results.append(value)
        }
        return results
    }
}
