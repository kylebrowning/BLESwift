//
//  VirtualLatency.swift
//  BLESwiftVirtualRadio
//

/// How long a virtual device takes to answer each kind of request, on the radio's
/// ``VirtualRadio/clock``. Every delay is `.zero` by default. The radio then answers in the same
/// actor turn and registers nothing on the clock.
///
/// Use a delay to drive a timeout to its deadline, such as a thirty-second `connect(timeout:)`. Put
/// the same `ManualClock` from `BLESwiftTestSupport` on the radio and on `Configuration.clock`,
/// then advance it.
///
/// - There is no notification delay and no advertising delay.
/// - A delay that has started continues after a disconnect. The radio checks the connection only
///   when the delay ends, and then refuses the request. Hardware aborts the ATT transaction
///   instead.
/// - Until the delay ends, the remote's serial chain stays blocked and a `ManualClock` still counts
///   the sleeper.
/// - A connect delay is the exception: a cancel withdraws the attempt together with its sleep.
public struct VirtualLatency: Sendable, Equatable {

    /// How long the radio takes to answer a connection attempt, success or failure, after the
    /// backend sends it. If a cancel occurs during the delay, the attempt ends and the radio never
    /// sees it.
    public var connect: Duration

    /// How long each service or characteristic discovery takes.
    public var discovery: Duration

    /// How long the radio takes to answer a read.
    public var read: Duration

    /// How long the radio takes to answer a `.withResponse` write. A `.withoutResponse` write has
    /// no answer, so there is no delay to apply.
    public var write: Duration

    /// How long the radio takes to answer a request to enable or disable notifications.
    public var subscribe: Duration

    /// Creates a latency. Every delay is `.zero` by default.
    public init(
        connect: Duration = .zero,
        discovery: Duration = .zero,
        read: Duration = .zero,
        write: Duration = .zero,
        subscribe: Duration = .zero
    ) {
        self.connect = connect
        self.discovery = discovery
        self.read = read
        self.write = write
        self.subscribe = subscribe
    }

    /// No delay on any request. This is the default.
    public static let none = VirtualLatency()
}
