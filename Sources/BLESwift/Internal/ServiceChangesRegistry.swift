//
//  ServiceChangesRegistry.swift
//  BLESwift
//

import BLESwiftCore
import BLESwiftCompat17

/// Per-peripheral `didModifyServices` broadcasters, keyed by ``PeripheralIdentifier``. The
/// invalidations of one peripheral never reach the subscribers of another.
///
/// The registry is `nonisolated` and a `Mutex` guards it, because
/// ``Peripheral/serviceChanges()`` is not `async` and must fetch its stream synchronously.
///
/// The registry creates entries on demand and never removes them. Streams survive a
/// disconnect, because a reconnect reuses the same broadcaster.
final class ServiceChangesRegistry: Sendable {

    private let broadcasters = Mutex<[PeripheralIdentifier: Broadcaster<[ServiceIdentifier]>]>([:])

    /// Returns the broadcaster for `id`. On first access, it creates one with `.none` replay.
    /// Get-or-create runs inside one `withLock`, so concurrent calls for the same `id` return
    /// the same instance.
    func broadcaster(for id: PeripheralIdentifier) -> Broadcaster<[ServiceIdentifier]> {
        broadcasters.withLock { state in
            if let existing = state[id] {
                return existing
            }
            let created = Broadcaster<[ServiceIdentifier]>(replay: .none)
            state[id] = created
            return created
        }
    }
}
