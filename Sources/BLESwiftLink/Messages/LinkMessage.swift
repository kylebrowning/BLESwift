//
//  LinkMessage.swift
//  BLESwiftLink
//

/// The envelope for every message that crosses a `LinkEndpoint`, encoded by a `LinkCodec`
/// and carried inside a framed payload.
public enum LinkMessage: Codable, Sendable, Equatable {

    /// A client's handshake greeting.
    case clientHello(ClientHello)

    /// The provider's handshake reply.
    case serverHello(ServerHello)

    /// A `Central`-role request from client to provider.
    case centralRequest(CentralRequest)

    /// A `Central`-role event from provider to client.
    case centralEvent(CentralWireEvent)

    /// A `peripheral`-role request from client to provider.
    case hostRequest(HostRequest)

    /// A `peripheral`-role event from provider to client.
    case hostEvent(HostWireEvent)
}
