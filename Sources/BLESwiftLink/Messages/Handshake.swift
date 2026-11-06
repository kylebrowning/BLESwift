//
//  Handshake.swift
//  BLESwiftLink
//

import Foundation

/// The side of the link that a client identifies as during the handshake.
public enum LinkRole: String, Codable, Sendable, CaseIterable {
    /// The client uses `CentralRequest` and `CentralWireEvent`. It controls a remote
    /// `Central`.
    case central
    /// The client uses `HostRequest` and `HostWireEvent`. It controls a remote
    /// `PeripheralHost`.
    case peripheral
}

/// The first message that a client sends after it connects. It identifies the client to the
/// provider.
public struct ClientHello: Codable, Sendable, Equatable {

    /// The wire protocol version that this client uses.
    public var protocolVersion: Int

    /// The side of the link that this client wants to control.
    public var role: LinkRole

    /// A name for this client that people can read. The provider uses it for logs.
    public var clientName: String

    /// The identity that a `.peripheral` client wants for the device that the provider hosts for
    /// it. A reconnect then appears as the *same* device to every central that saw it before.
    ///
    /// A `LinkPeripheralManager` creates one identity for each instance and sends it in every
    /// hello, including each reconnect's hello. A central-role client sends `nil`. In that case
    /// the provider creates a new identifier for the session.
    ///
    /// The field is optional, so a hello that was encoded without the key still decodes.
    public var hostIdentifier: UUID?

    /// Creates a `ClientHello`.
    ///
    /// - Parameters:
    ///   - protocolVersion: The wire protocol version that this client uses.
    ///   - role: The side of the link that this client wants to control.
    ///   - clientName: A name that people can read. The provider uses it for logs.
    ///   - hostIdentifier: The identity under which the provider hosts a `.peripheral` client's
    ///     device. The default is `nil`, which lets the provider create one.
    public init(protocolVersion: Int, role: LinkRole, clientName: String, hostIdentifier: UUID? = nil) {
        self.protocolVersion = protocolVersion
        self.role = role
        self.clientName = clientName
        self.hostIdentifier = hostIdentifier
    }
}

/// The provider's reply to a `ClientHello`. It accepts or rejects the connection.
public struct ServerHello: Codable, Sendable, Equatable {

    /// The wire protocol version that the provider uses.
    public var protocolVersion: Int

    /// Whether the provider accepted this client's handshake.
    public var accepted: Bool

    /// If `accepted` is `false`, an explanation that people can read. An example is a protocol
    /// version mismatch.
    public var reason: String?

    /// A name for the provider that people can read. The client uses it for logs.
    public var providerName: String

    /// The identity under which the provider actually hosted a `.peripheral` client's device.
    ///
    /// Normally this is the `ClientHello.hostIdentifier` that the client asked for. It differs
    /// if the provider refused that identifier because one of its *own* devices already uses it.
    /// The provider then creates a new identifier. The client cannot find this out alone, so this
    /// field lets it report the problem. Otherwise its reconnects keep asking for an identity
    /// that does not host it, and every central keeps seeing a different device.
    ///
    /// The value is `nil` in these cases:
    ///
    /// - The handshake was rejected.
    /// - The client is a `.central` client, because it hosts nothing.
    /// - The provider is older than this field.
    ///
    /// The field is optional, so a hello that was encoded without the key still decodes.
    public var assignedHostIdentifier: UUID?

    /// Creates a `ServerHello`.
    ///
    /// - Parameters:
    ///   - protocolVersion: The wire protocol version that the provider uses.
    ///   - accepted: Whether the provider accepted this client's handshake.
    ///   - reason: An explanation of a refusal that people can read.
    ///   - providerName: A name for the provider that people can read.
    ///   - assignedHostIdentifier: The identity under which the provider hosted a `.peripheral`
    ///     client's device. The default is `nil`, which every other case sends.
    public init(
        protocolVersion: Int,
        accepted: Bool,
        reason: String?,
        providerName: String,
        assignedHostIdentifier: UUID? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.accepted = accepted
        self.reason = reason
        self.providerName = providerName
        self.assignedHostIdentifier = assignedHostIdentifier
    }
}
