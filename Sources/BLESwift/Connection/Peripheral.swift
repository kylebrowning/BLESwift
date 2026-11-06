//
//  Peripheral.swift
//  BLESwift
//

import BLESwiftCore

/// A handle to a connected peripheral.
/// `Central.connect(_:timeout:reconnect:warningOptions:compatibility:)` returns it, and
/// ``ConnectionState/connected(_:)`` carries it.
///
/// `Peripheral` is a lightweight, `Sendable` facade. It holds only ``id`` and a **weak**
/// reference to the ``Central`` that created it, so it does not keep that actor alive. After
/// the connection is torn down, each call through a stale `Peripheral` throws
/// ``BLESwiftError/notConnected``.
public struct Peripheral: Sendable {

    /// The identifier of this peripheral.
    public let id: PeripheralIdentifier

    /// A weak handle to the ``Central`` actor that created this `Peripheral`. See
    /// ``WeakCentralBox``.
    let centralBox: WeakCentralBox

    /// Creates a `Peripheral` bound to `central`. It holds `central` only weakly.
    init(id: PeripheralIdentifier, central: Central) {
        self.id = id
        self.centralBox = WeakCentralBox(central)
    }

    /// Resolves the ``Central`` actor to which this peripheral belongs.
    ///
    /// - Throws: ``BLESwiftError/notConnected`` if the owning `Central` is already
    ///   deallocated.
    func resolveCentral() throws -> Central {
        guard let central = centralBox.central else {
            throw BLESwiftError.notConnected
        }
        return central
    }

    /// Disconnects this peripheral. It calls `Central.disconnect(_:)`.
    ///
    /// Pending operations fail with ``BLESwiftError/explicitDisconnect``.
    ///
    /// - Throws: ``BLESwiftError/notConnected`` if the owning `Central` is already
    ///   deallocated. It also throws the errors that `Central.disconnect(_:)` documents.
    public func disconnect() async throws {
        let central = try resolveCentral()
        try await central.disconnect(id)
    }
}

/// Holds a `weak` reference to a ``Central``. It lets ``Peripheral`` refer to the actor that
/// created it, without a retain.
///
/// `central` is `nonisolated(unsafe)` and the type is not `@unchecked Sendable`. The type
/// writes `central` once, at init, and the runtime makes it safe to observe a weak reference
/// become `nil` from concurrent code. So this escape hatch is narrower than a type-wide one.
final class WeakCentralBox: Sendable {
    nonisolated(unsafe) weak var central: Central?

    init(_ central: Central) {
        self.central = central
    }
}
