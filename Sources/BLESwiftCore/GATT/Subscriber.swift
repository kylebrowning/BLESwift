//
//  Subscriber.swift
//  BLESwiftCore
//

import Foundation

/// A remote central that a hosted `PeripheralHost` communicates with: the peer that sent a read or
/// write request, or subscribed to a characteristic's notifications.
///
/// A `Sendable` value-type mirror of CoreBluetooth's `CBCentral`, which is not `Sendable` and which
/// tests cannot construct. It has only the two fields that BLESwift's peripheral role needs. The
/// `BLESwift` module's CoreBluetooth seam bridges `CBCentral` to this type.
public struct Subscriber: Sendable, Hashable {

    /// The remote central's identifier. It is stable for the duration of a connection. Mirrors
    /// `CBCentral.identifier`.
    public let id: UUID

    /// The maximum number of bytes that this central can receive in a single notification update.
    /// Mirrors `CBCentral.maximumUpdateValueLength`. Use it to split values into fragments that you
    /// push with `PeripheralHost/updateValue(_:for:onSubscribed:)`.
    public let maximumUpdateValueLength: Int

    /// Creates a `Subscriber`.
    public init(id: UUID, maximumUpdateValueLength: Int) {
        self.id = id
        self.maximumUpdateValueLength = maximumUpdateValueLength
    }
}
