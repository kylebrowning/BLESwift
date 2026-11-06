//
//  HostMessages.swift
//  BLESwiftLink
//

import Foundation

/// A request that a `peripheral`-role client sends to the provider. The request controls a
/// remote `PeripheralHost`.
public enum HostRequest: Codable, Sendable, Equatable {

    /// Start to advertise `services`, and `localName` if it is present.
    case startAdvertising(localName: String?, services: [String])

    /// Stop the advertisement.
    case stopAdvertising

    /// Add `service` to the hosted GATT database.
    case addService(WireGATTService)

    /// Remove every hosted service.
    case removeAllServices

    /// Answer the read or write request that `token` identifies. `value` is the result of a
    /// successful read. `attError` is the result of a failure. A response can have both.
    case respond(token: UUID, value: Data?, attError: Int?)

    /// Push `value` for `characteristic` to `centrals`. If `centrals` is `nil`, push to every
    /// subscribed central. The request has a `sequence` tag. The client uses the tag to match an
    /// `updateValueDelivered` acknowledgement.
    case updateValue(sequence: UInt64, value: Data, characteristic: WireCharacteristicRef, centrals: [UUID]?)
}

/// An event that the provider sends to a `peripheral`-role client. The event reports activity
/// of a remote `PeripheralHost`.
public enum HostWireEvent: Codable, Sendable, Equatable {

    /// The Bluetooth state of the host changed.
    case didUpdateState(WireCentralState)

    /// The advertisement started. If it failed to start, the event gives `error`.
    case didStartAdvertising(error: WireError?)

    /// The host added `service` to the hosted GATT database. If it failed, the event gives
    /// `error`.
    case didAddService(service: String, error: WireError?)

    /// A remote central sent a read request.
    case didReceiveRead(WireReadRequest)

    /// A remote central sent a batch of write requests.
    case didReceiveWrite(WireWriteRequest)

    /// `central` subscribed to notifications for `characteristic`.
    case didSubscribe(central: WireSubscriber, characteristic: WireCharacteristicRef)

    /// `central` unsubscribed from notifications for `characteristic`.
    case didUnsubscribe(central: WireSubscriber, characteristic: WireCharacteristicRef)

    /// The host delivered the `updateValue` request that has the tag `sequence`.
    ///
    /// The client matches `sequence` against its outstanding pushes. It opens the window again
    /// only for a sequence that it recognizes. The client ignores a sequence if:
    ///
    /// - The client never sent the sequence.
    /// - The client already got an acknowledgement for the sequence.
    /// - The sequence belongs to a session that has since dropped.
    ///
    /// Thus a late or duplicated acknowledgement cannot open the *next* session's window too
    /// early.
    case updateValueDelivered(sequence: UInt64)
}
