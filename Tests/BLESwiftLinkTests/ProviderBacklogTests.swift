//
//  ProviderBacklogTests.swift
//  BLESwiftLinkTests
//

#if os(macOS)
import BLESwiftCore
import BLESwiftLink
@testable import BLESwiftProvider
import Dispatch
import Foundation
import Testing

/// What the provider's pending-connection table holds for a connection that has not been
/// served yet, driven directly rather than over a socket — the routing decision is synchronous
/// and total, so it can be asserted exactly.
@Suite("Provider pending-connection backlog")
struct ProviderBacklogTests {

    private static let service = ServiceIdentifier(uuid: "180D")
    private static let control = CharacteristicIdentifier(uuid: "2A39", service: service)

    /// One `writeValue` carrying `bytes` of payload — the biggest thing a client can put
    /// behind its own hello.
    private static func write(_ bytes: Int) -> LinkMessage {
        .centralRequest(.writeValue(
            peripheral: UUID(),
            characteristic: WireCharacteristicRef(control),
            value: Data(repeating: 0x5A, count: bytes),
            type: .withoutResponse,
            sequence: 0
        ))
    }

    /// A connection object for the table to key on. Never started: nothing here touches a
    /// socket.
    private static func connection() -> LinkConnection {
        LinkConnection.connect(
            to: LinkEndpoint(host: "127.0.0.1", port: 1),
            codec: .binaryPropertyList,
            queue: DispatchQueue(label: "provider.backlog")
        )
    }

    /// Routes the opening hello, which is what puts the entry into the state where everything
    /// behind it is held.
    private static func routeHello(_ pending: inout PendingConnections, _ connection: LinkConnection) -> Bool {
        let hello = LinkMessage.clientHello(ClientHello(
            protocolVersion: LinkProtocol.version,
            role: .central,
            clientName: "backlog"
        ))
        guard case .handshake = pending.route(hello, from: connection) else { return false }
        return true
    }

    @Test("A backlog past the byte cap ends the connection rather than dropping the message")
    func byteCapEndsTheConnection() throws {
        var pending = PendingConnections()
        let connection = Self.connection()
        let registered = pending.register(connection, limit: 4)
        #expect(registered)
        let routed = Self.routeHello(&pending, connection)
        #expect(routed)

        // Far below the count cap, so only the byte cap can answer this.
        let message = Self.write(128 * 1024)
        let held = PendingConnections.maximumQueuedBytes / message.heldByteCount
        #expect(held < 256)
        for index in 0..<held {
            guard case .drop = pending.route(message, from: connection) else {
                Issue.record("message \(index) should have been held")
                return
            }
        }

        // The one that would put the entry past a megabyte takes the connection with it.
        guard case .exceededBacklog = pending.route(message, from: connection) else {
            Issue.record("the message past the cap should have ended the connection")
            return
        }
        // And nothing is left to serve: the backlog went with the decision, so a session that
        // somehow still installed would replay none of it.
        let remaining = pending.beginReplay({ _ in }, for: connection)
        #expect(remaining?.isEmpty == true)
    }

    @Test("A backlog past the message cap ends the connection rather than dropping the message")
    func messageCapEndsTheConnection() throws {
        var pending = PendingConnections()
        let connection = Self.connection()
        let registered = pending.register(connection, limit: 4)
        #expect(registered)
        let routed = Self.routeHello(&pending, connection)
        #expect(routed)

        // Tiny, so the byte cap is nowhere near: only the message cap can answer this.
        let message = Self.write(1)
        #expect(PendingConnections.maximumQueued * message.heldByteCount < PendingConnections.maximumQueuedBytes)
        for index in 0..<PendingConnections.maximumQueued {
            guard case .drop = pending.route(message, from: connection) else {
                Issue.record("message \(index) should have been held")
                return
            }
        }

        // The one past the cap takes the connection with it rather than being dropped in
        // silence, exactly as the byte cap does.
        guard case .exceededQueueDepth = pending.route(message, from: connection) else {
            Issue.record("the message past the cap should have ended the connection")
            return
        }
        let remaining = pending.beginReplay({ _ in }, for: connection)
        #expect(remaining?.isEmpty == true)
    }

    @Test("A backlog under the byte cap is held and replayed in order")
    func backlogUnderTheCapIsReplayed() throws {
        var pending = PendingConnections()
        let connection = Self.connection()
        let registered = pending.register(connection, limit: 4)
        #expect(registered)
        let routed = Self.routeHello(&pending, connection)
        #expect(routed)

        let messages = [Self.write(1), Self.write(2), Self.write(3)]
        for message in messages {
            guard case .drop = pending.route(message, from: connection) else {
                Issue.record("a message well under the cap should have been held")
                return
            }
        }
        let replayed = pending.beginReplay({ _ in }, for: connection)
        #expect(replayed == messages)
    }
}
#endif
