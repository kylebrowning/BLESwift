//
//  ReadRequest.swift
//  BLESwiftCore
//

import Foundation

/// A read request from a remote central for a characteristic your `PeripheralHost` hosts,
/// surfaced on `PeripheralHost/readRequests()`.
///
/// Answer it by passing this value back to
/// `PeripheralHost/respond(to:with:)-(ReadRequest,_)` with either the requested `Data`
/// (`.success`) or an ``ATTError`` (`.failure`). Every read request must be answered exactly
/// once. A `Sendable` value type — the underlying `CBATTRequest` is held on the
/// CoreBluetooth side, keyed by ``token``.
public struct ReadRequest: Sendable, Hashable {

    /// The opaque token mapping this request back to its underlying `CBATTRequest` at the
    /// CoreBluetooth seam. Carried through to `PeripheralHost/respond(to:with:)-(ReadRequest,_)`.
    public let token: RequestToken

    /// The remote central that issued the request.
    public let central: Subscriber

    /// The characteristic being read.
    public let characteristic: CharacteristicIdentifier

    /// The byte offset into the characteristic's value at which the read should begin
    /// (non-zero for a Read Blob request). Mirrors `CBATTRequest.offset`.
    public let offset: Int

    /// Creates a `ReadRequest`.
    ///
    /// - Parameters:
    ///   - token: The token mapping this request back to CoreBluetooth.
    ///   - central: The remote central that issued the request.
    ///   - characteristic: The characteristic being read.
    ///   - offset: The byte offset the read begins at. Defaults to `0`.
    public init(
        token: RequestToken,
        central: Subscriber,
        characteristic: CharacteristicIdentifier,
        offset: Int = 0
    ) {
        self.token = token
        self.central = central
        self.characteristic = characteristic
        self.offset = offset
    }
}
