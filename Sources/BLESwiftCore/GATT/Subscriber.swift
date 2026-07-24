//
//  Subscriber.swift
//  BLESwiftCore
//

import Foundation

/// A remote central that a hosted `PeripheralHost` is talking to — the peer that issued a
/// read/write request, or that subscribed to a characteristic's notifications.
///
/// A `Sendable`, value-type mirror of CoreBluetooth's `CBCentral` (which is neither
/// `Sendable` nor constructible in tests), carrying only the two fields BLESwift's
/// peripheral role needs. The `CBCentral` bridge lives in the `BLESwift` module's
/// CoreBluetooth seam.
public struct Subscriber: Sendable, Hashable {

    /// The remote central's identifier, stable for the duration of a connection. Mirrors
    /// `CBCentral.identifier`.
    public let id: UUID

    /// The maximum number of bytes this central can receive in a single notification
    /// update. Mirrors `CBCentral.maximumUpdateValueLength` — use it to fragment values
    /// pushed via `PeripheralHost/updateValue(_:for:onSubscribed:)`.
    public let maximumUpdateValueLength: Int

    /// Creates a `Subscriber`.
    public init(id: UUID, maximumUpdateValueLength: Int) {
        self.id = id
        self.maximumUpdateValueLength = maximumUpdateValueLength
    }
}
