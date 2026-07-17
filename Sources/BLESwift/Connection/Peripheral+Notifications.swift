//
//  Peripheral+Notifications.swift
//  BLESwift
//

import BLESwiftCore
import Foundation

/// Notification (listen) streams, implemented as multicast `AsyncThrowingStream`s with a
/// refcounted `setNotifyValue` lifecycle.
extension Peripheral {

    /// Returns a stream of `characteristic`'s notifications, each decoded as `Value`.
    ///
    /// BLESwift notification streams are **multicast** — any number of concurrent
    /// subscribers each receive every value. The underlying CoreBluetooth notify state is
    /// refcounted: the first subscriber enables notifications (`setNotifyValue(true)`, awaiting its
    /// `didUpdateNotificationState` confirmation before values can be missed — the
    /// subscription is registered even before that handshake, so nothing delivered
    /// mid-handshake is lost), and only the last subscriber to go away disables them again
    /// (and only while still connected with the radio powered on).
    ///
    /// ### Ending the stream
    /// Stop consuming (`break` out of the `for try await` loop, or cancel the consuming
    /// task) to unsubscribe; there is no explicit "stop listening" call. The stream ends
    /// by **throwing** when the connection does — ``BLESwiftError/unexpectedDisconnect`` /
    /// ``BLESwiftError/explicitDisconnect`` / whatever error tore the connection down — and
    /// streams do **not** re-arm on reconnect: resubscribe after observing
    /// ``ConnectionEvent/connected(_:)``.
    ///
    /// ### Decode failures
    /// A value that fails `Value`'s `Receivable` decoding finishes **this subscriber's**
    /// stream by throwing the decode error — a typed stream cannot silently skip a value.
    /// Other concurrent subscribers of the same characteristic are unaffected (each has
    /// its own decode layer over the shared raw `Data` multicast). Subscribe with
    /// `Value == Data` (its `Receivable` conformance is the identity) for a stream that
    /// can never fail decoding.
    ///
    /// - Parameters:
    ///   - characteristic: The characteristic to receive notifications from. Its owning
    ///     service, and the characteristic itself, are lazily discovered first if needed.
    ///   - policy: How values are buffered when this subscriber consumes more slowly than
    ///     the peripheral notifies. Defaults to ``BufferingPolicy/unbounded``.
    /// - Returns: A stream of decoded notification values. If this peripheral is not (or
    ///   no longer) connected, the stream immediately throws ``BLESwiftError/notConnected``.
    ///
    /// - Note: Unlike ``read(from:timeout:)``, `Value` additionally requires
    ///   `SendableMetatype` (satisfied automatically by any type whose `Receivable`
    ///   conformance is nonisolated — i.e. every ordinary decode type): the decode layer
    ///   runs inside a `@Sendable` closure crossing into the owning actor, which Swift 6's
    ///   region isolation only permits for values whose metatype is safe to share.
    public func notifications<Value: Receivable & SendableMetatype>(
        for characteristic: CharacteristicIdentifier,
        policy: BufferingPolicy = .unbounded
    ) -> AsyncThrowingStream<Value, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: Value.self,
            bufferingPolicy: policy.asStreamPolicy(of: Value.self)
        )

        guard let central = centralBox.central else {
            continuation.finish(throwing: BLESwiftError.notConnected)
            return stream
        }

        let id = self.id
        let token = UUID()

        // The per-caller decode layer: turns one raw `Data` packet into a typed yield, or
        // reports the decode error that will finish (only) this subscriber's stream.
        let deliver: @Sendable (Data) -> Error? = { data in
            do {
                continuation.yield(try Value(bluetoothData: data))
                return nil
            } catch {
                return error
            }
        }
        let finish: @Sendable (Error?) -> Void = { error in
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }

        // Registration is enqueued BEFORE this method returns; `onTermination` (below) can
        // only fire after the caller has the stream, so — by the serial queue's FIFO
        // ordering — registration always runs before the termination handler's release.
        central.queue.async {
            central.assumeIsolated { central in
                central.startNotificationPump(
                    peripheral: id,
                    characteristic: characteristic,
                    token: token,
                    deliver: deliver,
                    finish: finish
                )
            }
        }

        continuation.onTermination = { _ in
            // Same sanctioned hop as every other arbitrary-thread entry point (delegate
            // proxy, cancellation handlers): `queue.async` + `assumeIsolated`, never
            // `Task { }`.
            central.queue.async {
                central.assumeIsolated { central in
                    central.handleNotificationStreamTermination(peripheral: id, characteristic: characteristic, token: token)
                }
            }
        }

        return stream
    }
}
