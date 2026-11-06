//
//  LinkMessage.swift
//  BLESwiftLink
//

/// The envelope for every message that crosses a `LinkEndpoint`. A `LinkCodec` encodes the
/// message. A framed payload carries it.
public enum LinkMessage: Codable, Sendable, Equatable {

    /// A client's handshake greeting.
    case clientHello(ClientHello)

    /// The provider's handshake reply.
    case serverHello(ServerHello)

    /// A `Central`-role request from the client to the provider.
    case centralRequest(CentralRequest)

    /// A `Central`-role event from the provider to the client.
    case centralEvent(CentralWireEvent)

    /// A `peripheral`-role request from the client to the provider.
    case hostRequest(HostRequest)

    /// A `peripheral`-role event from the provider to the client.
    case hostEvent(HostWireEvent)
}
