//
//  LinkEndpoint.swift
//  BLESwiftLink
//

import Foundation

/// The place where a provider listens: a host and a TCP port.
///
/// **The endpoint changes `localhost` to `127.0.0.1`.** The name `localhost` resolves to both
/// loopback families, so the two ends could pick different families. A client that dials `::1`
/// cannot reach a listener on the IPv4 loopback, and the connect fails with no explanation. The
/// endpoint stores the literal address, so both ends use the same address. Thus ``host`` can
/// differ from the string that you gave to the endpoint.
public struct LinkEndpoint: Sendable, Hashable, Codable, CustomStringConvertible {

    /// The environment variable that the client and the provider both read.
    public static let environmentKey = "BLESWIFT_LINK"

    /// `127.0.0.1:45541`.
    public static let `default` = LinkEndpoint(host: "127.0.0.1", port: 45541)

    /// The hostname or IP address to connect to. The endpoint stores `localhost` as
    /// `127.0.0.1`.
    public var host: String {
        get { _host }
        set { _host = Self.normalized(newValue) }
    }

    /// The stored value of ``host``. It is always normalized.
    private var _host: String
    /// The TCP port to connect to.
    public var port: UInt16

    /// Creates an endpoint from a host and port.
    ///
    /// - Parameters:
    ///   - host: The hostname or IP address. `localhost` becomes `127.0.0.1`. Thus a listener
    ///     and a client that get the same string bind and dial the same address.
    ///   - port: The TCP port.
    public init(host: String, port: UInt16) {
        self._host = Self.normalized(host)
        self.port = port
    }

    /// Returns `host`, with the IPv4 loopback literal in place of `localhost`. The match ignores
    /// case. Every other host stays the same.
    private static func normalized(_ host: String) -> String {
        host.lowercased() == "localhost" ? "127.0.0.1" : host
    }

    /// Parses `"host:port"`, or `"[host]:port"` for an IPv6 address. Returns `nil` for
    /// any other string.
    ///
    /// The brackets make the split clear, because an IPv6 address has many colons. The endpoint
    /// stores a bracketed host without its brackets, because a socket API needs that form.
    /// ``description`` adds the brackets again, so the two operations reverse each other.
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

    /// Keeps the encoded shape `{"host": …, "port": …}`. ``host`` is a computed property over a
    /// private stored property.
    private enum CodingKeys: String, CodingKey {
        case _host = "host"
        case port
    }

    /// Decodes an endpoint. This initializer normalizes the decoded host in the same way as
    /// ``init(host:port:)``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._host = Self.normalized(try container.decode(String.self, forKey: ._host))
        self.port = try container.decode(UInt16.self, forKey: .port)
    }

    /// The endpoint that `BLESWIFT_LINK` names, or `nil` if the variable is not set or is not
    /// well-formed.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> LinkEndpoint? {
        environment[environmentKey].flatMap(LinkEndpoint.init(string:))
    }

    /// Whether ``host`` names the loopback interface. The loopback interface is one of these:
    ///
    /// - `localhost`
    /// - any address in `127.0.0.0/8`
    /// - the IPv6 loopback `::1`, with or without brackets
    ///
    /// The link is **unauthenticated**. The provider serves anything that can open a TCP
    /// connection to it. If `--passthrough` is on, the Mac's Bluetooth radio is behind that
    /// connection. A listener on any other address exposes the radio to the network. A
    /// ``LinkListener`` binds to loopback only when this value is `true`.
    public var isLoopback: Bool { LinkTransportParameters.isLoopback(host) }

    /// `"host:port"`, or `"[host]:port"` when ``host`` is an IPv6 address. ``init(string:)`` reads
    /// this text back.
    public var description: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}
