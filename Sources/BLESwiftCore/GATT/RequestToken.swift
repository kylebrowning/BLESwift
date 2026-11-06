//
//  RequestToken.swift
//  BLESwiftCore
//

import Foundation

/// An opaque handle that identifies one in-flight read or write request from a remote central. The
/// CoreBluetooth seam maps it back to the underlying `CBATTRequest` values, so the raw
/// `CBATTRequest` never crosses into BLESwift's own code.
public struct RequestToken: Sendable, Hashable {

    /// The token's underlying UUID.
    public let rawValue: UUID

    /// Creates a `RequestToken`.
    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}
