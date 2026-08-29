//
//  TransportLoopbackTests.swift
//  BLESwiftLinkTests
//

import BLESwiftLink
import Dispatch
import Foundation
import Synchronization
import Testing

@Suite("Transport loopback")
struct TransportLoopbackTests {

    private func makeListener(codec: LinkCodec = .binaryPropertyList) async throws -> LinkListener {
        let listener = try LinkListener(endpoint: LinkEndpoint(host: "127.0.0.1", port: 0), codec: codec, queue: DispatchQueue(label: "listener"))
        try await listener.start()
        #expect(listener.port != 0)
        return listener
    }

    @Test("Client and server exchange messages in both directions")
    func exchange() async throws {
        let listener = try await makeListener()
        defer { listener.cancel() }
        let serverReceived = Mutex<[LinkMessage]>([])
        let serverSide = Mutex<LinkConnection?>(nil)
        listener.onConnection = { connection in
            serverSide.withLock { $0 = connection }
            connection.onMessage = { message in
                serverReceived.withLock { $0.append(message) }
                connection.send(.serverHello(ServerHello(protocolVersion: 1, accepted: true, reason: nil, providerName: "t")))
            }
        }

        let clientReceived = Mutex<[LinkMessage]>([])
        let client = LinkConnection.connect(to: LinkEndpoint(host: "127.0.0.1", port: listener.port), codec: .json, queue: DispatchQueue(label: "client"))
        client.onMessage = { message in clientReceived.withLock { $0.append(message) } }
        client.start()
        await waitFor { if case .ready = client.state { return true }; return false }

        client.send(.clientHello(ClientHello(protocolVersion: 1, role: .central, clientName: "c")))
        await waitFor { clientReceived.withLock { $0.count } == 1 }

        #expect(serverReceived.withLock { $0 } == [.clientHello(ClientHello(protocolVersion: 1, role: .central, clientName: "c"))])
        #expect(clientReceived.withLock { $0 } == [.serverHello(ServerHello(protocolVersion: 1, accepted: true, reason: nil, providerName: "t"))])
        client.cancel()
    }

    @Test("Mixed codecs on one connection decode per frame")
    func mixedCodecs() async throws {
        let listener = try await makeListener(codec: .json)      // server encodes JSON
        defer { listener.cancel() }
        let echoed = Mutex<[LinkMessage]>([])
        listener.onConnection = { connection in
            connection.onMessage = { connection.send($0) }
        }
        let client = LinkConnection.connect(to: LinkEndpoint(host: "127.0.0.1", port: listener.port), codec: .binaryPropertyList, queue: DispatchQueue(label: "client"))
        client.onMessage = { message in echoed.withLock { $0.append(message) } }
        client.start()
        await waitFor { if case .ready = client.state { return true }; return false }
        let big = LinkMessage.centralRequest(.l2capData(channel: 1, data: Data(repeating: 0x5A, count: 300_000)))
        client.send(.centralRequest(.stopScan))
        client.send(big)
        await waitFor(timeout: .seconds(5)) { echoed.withLock { $0.count } == 2 }
        #expect(echoed.withLock { $0 } == [.centralRequest(.stopScan), big])
        client.cancel()
    }

    @Test("Server cancel is observed by the client as a state change")
    func serverClose() async throws {
        let listener = try await makeListener()
        let server = Mutex<LinkConnection?>(nil)
        listener.onConnection = { connection in server.withLock { $0 = connection } }
        let states = Mutex<[String]>([])
        let client = LinkConnection.connect(to: LinkEndpoint(host: "127.0.0.1", port: listener.port), codec: .json, queue: DispatchQueue(label: "client"))
        client.onStateChange = { state in states.withLock { $0.append(String(describing: state)) } }
        client.start()
        await waitFor { server.withLock { $0 } != nil }
        server.withLock { $0 }?.cancel()
        await waitFor { client.state.isTerminal }
        #expect(client.state.isTerminal)
        listener.cancel()
    }

    @Test("Connecting to a closed port fails")
    func refused() async {
        let client = LinkConnection.connect(to: LinkEndpoint(host: "127.0.0.1", port: 1), codec: .json, queue: DispatchQueue(label: "client"))
        client.start()
        await waitFor(timeout: .seconds(5)) { client.state.isTerminal }
        if case .failed = client.state {} else { Issue.record("expected .failed, got \(client.state)") }
    }

    @Test("Handlers are invoked on the connection's queue")
    func handlersRunOnQueue() async throws {
        let listener = try await makeListener()
        defer { listener.cancel() }
        listener.onConnection = { connection in
            connection.onMessage = { connection.send($0) }
        }

        let key = DispatchSpecificKey<Bool>()
        let queue = DispatchQueue(label: "client")
        queue.setSpecific(key: key, value: true)
        let stateChangesOnQueue = Mutex<[Bool]>([])
        let messagesOnQueue = Mutex<[Bool]>([])

        let client = LinkConnection.connect(to: LinkEndpoint(host: "127.0.0.1", port: listener.port), codec: .json, queue: queue)
        client.onStateChange = { _ in
            stateChangesOnQueue.withLock { $0.append(DispatchQueue.getSpecific(key: key) == true) }
        }
        client.onMessage = { _ in
            messagesOnQueue.withLock { $0.append(DispatchQueue.getSpecific(key: key) == true) }
        }
        client.start()                                   // publishes .connecting synchronously
        await waitFor { if case .ready = client.state { return true }; return false }
        client.send(.centralRequest(.stopScan))
        await waitFor { messagesOnQueue.withLock { $0.count } == 1 }
        client.cancel()                                  // publishes .cancelled synchronously
        await waitFor { stateChangesOnQueue.withLock { $0.count } >= 3 }

        #expect(stateChangesOnQueue.withLock { $0.count } >= 3)   // .connecting, .ready, .cancelled
        #expect(stateChangesOnQueue.withLock { $0 }.allSatisfy { $0 })
        #expect(messagesOnQueue.withLock { $0 } == [true])
    }

    @Test("Sends are delivered in call order")
    func sendOrdering() async throws {
        let listener = try await makeListener()
        defer { listener.cancel() }
        let channels = Mutex<[UInt32]>([])
        // The listener does not retain accepted connections — the caller owns them.
        let serverSide = Mutex<LinkConnection?>(nil)
        listener.onConnection = { connection in
            serverSide.withLock { $0 = connection }
            connection.onMessage = { message in
                if case .centralRequest(.l2capData(let channel, _)) = message {
                    channels.withLock { $0.append(channel) }
                }
            }
        }
        let client = LinkConnection.connect(to: LinkEndpoint(host: "127.0.0.1", port: listener.port), codec: .binaryPropertyList, queue: DispatchQueue(label: "client"))
        client.start()
        await waitFor { if case .ready = client.state { return true }; return false }

        let sender = DispatchQueue(label: "sender")
        for index in 0 ..< 200 {
            sender.async {
                client.send(.centralRequest(.l2capData(channel: UInt32(index), data: Data([UInt8(index & 0xFF)]))))
            }
        }
        await waitFor(timeout: .seconds(5)) { channels.withLock { $0.count } == 200 }
        #expect(channels.withLock { $0 } == (0 ..< 200).map(UInt32.init))
        client.cancel()
        serverSide.withLock { $0 }?.cancel()
    }

    @Test("Starting a listener on a port already in use throws")
    func portInUse() async throws {
        let first = try await makeListener()
        defer { first.cancel() }
        let second = try LinkListener(endpoint: LinkEndpoint(host: "127.0.0.1", port: first.port), codec: .json, queue: DispatchQueue(label: "listener-2"))
        await #expect(throws: (any Error).self) { try await second.start() }
        second.cancel()
    }

    @Test("Starting a listener twice throws")
    func doubleStart() async throws {
        let listener = try await makeListener()
        defer { listener.cancel() }
        await #expect(throws: LinkListenerError.alreadyStarted) { try await listener.start() }
    }
}

extension LinkConnection.State {
    var isTerminal: Bool {
        switch self {
        case .failed, .cancelled: return true
        default: return false
        }
    }
}
