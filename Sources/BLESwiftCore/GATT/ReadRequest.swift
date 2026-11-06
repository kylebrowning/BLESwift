//
//  ReadRequest.swift
//  BLESwiftCore
//

import Foundation

/// A read request from a remote central for a characteristic that your `PeripheralHost` hosts. It
/// appears on `PeripheralHost/readRequests()`.
///
/// To answer it, pass this value back to `PeripheralHost/respond(to:with:)-(ReadRequest,_)` with
/// the requested `Data` (`.success`) or an ``ATTError`` (`.failure`). You must answer every read
/// request exactly once. This is a `Sendable` value type. The CoreBluetooth side holds the
/// underlying `CBATTRequest`, keyed by ``token``.
public struct ReadRequest: Sendable, Hashable {

    /// The opaque token that maps this request back to its `CBATTRequest` at the CoreBluetooth
    /// seam. `PeripheralHost/respond(to:with:)-(ReadRequest,_)` passes it through.
    public let token: RequestToken

    /// The remote central that sent the request.
    public let central: Subscriber

    /// The characteristic that the central reads.
    public let characteristic: CharacteristicIdentifier

    /// The byte offset in the characteristic's value where the read begins. It is not zero for a
    /// Read Blob request. Mirrors `CBATTRequest.offset`.
    public let offset: Int

    /// Creates a `ReadRequest`.
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
