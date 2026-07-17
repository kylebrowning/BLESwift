//
//  Central+Retrieval.swift
//  BLESwift
//

import BLESwiftCore
import Foundation

/// System-known peripheral retrieval — synchronous lookups against the local CoreBluetooth
/// cache/stack, with no radio scan.
extension Central {

    /// Looks up peripherals this device's CoreBluetooth stack already knows by
    /// identifier — no scan required.
    ///
    /// This is BLESwift's documented **restoration fallback**: persist the `uuid`s of
    /// peripherals you care about (e.g. in `UserDefaults`), and re-resolve them here on a
    /// later launch — this works even after a force-quit, when
    /// <doc:BackgroundRestoration> never fires. See that article's "Fallback" section.
    ///
    /// This is a synchronous lookup against the local CoreBluetooth cache — no radio scan,
    /// no waiting, cheap to call. Best called while ``state`` is ``CentralState/poweredOn``;
    /// earlier, CoreBluetooth may return no results. There is deliberately no hard state
    /// guard, matching ``connect(_:timeout:reconnect:warningOptions:)``, which also calls
    /// retrieval without one.
    ///
    /// Result order is not guaranteed, and identifiers CoreBluetooth doesn't recognize are
    /// simply omitted — never an error. An empty `identifiers` array returns `[]`.
    ///
    /// Retrieval does **not** connect, and does not hand back a ``Peripheral`` handle: feed
    /// a returned identifier to ``connect(_:timeout:reconnect:warningOptions:)``. For a
    /// peripheral the system is already holding a link to, that connect merely attaches
    /// this app to the existing link and typically completes quickly.
    ///
    /// - Parameter identifiers: The bare `UUID`s to resolve (not ``PeripheralIdentifier``s
    ///   — persist and query by the raw identifier CoreBluetooth assigned).
    /// - Returns: A ``PeripheralIdentifier`` for each recognized `UUID`, carrying
    ///   CoreBluetooth's system-cached name (`nil` becomes `"No Name"`, per
    ///   ``PeripheralIdentifier/init(uuid:name:)``).
    /// - Throws: ``BLESwiftError/stopped`` if this `Central` has been stopped via
    ///   ``stopAndExtractState()``.
    public func knownPeripherals(withIdentifiers identifiers: [UUID]) throws -> [PeripheralIdentifier] {
        guard let shim else { throw BLESwiftError.stopped }
        return shim.retrievePeripherals(withIdentifiers: identifiers)
            .map { PeripheralIdentifier(uuid: $0.identifier, name: $0.name) }
    }

    /// Peripherals currently connected to this *device* (by any app, not just this one)
    /// that contain at least one of the given services.
    ///
    /// ``connectionState`` tracks *this library's single session*; system-connected means
    /// the OS holds a BLE link to the peripheral opened by **any app on this device**
    /// (including another app entirely). The two can disagree — a peripheral can be
    /// system-connected while BLESwift is ``ConnectionState/disconnected`` from it.
    ///
    /// The service filter is **any-of** (a peripheral matches if it exposes at least one
    /// listed service), mirroring `CBCentralManager.retrieveConnectedPeripherals(withServices:)`.
    ///
    /// This is a synchronous lookup against the local CoreBluetooth stack — no radio scan,
    /// no waiting, cheap to call. Best called while ``state`` is ``CentralState/poweredOn``;
    /// earlier, CoreBluetooth may return no results. There is deliberately no hard state
    /// guard, matching ``connect(_:timeout:reconnect:warningOptions:)``, which also calls
    /// retrieval without one.
    ///
    /// Result order is not guaranteed, and this never errors for a lack of matches — an
    /// empty `services` array, or no system-connected match, returns `[]`.
    ///
    /// Retrieval does **not** connect, and does not hand back a ``Peripheral`` handle: feed
    /// a returned identifier to ``connect(_:timeout:reconnect:warningOptions:)``. Because
    /// the system already holds the link, that connect merely attaches this app to it and
    /// typically completes quickly.
    ///
    /// - Parameter services: The services to filter by — BLESwift's identity type; `CBUUID`
    ///   bridging stays internal to this call.
    /// - Returns: A ``PeripheralIdentifier`` for each matching system-connected peripheral,
    ///   carrying CoreBluetooth's system-cached name (`nil` becomes `"No Name"`, per
    ///   ``PeripheralIdentifier/init(uuid:name:)``).
    /// - Throws: ``BLESwiftError/stopped`` if this `Central` has been stopped via
    ///   ``stopAndExtractState()``.
    public func systemConnectedPeripherals(withServices services: [ServiceIdentifier]) throws -> [PeripheralIdentifier] {
        guard let shim else { throw BLESwiftError.stopped }
        return shim.retrieveConnectedPeripherals(withServices: services)
            .map { PeripheralIdentifier(uuid: $0.identifier, name: $0.name) }
    }
}
