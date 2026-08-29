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

    /// Parses `"host:port"`, or `"[host]:port"` for an IPv6 address. Returns `nil` for
    /// anything else.
    ///
    /// The brackets are what make the split unambiguous: an IPv6 address is itself full of
    /// colons, so `"::1:45541"` could be read either way. A bracketed host is stored without
    /// its brackets — ``host`` is what a socket API is handed — and ``description`` puts them
    /// back, so the two round-trip.
    public init?(string: String) {
        if string.hasPrefix("["), let close = string.firstIndex(of: "]") {
            let host = String(string[string.index(after: string.startIndex)..<close])
            let remainder = string[string.index(after: close)...]
            guard !host.isEmpty, remainder.hasPrefix(":"), let port = UInt16(remainder.dropFirst()) else {
                return nil
            }
            self.init(host: host, port: port)
            return
        }
        guard let colon = string.lastIndex(of: ":") else { return nil }
        let host = String(string[..<colon])
        guard !host.isEmpty, let port = UInt16(string[string.index(after: colon)...]) else { return nil }
        self.init(host: host, port: port)
    }

    /// The endpoint named by `BLESWIFT_LINK`, if set and well-formed.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> LinkEndpoint? {
        environment[environmentKey].flatMap(LinkEndpoint.init(string:))
    }

    /// Whether ``host`` names the loopback interface — `localhost`, any address in
    /// `127.0.0.0/8`, or the IPv6 loopback `::1` (bracketed or not).
    ///
    /// The link is **unauthenticated**: anything that can open a TCP connection to a provider
    /// is served, with the Mac's Bluetooth radio behind it when `--passthrough` is on. It is
    /// meant for loopback, and a listener bound anywhere else is exposing that to the network.
    /// A ``LinkListener`` binds loopback-only exactly when this is `true`.
    public var isLoopback: Bool { LinkTransportParameters.isLoopback(host) }

    /// `"host:port"` — or `"[host]:port"` when ``host`` is an IPv6 address, so that what this
    /// prints is what ``init(string:)`` reads back.
    public var description: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}
