//
//  VirtualLatency.swift
//  BLESwiftVirtualRadio
//

/// How long a virtual device takes to answer each kind of request, on its radio's
/// ``VirtualRadio/clock``. Every delay defaults to `.zero`, which is no delay at all: the
/// radio answers in the same actor turn it always has, and registers nothing on the clock.
///
/// A delay stands in for the air time a real peripheral takes, so a timeout — a
/// `connect(timeout:)` of thirty seconds, a read that never comes back — can be driven to
/// its deadline. With `BLESwiftTestSupport`'s `ManualClock` on the radio and on
/// `Configuration.clock`, that deadline is reached by advancing the clock, not by waiting.
///
/// There is no notification or advertising delay: the device's handler already decides
/// when it notifies, and the handle decides when it advertises.
///
/// **A delay already started outlives a disconnect.** The radio checks the connection only
/// once the delay has run out, so a read, write, or subscribe cut off by a disconnect still
/// sleeps out its full delay before it is refused — unlike hardware, where a link drop
/// aborts the ATT transaction. Until then the remote's serial chain stays blocked behind
/// it, so a reconnect's first operation queues behind the rest of the old delay, and a
/// `ManualClock` still counts that sleeper. A connect delay is the exception: a cancel
/// withdraws the attempt, sleep and all.
public struct VirtualLatency: Sendable, Equatable {

    /// How long a connection attempt takes to be answered — succeed or fail — once the
    /// backend has sent it. A cancel during the delay abandons the attempt without the radio
    /// ever seeing it.
    public var connect: Duration

    /// How long each service or characteristic discovery takes.
    public var discovery: Duration

    /// How long a read takes to be answered.
    public var read: Duration

    /// How long a `.withResponse` write takes to be answered. A `.withoutResponse` write has
    /// no answer to delay.
    public var write: Duration

    /// How long enabling or disabling notifications takes to be answered.
    public var subscribe: Duration

    /// Creates a latency, every delay defaulting to `.zero`.
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

    /// No delay on anything — the default.
    public static let none = VirtualLatency()
}
