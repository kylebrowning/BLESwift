//
//  Peripheral.swift
//  BLESwift
//

/// A handle to a connected peripheral, returned by `Central.connect(_:timeout:reconnect:warningOptions:)`
/// and carried by ``ConnectionState/connected(_:)``.
///
/// `Peripheral` is a lightweight, `Sendable` façade: it holds only ``id`` and an internal
/// **weak** reference back to the ``Central`` actor that vended it (see `WeakCentralBox`)
/// — never a strong one, so holding onto a `Peripheral` after its `Central` has been
/// deallocated does not keep that actor alive. GATT operations (reads, writes,
/// notifications — added in later phases) are declared as `async throws` methods on this
/// type that route through the owning actor; once the connection is torn down, the actor
/// drops its tracked session, and any further call through a stale `Peripheral` throws
/// ``BLESwiftError/notConnected``.
public struct Peripheral: Sendable {

    /// This peripheral's identifier.
    public let id: PeripheralIdentifier

    /// A weak handle to the ``Central`` actor that vended this `Peripheral`. See
    /// ``WeakCentralBox``.
    let centralBox: WeakCentralBox

    /// Creates a `Peripheral` bound to `central`, held only weakly.
    init(id: PeripheralIdentifier, central: Central) {
        self.id = id
        self.centralBox = WeakCentralBox(central)
    }

    /// Resolves the ``Central`` actor this peripheral belongs to.
    ///
    /// Later phases (GATT operations, notifications) use this to route their calls through
    /// the actor.
    ///
    /// - Throws: ``BLESwiftError/notConnected`` if the owning `Central` has already been
    ///   deallocated.
    func resolveCentral() throws -> Central {
        guard let central = centralBox.central else {
            throw BLESwiftError.notConnected
        }
        return central
    }
}

/// Holds a `weak` reference to a ``Central``, letting ``Peripheral`` refer to the actor that
/// created it without retaining it.
///
/// `central` is declared `nonisolated(unsafe)` rather than requiring `@unchecked Sendable`
/// on this whole type (forbidden — see Phase 2/10's grep guards): it is written exactly
/// once, at initialization, and never reassigned afterward by this type's own code — the
/// only further "mutation" is Swift's weak-reference runtime zeroing `central` out when the
/// referenced `Central` deallocates, which the language guarantees is safe to observe
/// concurrently (that guarantee is the entire point of `weak`). `nonisolated(unsafe)`
/// therefore narrowly and correctly disables the compiler's Sendable check for this one
/// property, relying instead on `weak`'s own thread safety — not on an unaudited, type-wide
/// escape hatch.
final class WeakCentralBox: Sendable {
    nonisolated(unsafe) weak var central: Central?

    init(_ central: Central) {
        self.central = central
    }
}
