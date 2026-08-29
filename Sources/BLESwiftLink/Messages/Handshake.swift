//
//  Handshake.swift
//  BLESwiftLink
//

import Foundation

/// Which side of the link a client identifies itself as during the handshake.
public enum LinkRole: String, Codable, Sendable, CaseIterable {
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

    /// The identity a `.peripheral` client wants the device the provider hosts for it to
    /// carry, so a reconnect is the *same* device to every central that had seen it.
    ///
    /// A `LinkPeripheralManager` mints one of these per instance and sends it on every hello,
    /// including the ones its reconnects send. `nil` — which is what a client that predates
    /// the field, or one in the central role, sends — leaves the provider to mint a fresh
    /// identifier for the session, as it always did. Optional, so a hello encoded without the
    /// key still decodes.
    public var hostIdentifier: UUID?

    /// Creates a `ClientHello`.
    ///
    /// - Parameters:
    ///   - protocolVersion: The wire protocol version this client speaks.
    ///   - role: Which side of the link this client wants to drive.
    ///   - clientName: A human-readable name, for provider-side logging.
    ///   - hostIdentifier: The identity to host a `.peripheral` client's device under.
    ///     Defaults to `nil`, which lets the provider mint one.
    public init(protocolVersion: Int, role: LinkRole, clientName: String, hostIdentifier: UUID? = nil) {
        self.protocolVersion = protocolVersion
        self.role = role
        self.clientName = clientName
        self.hostIdentifier = hostIdentifier
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
