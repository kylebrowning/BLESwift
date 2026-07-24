//
//  ServiceChangesRegistry.swift
//  BLESwift
//

import BLESwiftCore
import Synchronization

/// Per-peripheral `didModifyServices` broadcasters, keyed by ``PeripheralIdentifier``, so
/// peripheral A's invalidations never reach peripheral B's ``Peripheral/serviceChanges()``
/// subscribers.
///
/// `nonisolated` and `Mutex`-guarded: ``Peripheral/serviceChanges()`` must fetch its stream
/// **synchronously** — no actor hop, matching that method's non-`async` signature.
///
/// Entries are created on demand and never removed — bounded by the number of distinct
/// peripherals this `Central` ever touches. Streams deliberately survive disconnect: a
/// subscriber that started listening before a disconnect keeps receiving invalidations
/// after that same peripheral reconnects, since reconnecting reuses the same broadcaster.
final class ServiceChangesRegistry: Sendable {

    private let broadcasters = Mutex<[PeripheralIdentifier: Broadcaster<[ServiceIdentifier]>]>([:])

    /// Returns `id`'s broadcaster, creating one (`.none` replay) on first access.
    /// Get-or-create happens entirely inside one `withLock`, so two concurrent calls for
    /// the same `id` are serialized and always return the same instance.
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
