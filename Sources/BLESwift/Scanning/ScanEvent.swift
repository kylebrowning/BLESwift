//
//  ScanEvent.swift
//  BLESwift
//

import BLESwiftCore

/// An event produced by an in-progress
/// ``Central/scan(services:allowDuplicates:rssiThreshold:lossTimeout:timeout:)``.
///
/// Scan results are delivered as a single stream: `break`ing out of (or cancelling the task
/// consuming) the stream stops the scan; `filter`ing the stream discards unwanted
/// peripherals from further reporting; calling `connect(_:)` with a sighted peripheral's
/// identifier connects to it directly. Connecting while a scan is live is permitted and
/// does not stop the scan.
public enum ScanEvent: Sendable {

    /// A peripheral was sighted for the first time in this scan session — or sighted again
    /// after previously being reported as ``lost(_:)``.
    case discovered(Discovery)

    /// A previously-``discovered(_:)`` peripheral was sighted again in the same scan
    /// session. Only emitted when the scan was started with `allowDuplicates: true` —
    /// without it, CoreBluetooth itself never redelivers a discovery for an
    /// already-discovered peripheral, so this case cannot occur.
    case updated(Discovery)

    /// A previously-sighted peripheral has not been re-sighted within the scan's
    /// `lossTimeout`. Only emitted when the scan was started with `allowDuplicates: true`
    /// (peripheral-loss tracking only makes sense when repeat sightings are being observed
    /// in the first place). A later re-sighting of the same peripheral is reported as a
    /// fresh ``discovered(_:)``, not ``updated(_:)``.
    case lost(Discovery)
}
