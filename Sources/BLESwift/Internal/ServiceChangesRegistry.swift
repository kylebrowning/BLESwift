//
//  ServiceChangesRegistry.swift
//  BLESwift
//

import BLESwiftCore
import Synchronization

/// Per-peripheral `didModifyServices` broadcasters, keyed by ``PeripheralIdentifier`` —
/// replaces `Central`'s old single, un-keyed `serviceChangesBroadcaster` so peripheral A's
/// invalidations never reach peripheral B's ``Peripheral/serviceChanges()`` subscribers.
///
/// Declared `nonisolated` and `Mutex`-guarded (via ``Broadcaster``, itself `Sendable` and
/// internally `Mutex`-guarded — this type adds only the identifier-keyed dictionary layer)
/// for the same reason the single broadcaster it replaces was: ``Peripheral/serviceChanges()``
/// must fetch its stream **synchronously** — no actor hop, matching that method's
/// non-`async` signature.
///
/// Entries are created on demand (``broadcaster(for:)`` is get-or-create) and never
/// removed — bounded by the number of distinct peripherals this `Central` ever touches,
/// not by how many are currently connected. Streams deliberately survive disconnect,
/// matching the single-peripheral predecessor's behavior (that broadcaster never finished
/// on disconnect either): a subscriber that started listening before a disconnect keeps
/// receiving invalidations after that same peripheral reconnects, because reconnecting
/// reuses the same `PeripheralIdentifier` and so the same broadcaster instance.
final class ServiceChangesRegistry: Sendable {

    private let broadcasters = Mutex<[PeripheralIdentifier: Broadcaster<[ServiceIdentifier]>]>([:])

    /// Returns `id`'s broadcaster, creating one (with `.none` replay, matching the
    /// single-broadcaster predecessor) on first access.
    ///
    /// Get-or-create happens entirely inside one `withLock` — no callback into this
    /// registry (or anything else) runs while the lock is held, only a plain dictionary
    /// lookup/insert and a `Broadcaster` allocation — so two concurrent calls for the same
    /// `id` are serialized by the lock itself and always observe (and return) the SAME
    /// instance; there is no lost-broadcaster race between a "does it exist" check and a
    /// separate "create it" step.
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
