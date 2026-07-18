//
//  SubscriptionEvent.swift
//  BLESwiftCore
//

/// A remote central subscribing to, or unsubscribing from, one of your hosted
/// characteristic's notifications — surfaced on `PeripheralHost/subscriptionEvents()`.
///
/// Track these to know which centrals are currently listening: push values to them with
/// `PeripheralHost/updateValue(_:for:onSubscribed:)`. A `Sendable` value type.
public enum SubscriptionEvent: Sendable, Hashable {

    /// A central subscribed to `characteristic`'s notifications/indications. Mirrors
    /// `peripheralManager(_:central:didSubscribeTo:)`.
    case subscribed(Subscriber, characteristic: CharacteristicIdentifier)

    /// A central unsubscribed from `characteristic`'s notifications/indications. Mirrors
    /// `peripheralManager(_:central:didUnsubscribeFrom:)`.
    case unsubscribed(Subscriber, characteristic: CharacteristicIdentifier)
}
