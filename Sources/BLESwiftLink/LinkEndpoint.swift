//
//  LinkEndpoint.swift
//  BLESwiftLink
//

import Foundation

/// Where a provider listens: a host and TCP port.
public struct LinkEndpoint: Sendable, Hashable, Codable, CustomStringConvertible {

    /// The environment variable both the client and the provider honor.
    public static let environmentKey = "BLESWIFT_LINK"

    /// `127.0.0.1:45541`.
    public static let `default` = LinkEndpoint(host: "127.0.0.1", port: 45541)

    /// The hostname or IP address to connect to.
    public var host: String
    /// The TCP port to connect to.
    public var port: UInt16

    /// Creates an endpoint from a host and port.
    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// Parses `"host:port"`. Returns `nil` for anything else.
    public init?(string: String) {
        guard let colon = string.lastIndex(of: ":") else { return nil }
        let host = String(string[..<colon])
        guard !host.isEmpty, let port = UInt16(string[string.index(after: colon)...]) else { return nil }
        self.init(host: host, port: port)
    }

    /// The endpoint named by `BLESWIFT_LINK`, if set and well-formed.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> LinkEndpoint? {
        environment[environmentKey].flatMap(LinkEndpoint.init(string:))
    }

    /// Whether ``host`` names the loopback interface — `127.0.0.1` or `localhost`.
    ///
    /// The link is **unauthenticated**: anything that can open a TCP connection to a provider
    /// is served, with the Mac's Bluetooth radio behind it when `--passthrough` is on. It is
    /// meant for loopback, and a listener bound anywhere else is exposing that to the network.
    /// A ``LinkListener`` binds loopback-only exactly when this is `true`.
    public var isLoopback: Bool { LinkTransportParameters.isLoopback(host) }

    /// `"host:port"`.
    public var description: String { "\(host):\(port)" }
}
