//
//  LinkProtocol.swift
//  BLESwiftLink
//

import Foundation

/// Wire-protocol-wide constants.
public enum LinkProtocol {
    /// The protocol version this build speaks. Bumped on any incompatible message change.
    public static let version = 1
}

/// Flow-control windows shared by both ends of the link.
public enum LinkFlowControl {
    /// Unacknowledged `.withoutResponse` writes a client may have in flight per peripheral.
    public static let writeWithoutResponseWindow = 64
    /// Unacknowledged `updateValue` notifications a client may have in flight per host.
    public static let updateValueWindow = 32
    /// Bytes each direction of an L2CAP channel may send before waiting for credit.
    public static let l2capInitialCredit = 262_144
}

/// Link-level failures surfaced to BLESwift as `NSError`s (domain ``LinkError/domain``).
public enum LinkError: Error, Equatable, Sendable {
    /// The provider connection dropped while sessions were live.
    case providerDisconnected
    /// The provider refused the handshake.
    case handshakeRejected(reason: String)
    /// The provider speaks a different ``LinkProtocol/version``.
    case protocolVersionMismatch(remote: Int)

    public static let domain = "BLESwiftLink"

    /// The `NSError` code used for this case.
    public var code: Int {
        switch self {
        case .providerDisconnected: return 1
        case .handshakeRejected: return 2
        case .protocolVersionMismatch: return 3
        }
    }

    /// This error as an `NSError` suitable for a backend event payload.
    public var nsError: NSError {
        NSError(domain: Self.domain, code: code, userInfo: [NSLocalizedDescriptionKey: String(describing: self)])
    }
}
