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
    /// Streams are **multicast** — any number of concurrent subscribers each receive every
    /// value. The underlying CoreBluetooth notify state is refcounted: the first subscriber
    /// enables notifications, and only the last subscriber to go away disables them again.
    ///
    /// Stop consuming (`break`, or cancel the task) to unsubscribe; there is no explicit
    /// "stop listening" call. The stream ends by **throwing** when the connection does, and
    /// does **not** re-arm on reconnect: resubscribe after observing
    /// ``ConnectionEvent/connected(_:)``.
    ///
    /// A value that fails `Value`'s `Receivable` decoding finishes **this subscriber's**
    /// stream only — other concurrent subscribers of the same characteristic are unaffected.
    /// Subscribe with `Value == Data` for a stream that can never fail decoding.
    ///
    /// - Parameters:
    ///   - characteristic: The characteristic to receive notifications from.
    ///   - policy: How values are buffered when this subscriber consumes more slowly than
    ///     the peripheral notifies. Defaults to ``BufferingPolicy/unbounded``.
    /// - Returns: A stream of decoded notification values. If this peripheral is not (or
    ///   no longer) connected, the stream immediately throws ``BLESwiftError/notConnected``.
    ///
    /// - Note: Unlike ``read(from:timeout:)``, `Value` additionally requires
    ///   `SendableMetatype`: the decode layer runs inside a `@Sendable` closure crossing
    ///   into the owning actor, which Swift 6's region isolation requires.
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

        // Per-caller decode layer: turns a raw `Data` packet into a typed yield, or reports
        // the decode error that finishes only this subscriber's stream.
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

        // Enqueued before this method returns, so by the serial queue's FIFO ordering,
        // registration always runs before `onTermination`'s release.
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
            // Same sanctioned hop as every other arbitrary-thread entry point: `queue.async`
            // + `assumeIsolated`, never `Task { }`.
            central.queue.async {
                central.assumeIsolated { central in
                    central.handleNotificationStreamTermination(peripheral: id, characteristic: characteristic, token: token)
                }
            }
        }

        return stream
    }
}
