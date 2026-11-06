//
//  LinkProtocol.swift
//  BLESwiftLink
//

import Foundation

/// Constants for the whole wire protocol.
public enum LinkProtocol {
    /// The protocol version of this build. Increase it for each incompatible message change.
    public static let version = 1
}

/// Flow-control windows that both ends of the link share.
public enum LinkFlowControl {
    /// The number of unacknowledged `.withoutResponse` writes that a client can have in flight
    /// for each peripheral.
    public static let writeWithoutResponseWindow = 64
    /// The number of unacknowledged `updateValue` notifications that a client can have in flight
    /// for each host.
    public static let updateValueWindow = 32
    /// The number of bytes that each direction of an L2CAP channel can send before it waits for
    /// credit.
    public static let l2capInitialCredit = 262_144
}

/// Link-level failures that BLESwift receives as `NSError` values (domain ``LinkError/domain``).
public enum LinkError: Error, Equatable, Sendable {
    /// The provider connection dropped while sessions were live.
    case providerDisconnected
    /// The provider refused the handshake.
    case handshakeRejected(reason: String)
    /// The provider uses a different ``LinkProtocol/version``.
    case protocolVersionMismatch(remote: Int)

    /// The `NSError` domain for every ``LinkError``.
    public static let domain = "BLESwiftLink"

    /// The `NSError` code for this case.
    public var code: Int {
        switch self {
        case .providerDisconnected: return 1
        case .handshakeRejected: return 2
        case .protocolVersionMismatch: return 3
        }
    }

    /// This error as an `NSError`. Use it as the payload of a backend event.
    public var nsError: NSError {
        NSError(domain: Self.domain, code: code, userInfo: [NSLocalizedDescriptionKey: String(describing: self)])
    }
}
