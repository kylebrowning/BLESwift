//
//  Peripheral+ANCS.swift
//  BLESwift
//

#if os(iOS)
import BLESwiftCore

extension Peripheral {

    /// Whether the connection used `requiresANCS: true` and the user authorized ANCS (Apple
    /// Notification Center Service) data sharing. It mirrors `CBPeripheral.ancsAuthorized`.
    ///
    /// The value is `false` if the peripheral is not connected, or if its `Central` is
    /// deallocated. iOS only.
    public var ancsAuthorized: Bool {
        get async {
            guard let central = centralBox.central else { return false }
            return await central.ancsAuthorized(for: id)
        }
    }

    /// Returns a multicast stream of ANCS authorization changes for this peripheral. It
    /// mirrors `centralManager(_:didUpdateANCSAuthorizationFor:)`. Each element is the new
    /// ``ancsAuthorized`` value.
    ///
    /// Like ``serviceChanges()``, the stream survives a disconnect and continues after a
    /// reconnect. There is no replay. Read ``ancsAuthorized`` for the current value. iOS only.
    public func ancsAuthorizationEvents() -> AsyncStream<Bool> {
        guard let central = centralBox.central else {
            return AsyncStream { continuation in continuation.finish() }
        }
        return central.ancsAuthorizationRegistry.broadcaster(for: id).stream()
    }
}
#endif
