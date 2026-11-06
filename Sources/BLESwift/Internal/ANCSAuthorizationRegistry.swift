//
//  ANCSAuthorizationRegistry.swift
//  BLESwift
//

#if os(iOS)
import BLESwiftCore
import BLESwiftCompat17

/// Per-peripheral ANCS-authorization broadcasters, keyed by ``PeripheralIdentifier``. It works
/// like ``ServiceChangesRegistry``: a `Mutex` guards it, you fetch synchronously, and entries
/// survive a reconnect.
///
/// The registry creates entries on demand and never removes them.
final class ANCSAuthorizationRegistry: Sendable {

    private let broadcasters = Mutex<[PeripheralIdentifier: Broadcaster<Bool>]>([:])

    /// Returns the broadcaster for `id`. On first access, it creates one with `.none` replay.
    func broadcaster(for id: PeripheralIdentifier) -> Broadcaster<Bool> {
        broadcasters.withLock { state in
            if let existing = state[id] {
                return existing
            }
            let created = Broadcaster<Bool>(replay: .none)
            state[id] = created
            return created
        }
    }
}
#endif
