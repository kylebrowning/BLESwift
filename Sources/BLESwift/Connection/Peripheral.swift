//
//  Peripheral.swift
//  BLESwift
//

import BLESwiftCore

/// A handle to a connected peripheral, returned by `Central.connect(_:timeout:reconnect:warningOptions:)`
/// and carried by ``ConnectionState/connected(_:)``.
///
/// `Peripheral` is a lightweight, `Sendable` façade: it holds only ``id`` and an internal
/// **weak** reference back to the ``Central`` actor that vended it — never a strong one, so
/// holding onto a `Peripheral` after its `Central` deallocates does not keep that actor
/// alive. Once the connection is torn down, any further call through a stale `Peripheral`
/// throws ``BLESwiftError/notConnected``.
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
    /// - Throws: ``BLESwiftError/notConnected`` if the owning `Central` has already been
    ///   deallocated.
    func resolveCentral() throws -> Central {
        guard let central = centralBox.central else {
            throw BLESwiftError.notConnected
        }
        return central
    }

    /// Disconnects this peripheral — the ergonomic call-site for
    /// `Central.disconnect(_:immediate:)`.
    ///
    /// - Parameter immediate: If `true`, fails pending operations with
    ///   ``BLESwiftError/explicitDisconnect`` rather than waiting for them to finish.
    ///   Defaults to `false`.
    /// - Throws: ``BLESwiftError/notConnected`` if the owning `Central` has already been
    ///   deallocated, or as documented on `Central.disconnect(_:immediate:)`.
    public func disconnect(immediate: Bool = false) async throws {
        let central = try resolveCentral()
        try await central.disconnect(id, immediate: immediate)
    }
}

/// Holds a `weak` reference to a ``Central``, letting ``Peripheral`` refer to the actor that
/// created it without retaining it.
///
/// `central` is `nonisolated(unsafe)` rather than `@unchecked Sendable` on the whole type:
/// it's written once at init, and weak's runtime zeroing is safe to observe concurrently by
/// the language's own guarantee — a narrower escape hatch than an unaudited, type-wide one.
final class WeakCentralBox: Sendable {
    nonisolated(unsafe) weak var central: Central?

    init(_ central: Central) {
        self.central = central
    }
}
