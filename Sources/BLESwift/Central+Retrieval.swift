//
//  Central+Retrieval.swift
//  BLESwift
//

import BLESwiftCore
import Foundation

/// System-known peripheral retrieval. These lookups are synchronous and do not scan.
extension Central {

    /// Looks up peripherals that this device's CoreBluetooth stack already knows by
    /// identifier. No scan is necessary. Save the `uuid` values and resolve them here on a
    /// later launch. This also works after the user force-quits the app (see
    /// <doc:BackgroundRestoration>).
    ///
    /// - Parameter identifiers: The bare `UUID` values to resolve. Do not use
    ///   ``PeripheralIdentifier`` values.
    /// - Returns: A ``PeripheralIdentifier`` for each recognized `UUID`. The result omits
    ///   unrecognized values. Pass a result to
    ///   ``connect(_:timeout:reconnect:warningOptions:compatibility:)``.
    /// - Throws: ``BLESwiftError/stopped`` if this `Central` is stopped.
    public func knownPeripherals(withIdentifiers identifiers: [UUID]) throws -> [PeripheralIdentifier] {
        guard let shim else { throw BLESwiftError.stopped }
        return shim.retrievePeripherals(withIdentifiers: identifiers)
            .map { PeripheralIdentifier(uuid: $0.identifier, name: $0.name) }
    }

    /// Peripherals that are connected to this *device* and that contain at least one of the
    /// given services. Any app can hold the connection. ``Central/connectedPeripherals`` shows
    /// only the sessions that this library tracks, so the two results can differ.
    ///
    /// - Parameter services: The services to filter by. A peripheral matches if it has any
    ///   one of them.
    /// - Returns: A ``PeripheralIdentifier`` for each matching peripheral. Pass a result to
    ///   ``connect(_:timeout:reconnect:warningOptions:compatibility:)``.
    /// - Throws: ``BLESwiftError/stopped`` if this `Central` is stopped.
    public func systemConnectedPeripherals(withServices services: [ServiceIdentifier]) throws -> [PeripheralIdentifier] {
        guard let shim else { throw BLESwiftError.stopped }
        return shim.retrieveConnectedPeripherals(withServices: services)
            .map { PeripheralIdentifier(uuid: $0.identifier, name: $0.name) }
    }
}
