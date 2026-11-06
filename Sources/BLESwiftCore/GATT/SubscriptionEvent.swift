//
//  SubscriptionEvent.swift
//  BLESwiftCore
//

/// A remote central subscribed to, or unsubscribed from, one of your hosted characteristics'
/// notifications. It appears on `PeripheralHost/subscriptionEvents()`.
///
/// Track these events to know which centrals are subscribed. Push values to them with
/// `PeripheralHost/updateValue(_:for:onSubscribed:)`. This is a `Sendable` value type.
public enum SubscriptionEvent: Sendable, Hashable {

    /// A central subscribed to `characteristic`'s notifications or indications. Mirrors
    /// `peripheralManager(_:central:didSubscribeTo:)`.
    case subscribed(Subscriber, characteristic: CharacteristicIdentifier)

    /// A central unsubscribed from `characteristic`'s notifications or indications. Mirrors
    /// `peripheralManager(_:central:didUnsubscribeFrom:)`.
    case unsubscribed(Subscriber, characteristic: CharacteristicIdentifier)
}
