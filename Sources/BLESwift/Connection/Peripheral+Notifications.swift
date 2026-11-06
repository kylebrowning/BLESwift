//
//  Peripheral+Notifications.swift
//  BLESwift
//

import BLESwiftCompat16
import BLESwiftCore
import Foundation

/// Notification (listen) streams: multicast `AsyncThrowingStream` values with a
/// reference-counted `setNotifyValue` lifecycle.
extension Peripheral {

    /// Returns a stream of the notifications of `characteristic`, decoded as `Value`.
    ///
    /// Streams are **multicast**. Each concurrent subscriber receives every value. The first
    /// subscriber enables notifications and the last one to leave disables them. To
    /// unsubscribe, stop to consume (`break`, or cancel the task).
    ///
    /// By default, the stream ends by **throwing** when the connection ends. A reconnect does
    /// not enable it again. Pass `survivesReconnect: true` to keep the stream across an
    /// unexpected disconnect that an active ``ReconnectPolicy`` will retry. The same stream
    /// then continues after BLESwift runs discovery again and enables notifications again.
    /// ``ConnectionEvent/notificationsRestored(_:restored:failed:)`` reports the result.
    /// See <doc:ConnectionsAndReconnection#Notification-streams-across-reconnects>.
    ///
    /// If a value fails the `Receivable` decoding of `Value`, only **this subscriber's**
    /// stream finishes. With `Value == Data`, decoding cannot fail.
    ///
    /// - Parameters:
    ///   - characteristic: The characteristic from which to receive notifications.
    ///   - policy: How the stream buffers values when this subscriber consumes more slowly
    ///     than the peripheral notifies. The default is ``BufferingPolicy/unbounded``.
    ///   - survivesReconnect: Whether this stream survives an automatic reconnect. The default
    ///     is `false`. It has an effect only with a ``ReconnectPolicy`` other than
    ///     ``ReconnectPolicy/never``. An explicit disconnect always finishes the stream.
    /// - Returns: A stream of decoded notification values. If this peripheral is not
    ///   connected, the stream throws ``BLESwiftError/notConnected`` immediately.
    ///
    /// - Note: Unlike ``read(from:timeout:)``, `Value` must also conform to
    ///   `SendableMetatype`, because the decode layer runs in a `@Sendable` closure that
    ///   crosses into the owning actor.
    public func notifications<Value: Receivable & SendableMetatype>(
        for characteristic: CharacteristicIdentifier,
        policy: BufferingPolicy = .unbounded,
        survivesReconnect: Bool = false
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

        // Per-subscriber decode layer. It yields a typed value, or returns the decode error that
        // finishes only this subscriber's stream.
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

        // Enqueued before the method returns. The serial queue's FIFO order runs the
        // registration before `onTermination` can release it.
        central.queue.async {
            central.assumeIsolated(onQueue: central.queue) { central in
                central.startNotificationPump(
                    peripheral: id,
                    characteristic: characteristic,
                    token: token,
                    survivesReconnect: survivesReconnect,
                    deliver: deliver,
                    finish: finish
                )
            }
        }

        continuation.onTermination = { _ in
            // The approved hop from an arbitrary thread: `queue.async` and `assumeIsolated`,
            // never `Task { }`.
            central.queue.async {
                central.assumeIsolated(onQueue: central.queue) { central in
                    central.handleNotificationStreamTermination(peripheral: id, characteristic: characteristic, token: token)
                }
            }
        }

        return stream
    }
}
