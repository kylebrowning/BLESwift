//
//  BufferingPolicy.swift
//  BLESwift
//

/// How a notification stream buffers values its consumer hasn't consumed yet.
///
/// BLESwift's own mirror of `AsyncStream.Continuation.BufferingPolicy` (which is nested inside
/// a generic type and so can't appear directly in
/// ``Peripheral/notifications(for:policy:)``'s signature without naming the element type).
/// Notifications arrive at the peripheral's pace, not the consumer's — this policy decides
/// what happens when the consumer falls behind.
public enum BufferingPolicy: Sendable, Equatable {

    /// Buffer every unconsumed value, without limit. The default.
    case unbounded

    /// Buffer at most `count` unconsumed values, discarding the **newest** value when a
    /// fresh one arrives with the buffer full (the buffer keeps the oldest values).
    case bufferingOldest(Int)

    /// Buffer at most `count` unconsumed values, discarding the **oldest** buffered value
    /// when a fresh one arrives with the buffer full (the buffer keeps the newest values).
    /// `bufferingNewest(1)` yields classic "latest value wins" behavior.
    case bufferingNewest(Int)
}

extension BufferingPolicy {
    /// The corresponding `AsyncThrowingStream` buffering policy for streams of `Element`.
    func asStreamPolicy<Element>(
        of _: Element.Type = Element.self
    ) -> AsyncThrowingStream<Element, Error>.Continuation.BufferingPolicy {
        switch self {
        case .unbounded:
            return .unbounded
        case .bufferingOldest(let count):
            return .bufferingOldest(count)
        case .bufferingNewest(let count):
            return .bufferingNewest(count)
        }
    }
}
