//
//  RequestToken.swift
//  BLESwiftCore
//

import Foundation

/// An opaque handle identifying one in-flight read or write request from a remote central.
/// The CoreBluetooth seam maps it back to the underlying `CBATTRequest`(s), so the raw
/// `CBATTRequest` never crosses into BLESwift-owned code.
public struct RequestToken: Sendable, Hashable {

    /// The token's underlying value.
    public let rawValue: UUID

    /// Creates a `RequestToken`.
    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}
