//
//  Central+Retrieval.swift
//  BLESwift
//

import BLESwiftCore
import Foundation

/// System-known peripheral retrieval — synchronous lookups against the local CoreBluetooth
/// cache/stack, with no radio scan.
extension Central {

    /// Looks up peripherals this device's CoreBluetooth stack already knows by identifier —
    /// no scan required. Documented restoration fallback: persist `uuid`s and re-resolve
    /// them here on a later launch, even after a force-quit (see <doc:BackgroundRestoration>).
    ///
    /// - Parameter identifiers: The bare `UUID`s to resolve (not ``PeripheralIdentifier``s).
    /// - Returns: A ``PeripheralIdentifier`` per recognized `UUID`; unrecognized ones are
    ///   omitted, not errors. Feed a result to ``connect(_:timeout:reconnect:warningOptions:)``.
    /// - Throws: ``BLESwiftError/stopped`` if this `Central` has been stopped.
    public func knownPeripherals(withIdentifiers identifiers: [UUID]) throws -> [PeripheralIdentifier] {
        guard let shim else { throw BLESwiftError.stopped }
        return shim.retrievePeripherals(withIdentifiers: identifiers)
            .map { PeripheralIdentifier(uuid: $0.identifier, name: $0.name) }
    }

    /// Peripherals currently connected to this *device* (by any app, not just this one)
    /// that contain at least one of the given services. Unlike
    /// ``Central/connectedPeripherals``, this reflects OS-wide links, not just this
    /// library's tracked sessions — the two can disagree.
    ///
    /// - Parameter services: The services to filter by (any-of match).
    /// - Returns: A ``PeripheralIdentifier`` per matching peripheral. Feed a result to
    ///   ``connect(_:timeout:reconnect:warningOptions:)``.
    /// - Throws: ``BLESwiftError/stopped`` if this `Central` has been stopped.
    public func systemConnectedPeripherals(withServices services: [ServiceIdentifier]) throws -> [PeripheralIdentifier] {
        guard let shim else { throw BLESwiftError.stopped }
        return shim.retrieveConnectedPeripherals(withServices: services)
            .map { PeripheralIdentifier(uuid: $0.identifier, name: $0.name) }
    }
}
