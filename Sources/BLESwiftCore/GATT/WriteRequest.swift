//
//  WriteRequest.swift
//  BLESwiftCore
//

import Foundation

/// A write request from a remote central for one or more characteristics your
/// `PeripheralHost` hosts, surfaced on `PeripheralHost/writeRequests()`.
///
/// CoreBluetooth delivers writes in a batch, answered by a single
/// `PeripheralHost/respond(to:with:)-(WriteRequest,_)` call: `.success` applies every
/// ``entries`` write; `.failure(ATTError)` rejects the whole batch.
public struct WriteRequest: Sendable, Hashable {

    /// One write within a batch.
    public struct Entry: Sendable, Hashable {

        /// The remote central that issued the write.
        public let central: Subscriber

        /// The characteristic being written.
        public let characteristic: CharacteristicIdentifier

        /// The byte offset into the characteristic's value at which to begin writing.
        /// Mirrors `CBATTRequest.offset`.
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

    /// The opaque token mapping this batch back to its underlying `CBATTRequest`(s) at the
    /// CoreBluetooth seam. Carried through to `PeripheralHost/respond(to:with:)-(WriteRequest,_)`.
    public let token: RequestToken

    /// The writes in this batch, in the order CoreBluetooth delivered them. Never empty.
    public let entries: [Entry]

    /// Creates a `WriteRequest`.
    public init(token: RequestToken, entries: [Entry]) {
        self.token = token
        self.entries = entries
    }
}
