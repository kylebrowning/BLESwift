//
//  BufferingPolicy.swift
//  BLESwift
//

/// How a notification stream buffers the values that its consumer has not consumed yet. It
/// mirrors `AsyncStream.Continuation.BufferingPolicy`, which needs an element type and so
/// cannot appear in the signature of ``Peripheral/notifications(for:policy:)``.
public enum BufferingPolicy: Sendable, Equatable {

    /// Buffer every unconsumed value, without a limit. This is the default.
    case unbounded

    /// Buffer at most `count` unconsumed values. If a new value arrives and the buffer is
    /// full, the buffer discards the **newest** value. The buffer keeps the oldest values.
    case bufferingOldest(Int)

    /// Buffer at most `count` unconsumed values. If a new value arrives and the buffer is
    /// full, the buffer discards the **oldest** value. The buffer keeps the newest
    /// values. `bufferingNewest(1)` keeps only the latest value.
    case bufferingNewest(Int)
}

extension BufferingPolicy {
    /// The matching `AsyncThrowingStream` buffering policy for streams of `Element`.
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
