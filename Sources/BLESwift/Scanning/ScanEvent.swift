//
//  ScanEvent.swift
//  BLESwift
//

import BLESwiftCore

/// An event produced by an in-progress
/// ``Central/scan(services:allowDuplicates:rssiThreshold:lossTimeout:timeout:)``. Breaking
/// out of (or cancelling the task consuming) the stream stops the scan; connecting while a
/// scan is live is permitted and does not stop it.
public enum ScanEvent: Sendable {

    /// A peripheral was sighted for the first time in this scan session — or again after
    /// previously being reported as ``lost(_:)``.
    case discovered(Discovery)

    /// A previously-``discovered(_:)`` peripheral was sighted again. Only emitted with
    /// `allowDuplicates: true`; otherwise CoreBluetooth never redelivers a discovery.
    case updated(Discovery)

    /// A previously-sighted peripheral has not been re-sighted within `lossTimeout`. Only
    /// emitted with `allowDuplicates: true`. A later re-sighting is reported as a fresh
    /// ``discovered(_:)``, not ``updated(_:)``.
    case lost(Discovery)
}
