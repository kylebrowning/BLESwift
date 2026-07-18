//
//  RequestToken.swift
//  BLESwiftCore
//

import Foundation

/// An opaque handle identifying one in-flight read or write request from a remote central.
///
/// The peripheral role surfaces requests as `Sendable` value types
/// (``ReadRequest``/``WriteRequest``), each carrying one of these tokens. Answer a request
/// by passing its originating value back to `PeripheralHost/respond(to:with:)-(ReadRequest,_)`
/// / `PeripheralHost/respond(to:with:)-(WriteRequest,_)`; the CoreBluetooth seam maps the
/// token back to the underlying `CBATTRequest`(s) it minted the token for, so the raw
/// `CBATTRequest` never crosses into BLESwift-owned code.
public struct RequestToken: Sendable, Hashable {

    /// The token's underlying value.
    public let rawValue: UUID

    /// Creates a `RequestToken`.
    ///
    /// - Parameter rawValue: The token's underlying value. Defaults to a fresh `UUID`.
    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}
