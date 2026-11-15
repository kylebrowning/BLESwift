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

    /// The provider's state, for a ``LinkRole/monitor`` client.
    case providerStatus(ProviderStatus)
}

extension LinkMessage {

    /// The maximum number of characters in ``trafficSummary`` before the ellipsis.
    static let trafficSummaryLimit = 240

    /// A short description of this message for a traffic log.
    ///
    /// The value is `String(describing:)` of the message. If that has more than 240 characters,
    /// the value keeps the first 240 and adds "…". A `Data` value describes itself as its byte
    /// count, so no payload bytes reach the log.
    public var trafficSummary: String {
        let description = String(describing: self)
        guard description.count > Self.trafficSummaryLimit else { return description }
        return String(description.prefix(Self.trafficSummaryLimit)) + "…"
    }
}
