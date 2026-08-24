//
//  ANCSAuthorizationRegistry.swift
//  BLESwift
//

#if os(iOS)
import BLESwiftCore
import Synchronization

/// Per-peripheral ANCS-authorization broadcasters, keyed by ``PeripheralIdentifier`` —
/// the ANCS mirror of ``ServiceChangesRegistry``, with the same synchronous-fetch
/// (`nonisolated`, `Mutex`-guarded) and survives-reconnect semantics.
///
/// Entries are created on demand and never removed — bounded by the number of distinct
/// peripherals this `Central` ever touches.
final class ANCSAuthorizationRegistry: Sendable {

    private let broadcasters = Mutex<[PeripheralIdentifier: Broadcaster<Bool>]>([:])

    /// Returns `id`'s broadcaster, creating one (`.none` replay) on first access.
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
