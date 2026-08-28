//
//  Handshake.swift
//  BLESwiftLink
//

/// Which side of the link a client identifies itself as during the handshake.
public enum LinkRole: String, Codable, Sendable {
    /// The client speaks `CentralRequest`/`CentralWireEvent` — it drives a remote
    /// `Central`.
    case central
    /// The client speaks `HostRequest`/`HostWireEvent` — it drives a remote
    /// `PeripheralHost`.
    case peripheral
}

/// The first message a client sends after connecting, identifying itself to the provider.
public struct ClientHello: Codable, Sendable, Equatable {

    /// The wire protocol version this client speaks.
    public var protocolVersion: Int

    /// Which side of the link this client wants to drive.
    public var role: LinkRole

    /// A human-readable name for this client, for logging on the provider side.
    public var clientName: String

    /// Creates a `ClientHello`.
    public init(protocolVersion: Int, role: LinkRole, clientName: String) {
        self.protocolVersion = protocolVersion
        self.role = role
        self.clientName = clientName
    }
}

/// The provider's reply to a `ClientHello`, accepting or rejecting the connection.
public struct ServerHello: Codable, Sendable, Equatable {

    /// The wire protocol version the provider speaks.
    public var protocolVersion: Int

    /// Whether the provider accepted this client's handshake.
    public var accepted: Bool

    /// When `accepted` is `false`, a human-readable explanation (e.g. a protocol version
    /// mismatch).
    public var reason: String?

    /// A human-readable name for the provider, for logging on the client side.
    public var providerName: String

    /// Creates a `ServerHello`.
    public init(protocolVersion: Int, accepted: Bool, reason: String?, providerName: String) {
        self.protocolVersion = protocolVersion
        self.accepted = accepted
        self.reason = reason
        self.providerName = providerName
    }
}
