//
//  Peripheral+ANCS.swift
//  BLESwift
//

#if os(iOS)
import BLESwiftCore

extension Peripheral {

    /// Whether this peripheral's connection was made with `requiresANCS: true` and the
    /// user has authorized ANCS (Apple Notification Center Service) data sharing. Mirrors
    /// `CBPeripheral.ancsAuthorized`.
    ///
    /// `false` when the peripheral is not currently connected (or its `Central` has been
    /// deallocated). iOS only.
    public var ancsAuthorized: Bool {
        get async {
            guard let central = centralBox.central else { return false }
            return await central.ancsAuthorized(for: id)
        }
    }

    /// Returns a multicast stream of ANCS authorization changes for this peripheral,
    /// mirroring `centralManager(_:didUpdateANCSAuthorizationFor:)`. Each element is the
    /// new ``ancsAuthorized`` value.
    ///
    /// Keyed by identifier, like ``serviceChanges()``: the stream deliberately survives
    /// disconnect — a subscriber keeps receiving changes after this same peripheral
    /// reconnects. No replay; read ``ancsAuthorized`` for the current value. iOS only.
    public func ancsAuthorizationEvents() -> AsyncStream<Bool> {
        guard let central = centralBox.central else {
            return AsyncStream { continuation in continuation.finish() }
        }
        return central.ancsAuthorizationRegistry.broadcaster(for: id).stream()
    }
}
#endif
