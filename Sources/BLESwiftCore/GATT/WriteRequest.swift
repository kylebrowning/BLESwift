//
//  WriteRequest.swift
//  BLESwiftCore
//

import Foundation

/// A write request from a remote central for one or more characteristics that your `PeripheralHost`
/// hosts. It appears on `PeripheralHost/writeRequests()`.
///
/// CoreBluetooth delivers writes in a batch. A single
/// `PeripheralHost/respond(to:with:)-(WriteRequest,_)` call answers the batch. `.success` applies
/// every ``entries`` write. `.failure(ATTError)` rejects the whole batch.
public struct WriteRequest: Sendable, Hashable {

    /// One write in a batch.
    public struct Entry: Sendable, Hashable {

        /// The remote central that sent the write.
        public let central: Subscriber

        /// The characteristic that the central writes.
        public let characteristic: CharacteristicIdentifier

        /// The byte offset in the characteristic's value where the write begins. Mirrors
        /// `CBATTRequest.offset`.
        public let offset: Int

        /// The value to write.
        public let value: Data

        /// Creates a write `Entry`.
        public init(
            central: Subscriber,
            characteristic: CharacteristicIdentifier,
            offset: Int = 0,
            value: Data
        ) {
            self.central = central
            self.characteristic = characteristic
            self.offset = offset
            self.value = value
        }
    }

    /// The opaque token that maps this batch back to its `CBATTRequest` values at the CoreBluetooth
    /// seam. `PeripheralHost/respond(to:with:)-(WriteRequest,_)` passes it through.
    public let token: RequestToken

    /// The writes in this batch, in the order that CoreBluetooth delivered them. It is never empty.
    public let entries: [Entry]

    /// Creates a `WriteRequest`.
    public init(token: RequestToken, entries: [Entry]) {
        self.token = token
        self.entries = entries
    }
}
