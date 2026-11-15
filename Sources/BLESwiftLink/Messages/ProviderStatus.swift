//
//  ProviderStatus.swift
//  BLESwiftLink
//

/// A snapshot of a provider's state. The provider sends it to a ``LinkRole/monitor`` client in a
/// ``LinkMessage/providerStatus(_:)`` message.
public struct ProviderStatus: Codable, Sendable, Equatable {

    /// One live session of the provider.
    public struct Session: Codable, Sendable, Equatable {

        /// The number that the provider gave the session when it opened. The session log lines
        /// of the provider use the same number.
        ///
        /// This is not the connection number `N` in a `link N` line of the traffic log. When the
        /// traffic log is on, a line `link N is <role> session M` connects the two numbers.
        public var ordinal: Int

        /// The role that the client stated in its ``ClientHello``.
        public var role: LinkRole

        /// The name that the client stated in its ``ClientHello``.
        public var clientName: String

        /// Creates a session entry.
        public init(ordinal: Int, role: LinkRole, clientName: String) {
            self.ordinal = ordinal
            self.role = role
            self.clientName = clientName
        }
    }

    /// The name that the provider reports in its ``ServerHello``.
    public var providerName: String

    /// Whether the provider also serves the host machine's real CoreBluetooth.
    public var passthrough: Bool

    /// The number of fixture devices that the provider hosts.
    public var fixtureDeviceCount: Int

    /// The live sessions, sorted by ``Session/ordinal``.
    public var sessions: [Session]

    /// Creates a snapshot.
    public init(providerName: String, passthrough: Bool, fixtureDeviceCount: Int, sessions: [Session]) {
        self.providerName = providerName
        self.passthrough = passthrough
        self.fixtureDeviceCount = fixtureDeviceCount
        self.sessions = sessions
    }
}
