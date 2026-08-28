//
//  HostMessages.swift
//  BLESwiftLink
//

import Foundation

/// A request sent from a `peripheral`-role client to the provider, driving a remote
/// `PeripheralHost`.
public enum HostRequest: Codable, Sendable, Equatable {

    /// Start advertising `localName` (if any) and `services`.
    case startAdvertising(localName: String?, services: [String])

    /// Stop advertising.
    case stopAdvertising

    /// Add `service` to the hosted GATT database.
    case addService(WireGATTService)

    /// Remove every hosted service.
    case removeAllServices

    /// Answer the read or write request identified by `token`, with `value` (for a
    /// successful read) and/or `attError` (for a failure).
    case respond(token: UUID, value: Data?, attError: Int?)

    /// Push `value` for `characteristic` to `centrals` (or every subscribed central, if
    /// `nil`), tagged with `sequence` for correlating an `updateValueDelivered`
    /// acknowledgement.
    case updateValue(sequence: UInt64, value: Data, characteristic: WireCharacteristicRef, centrals: [UUID]?)
}

/// An event sent from the provider to a `peripheral`-role client, reporting activity from
/// a remote `PeripheralHost`.
public enum HostWireEvent: Codable, Sendable, Equatable {

    /// The host's Bluetooth state changed.
    case didUpdateState(WireCentralState)

    /// Advertising started (or failed to start with `error`).
    case didStartAdvertising(error: WireError?)

    /// `service` was added to the hosted GATT database (or failed with `error`).
    case didAddService(service: String, error: WireError?)

    /// A remote central issued a read request.
    case didReceiveRead(WireReadRequest)

    /// A remote central issued a batch of write requests.
    case didReceiveWrite(WireWriteRequest)

    /// `central` subscribed to notifications for `characteristic`.
    case didSubscribe(central: WireSubscriber, characteristic: WireCharacteristicRef)

    /// `central` unsubscribed from notifications for `characteristic`.
    case didUnsubscribe(central: WireSubscriber, characteristic: WireCharacteristicRef)

    /// The `updateValue` request tagged with `sequence` was delivered.
    case updateValueDelivered(sequence: UInt64)
}
